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
/// Orchestrates the physical reorganization of media into the output structure.
/// Progress bar reflects *real file operations* (move/copy/rename) only.
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

      // 2) Build moving context & service
      final movingContext = MovingContext.fromConfig(
        context.config,
        context.outputDirectory,
      );
      final movingService = MediaEntityMovingService();

      // 3) Totals for robust accounting
      final int lowLevelTotal = await movingService.estimateOperationCount(
        context.mediaCollection,
        movingContext,
      ); // files + symlinks + json

      final int realFilesTotal = await movingService.estimateRealFileOperationCount(
        context.mediaCollection,
        movingContext,
      ); // only real files

      // 4) Progress bar for *real files only*
      final progressBar = FillingBar(
        desc: 'Moving files',
        total: max(1, realFilesTotal),
        width: 50,
      );

      // 5) Authoritative counters from service summary (if provided)
      MediaMoveCounters? summary;

      // 6) Local counters for progress and fallback
      int processedEntities = 0;
      int progressSoFar = 0; // real-file progress (drives the bar)

      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
        onRealFile: (final File src, final File dst) {
          progressSoFar++;
          progressBar.update(min(progressSoFar, progressBar.total));
        },
        onSummary: (final MediaMoveCounters counters) {
          summary = counters;
        },
      )) {
        processedEntities++;
      }

      // 7) Finalize UI
      stopwatch.stop();
      print(''); // close the progress bar line

      // 8) Reconcile counts (robust)
      // Prefer service-provided counts; if symlinks look wrong, compute fallback.
      final int filesMovedCount = summary?.realFiles ?? progressSoFar;
      final int jsonWritesCount = summary?.jsonWrites ?? 0;

      // Algebraic fallback for symlinks:
      // lowLevel = files + symlinks + json  => symlinks = lowLevel - files - json
      int symlinksCreatedCount = summary?.symlinks ?? -1; // -1 indicates "unknown/unreliable"
      if (symlinksCreatedCount < 0) {
        symlinksCreatedCount = max(0, lowLevelTotal - filesMovedCount - jsonWritesCount);
      }

      // 9) Build success result
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
          'lowLevelTotalPlanned': lowLevelTotal,
          'realFilesTotalPlanned': realFilesTotal,
          'realFilesProgressObserved': progressSoFar,
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

  /// Transform Pixel .MP/.MV files to .mp4 extension (rename on disk and update entities).
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
