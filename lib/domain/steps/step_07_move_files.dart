import 'dart:io';
import 'dart:math';

import 'package:console_bars/console_bars.dart';

import '../entities/media_entity.dart';
import '../models/pipeline_step_model.dart';
import '../services/file_operations/moving/media_entity_moving_service.dart';
import '../services/file_operations/moving/moving_context_model.dart';
import '../value_objects/media_files_collection.dart';

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

      // 5) Counters from service summary (authoritative)
      int processedEntities = 0; // informational
      MediaMoveCounters? summary; // will be set by onSummary

      // ✅ we maintain our own progress counter
      int progressSoFar = 0;

      // 6) Consume stream; progress is driven by onRealFile (1 tick per real file)
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
        onRealFile: (final File src, final File dst) {
          progressSoFar++;
          // Update bar with our local counter, capped to totalOps
          progressBar.update(min(progressSoFar, progressBar.total));
        },
        onSummary: (final MediaMoveCounters counters) {
          summary = counters;
        },
      )) {
        processedEntities++;
      }

      // 7) Finish timing and UI
      stopwatch.stop();
      print(''); // newline after the progress bar

      // 8) Use authoritative counters from the service (fallback to zeros if null)
      final filesMovedCount = summary?.realFiles ?? 0;
      final symlinksCreatedCount = summary?.symlinks ?? 0;
      final jsonWritesCount = summary?.jsonWrites ?? 0;
      final othersCount = summary?.others ?? 0;

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
          'otherOpsCount': othersCount,
          'totalOperationsPlanned': totalOps,
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
