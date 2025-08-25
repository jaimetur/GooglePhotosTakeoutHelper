import 'dart:io';
import 'dart:math';

import 'package:console_bars/console_bars.dart';

import '../entities/media_entity.dart';
import '../models/pipeline_step_model.dart';
import '../services/file_operations/moving/media_entity_moving_service.dart';
import '../services/file_operations/moving/moving_context_model.dart';
import '../value_objects/media_files_collection.dart';

/// Step 7: Move files to output directory
///
/// This final step organizes and relocates all processed media files from the
/// Google Photos Takeout structure to the user's desired output organization.
/// It applies album behavior, date organization, and file operation modes.
class MoveFilesStep extends ProcessingStep {
  const MoveFilesStep() : super('Move Files');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();

    try {
      // 1) Optional Pixel .MP/.MV transformation BEFORE counting ops
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

      // 3) Get the REAL total of file ops (move/copy/rename) excluding symlinks/JSON
      final totalOps = await movingService.estimateRealFileOperationCount(
        context.mediaCollection,
        movingContext,
      );

      // 4) Progress bar for REAL files only (no symlinks/JSON)
      final progressBar = FillingBar(
        desc: 'Moving files',
        total: max(1, totalOps),
        width: 50,
      );

      // 5) Counters
      int processedEntities = 0;    // informational
      int filesMovedCount = 0;      // real file ops (unique src->dst)
      int symlinksCreatedCount = 0; // symlink/shortcut ops
      int jsonWritesCount = 0;      // JSON writes (if any)
      int otherOpsCount = 0;        // anything else we don't want to count as "file"

      // Dedup set to ensure we count each real file op ONCE
      final Set<String> countedFileOps = <String>{};

      // 6) Consume stream; classify every low-level op
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
        onOperation: (final result) {
          final _OpKind kind = _classify(result);
          if (kind == _OpKind.symlink) {
            symlinksCreatedCount++;
            return;
          }
          if (kind == _OpKind.json) {
            jsonWritesCount++;
            return;
          }

          // For real files, dedupe by (src -> dst)
          final _Paths p = _extractPaths(result);
          if (p.isRealFileMoveOrCopy) {
            final String key = '${p.src} -> ${p.dst}';
            if (countedFileOps.add(key)) {
              filesMovedCount++;
              // Keep the visual bar within [0..total]; do NOT resize it (prevents blank lines).
              final int progress = min(filesMovedCount, progressBar.total);
              progressBar.update(progress);
            }
          } else {
            // Non-real or unknown ops -> do not touch the bar
            otherOpsCount++;
          }
        },
      )) {
        processedEntities++;
      }

      // 7) Finish timing and UI
      stopwatch.stop();
      print(''); // newline after the progress bar line

      // 8) Build success result
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
          'totalOperationsPlanned': totalOps,
          'uniqueFileOpsCounted': countedFileOps.length,
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

  // ---------- Helpers: operation classification & path extraction ----------

  /// Minimal, compile-safe operation classifier.
  /// Only `move/copy/rename` with real destination file is treated as _OpKind.file.
  _OpKind _classify(final dynamic result) {
    final String t = (result?.toString() ?? '').toLowerCase();

    // Obvious symlink/shortcut markers
    if (t.contains('symlink') ||
        t.contains('shortcut') ||
        t.contains('junction') ||
        t.contains('hardlink') ||
        t.contains('mklink') ||
        t.contains('ln -s') ||
        t.contains('link ->') ||
        t.contains('.lnk') ||
        t.contains('.url') ||
        t.contains('.desktop') ||
        t.contains('.webloc')) {
      return _OpKind.symlink;
    }

    // JSON writes (album metadata or mapping files)
    if (t.contains('.json') || t.contains('json write') || t.contains('write json')) {
      return _OpKind.json;
    }

    // Otherwise, leave final decision to path extraction (real file dst vs no-op)
    final _Paths p = _extractPaths(result);
    if (p.isRealFileMoveOrCopy) return _OpKind.file;

    return _OpKind.other;
  }

  /// Extract source/destination paths defensively from `result`.
  /// We try common fields first (operation.sourceFile.path / operation.destinationFile.path),
  /// then fall back to parsing the `toString()`.
  _Paths _extractPaths(final dynamic result) {
    String? src;
    String? dst;

    try {
      final dynamic op = (result as dynamic).operation;
      try {
        final dynamic sf = op.sourceFile;
        if (sf is File) {
          src = sf.path;
        } else if (sf is String) {
          src = sf;
        } else {
          try {
            src = sf?.path?.toString();
          } catch (_) {}
        }
      } catch (_) {}

      try {
        final dynamic df = op.destinationFile ?? op.targetFile;
        if (df is File) {
          dst = df.path;
        } else if (df is String) {
          dst = df;
        } else {
          try {
            dst = df?.path?.toString();
          } catch (_) {}
        }
      } catch (_) {}

      // Some services expose string paths directly:
      try {
        dst ??= op.destinationPath?.toString();
      } catch (_) {}
    } catch (_) {
      // ignore and fall through to parsing toString()
    }

    // Fallback: try to parse "... source: <path> ... dest: <path> ..."
    if (src == null || dst == null) {
      final String text = (result?.toString() ?? '');
      final RegExp pathLike = RegExp(r'([A-Za-z]:\\|/)[^\s"]+'); // crude but effective
      final matches = pathLike.allMatches(text).map((m) => m.group(0)!).toList();
      if (src == null && matches.isNotEmpty) src = matches.first;
      if (dst == null && matches.length > 1) dst = matches.last;
    }

    return _Paths(src: src, dst: dst);
  }

  /// Transform Pixel .MP/.MV files to .mp4 extension.
  ///
  /// Updates MediaEntity file paths to use .mp4 extension while preserving content.
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
        final String lower = currentPath.toLowerCase();

        if (lower.endsWith('.mp') || lower.endsWith('.mv')) {
          final String newPath =
              '${currentPath.substring(0, currentPath.lastIndexOf('.'))}.mp4';
          try {
            await file.rename(newPath);
            updatedFiles[albumName] = File(newPath);
            hasChanges = true;
            transformedCount++;
            if (context.config.verbose) {
              print('Transformed: ${file.path} -> $newPath');
            }
          } catch (e) {
            updatedFiles[albumName] = file;
            print('Warning: Failed to transform ${file.path}: $e');
          }
        } else {
          updatedFiles[albumName] = file;
        }
      }

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

    context.mediaCollection.clear();
    context.mediaCollection.addAll(updatedEntities);

    return transformedCount;
  }
}

enum _OpKind { file, symlink, json, other }

/// Small value object to carry extracted paths and related logic.
class _Paths {
  const _Paths({required this.src, required this.dst});

  final String? src;
  final String? dst;

  bool get hasSrcAndDst => src != null && dst != null;

  bool get isJsonDst => (dst ?? '').toLowerCase().endsWith('.json');

  bool get isShortcutDst {
    final d = (dst ?? '').toLowerCase();
    return d.endsWith('.lnk') ||
        d.endsWith('.url') ||
        d.endsWith('.desktop') ||
        d.endsWith('.webloc');
  }

  bool get isSamePath => hasSrcAndDst && src == dst;

  /// Treat as a real file operation **only** if:
  /// - src and dst exist,
  /// - they differ,
  /// - destination is not JSON and not a shortcut file.
  bool get isRealFileMoveOrCopy =>
      hasSrcAndDst && !isSamePath && !isJsonDst && !isShortcutDst;
}
