import 'dart:io';

import 'package:console_bars/console_bars.dart';

import '../entities/media_entity.dart';
import '../models/pipeline_step_model.dart';
import '../services/file_operations/moving/media_entity_moving_service.dart';
import '../services/file_operations/moving/moving_context_model.dart';
import '../value_objects/media_files_collection.dart';

/// Step 7: Move files to output directory
///
/// This critical final step organizes and relocates all processed media files from the
/// Google Photos Takeout structure to the user's desired output organization. It applies
/// all configuration choices including album behavior, date organization, and file operation modes.
///
/// (Docstring intentionally preserved as provided by user.)
class MoveFilesStep extends ProcessingStep {
  const MoveFilesStep() : super('Move Files');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();

    try {
      // 1) Optional transformation of Pixel .MP/.MV files (before estimating ops)
      int transformedCount = 0;
      if (context.config.transformPixelMp) {
        transformedCount = await _transformPixelFiles(context);
        if (context.config.verbose) {
          print('Transformed $transformedCount Pixel .MP/.MV files to .mp4');
        }
      }

      // 2) Prepare moving context and service
      final movingContext = MovingContext.fromConfig(
        context.config,
        context.outputDirectory,
      );
      final movingService = MediaEntityMovingService();

      // 3) Compute the number of REAL file operations (exclude symlinks/shortcuts/json)
      int filesPlanned = _estimateRealFileOpsPlanned(context);

      // 4) Initialize a progress bar that tracks ONLY real file operations
      //    We may adjust "total" upward if we detect more real file ops than planned.
      var progressBar = FillingBar(
        desc: 'Moving files',
        total: filesPlanned > 0 ? filesPlanned : 1,
        width: 50,
      );

      // 5) Counters
      int processedEntities = 0;       // secondary: entities processed
      int filesMovedCount = 0;         // primary: real file ops (move/copy/rename of media)
      int symlinksCreatedCount = 0;    // symlink/shortcut ops (including .lnk/.url/etc.)
      int jsonWritesCount = 0;         // JSON writes (if any)
      int otherOpsCount = 0;           // any other operation kind

      // 6) Consume stream; progress is driven by onOperation classification
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
        onOperation: (final result) {
          final kind = _classifyOperationKind(result);

          if (kind == _OpKind.file) {
            filesMovedCount++;

            // If we are exceeding the planned total (e.g., behavior alias not detected),
            // bump the progress bar's total so it can still reach 100%.
            if (filesMovedCount > progressBar.total) {
              // Recreate the bar with a larger total and update it to current progress.
              final newTotal = filesMovedCount;
              // Print a newline to avoid overwriting the existing bar in some terminals.
              // (console_bars does not support dynamic total change; rebuild is simplest.)
              stdout.write('\n');
              progressBar = FillingBar(
                desc: 'Moving files',
                total: newTotal,
                width: 50,
              );
              progressBar.update(filesMovedCount);
            } else {
              progressBar.update(filesMovedCount);
            }
          } else if (kind == _OpKind.symlink) {
            symlinksCreatedCount++;
          } else if (kind == _OpKind.json) {
            jsonWritesCount++;
          } else {
            otherOpsCount++;
          }
        },
      )) {
        processedEntities++;
      }

      // 7) Finalize timing and UI
      stopwatch.stop();
      print(''); // newline after progress bar

      // 8) Build success result with split counters
      final messageBuffer = StringBuffer()
        ..write('Moved $filesMovedCount files to output directory')
        ..write(', created $symlinksCreatedCount symlinks');
      if (jsonWritesCount > 0) {
        messageBuffer.write(', wrote $jsonWritesCount JSON entries');
      }

      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: <String, dynamic>{
          'processedEntities': processedEntities,
          'transformedCount': transformedCount,
          'albumBehavior': context.config.albumBehavior.value,
          'filesMovedCount': filesMovedCount,
          'symlinksCreatedCount': symlinksCreatedCount,
          'jsonWritesCount': jsonWritesCount,
          'otherOpsCount': otherOpsCount,
          'filesPlanned': filesPlanned,
        },
        message: messageBuffer.toString(),
      );
    } catch (e) {
      stopwatch.stop();
      return StepResult.failure(
        stepName: name,
        duration: stopwatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to move files: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;

  /// Estimate how many REAL file operations (move/copy) will happen,
  /// excluding symlinks/shortcuts and JSON writes.
  /// Heuristic based on album behavior; supports multiple aliases and enum-ish names.
  int _estimateRealFileOpsPlanned(final ProcessingContext context) {
    final behaviorRaw = context.config.albumBehavior.value;
    final behavior = behaviorRaw.toString().toLowerCase();

    final bool isDuplicate = behavior.contains('duplicate') ||
        behavior.contains('copy') ||
        behavior.contains('dup') ||
        behavior.contains('duplicate_copy') ||
        behavior.contains('duplicate-copy') ||
        behavior.contains('albumbehavior.duplicate');

    final bool isJson = behavior.contains('json') ||
        behavior.contains('albumbehavior.json');

    // reverse/shortcut/nothing → treat as 1 real file per entity (links or none for the rest)
    int total = 0;
    for (final mediaEntity in context.mediaCollection.media) {
      final placements = mediaEntity.files.files.length;
      if (isDuplicate) {
        total += placements; // each placement is a real copy
      } else if (isJson) {
        total += 1; // only ALL_PHOTOS real file
      } else {
        total += 1; // one primary real file (ALL_PHOTOS or album), rest links or nothing
      }
    }
    return total;
  }

  /// Classify the operation kind without relying on unsupported reflection.
  /// We use a robust, compile-safe heuristic based on `toString()` contents and common suffixes.
  _OpKind _classifyOperationKind(final dynamic result) {
    final String text = (result?.toString() ?? '').toLowerCase();

    // Quick path: common words for symlink/shortcut/hardlink/junction
    if (text.contains('symlink') ||
        text.contains('shortcut') ||
        text.contains('junction') ||
        text.contains('hardlink') ||
        text.contains('mklink') ||
        text.contains('ln -s') ||
        text.contains('link ->') ||
        text.contains('created link') ||
        text.contains('create link')) {
      return _OpKind.symlink;
    }

    // Destinations that strongly indicate a shortcut/symlink (Windows/macOS/Linux)
    // We detect by common file extensions or patterns in the "destination" shown in toString().
    if (text.contains('.lnk') ||
        text.contains('.url') ||
        text.contains('.desktop') ||
        text.contains('.webloc')) {
      return _OpKind.symlink;
    }

    // JSON-related detection (side outputs or album metadata)
    if (text.contains('.json') || text.contains('json write') || text.contains('write json')) {
      return _OpKind.json;
    }

    // Clear signals of real file operations
    if (text.contains(' move ') ||
        text.contains(' moved ') ||
        text.contains('copy ') ||
        text.contains(' copied ') ||
        text.contains('rename') ||
        text.contains('renamed') ||
        text.contains('file ->') ||
        text.contains('to file')) {
      return _OpKind.file;
    }

    // Fallback: default to file to avoid under-counting progress
    return _OpKind.file;
  }

  /// Transform Pixel .MP/.MV files to .mp4 extension.
  ///
  /// Updates MediaEntity file paths to use .mp4 extension for better compatibility
  /// while preserving the original file content.
  Future<int> _transformPixelFiles(final ProcessingContext context) async {
    int transformedCount = 0;
    final updatedEntities = <MediaEntity>[];

    for (final mediaEntity in context.mediaCollection.media) {
      var hasChanges = false;
      final updatedFiles = <String?, File>{};

      for (final entry in mediaEntity.files.files.entries) {
        final albumName = entry.key;
        final file = entry.value;
        final String currentPath = file.path;
        final String extension = currentPath.toLowerCase();

        if (extension.endsWith('.mp') || extension.endsWith('.mv')) {
          // Create new path with .mp4 extension
          final String newPath =
              '${currentPath.substring(0, currentPath.lastIndexOf('.'))}.mp4';

          try {
            // Rename the physical file
            await file.rename(newPath);
            updatedFiles[albumName] = File(newPath);
            hasChanges = true;
            transformedCount++;

            if (context.config.verbose) {
              print('Transformed: ${file.path} -> $newPath');
            }
          } catch (e) {
            // If rename fails, keep original file reference
            updatedFiles[albumName] = file;
            print('Warning: Failed to transform ${file.path}: $e');
          }
        } else {
          // Keep original file reference
          updatedFiles[albumName] = file;
        }
      }

      // Create updated entity
      if (hasChanges) {
        final newFilesCollection = MediaFilesCollection.fromMap(updatedFiles);
        final updatedEntity = MediaEntity(
          files: newFilesCollection,
          dateTaken: mediaEntity.dateTaken,
          dateAccuracy: mediaEntity.dateAccuracy,
          dateTimeExtractionMethod: mediaEntity.dateTimeExtractionMethod,
          partnershared: mediaEntity.partnershared,
        );
        updatedEntities.add(updatedEntity);
      } else {
        updatedEntities.add(mediaEntity);
      }
    }

    // Replace all entities in the collection
    context.mediaCollection.clear();
    context.mediaCollection.addAll(updatedEntities);

    return transformedCount;
  }
}

enum _OpKind { file, symlink, json, other }
