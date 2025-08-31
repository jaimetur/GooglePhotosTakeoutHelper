import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:gpth/gpth-lib.dart';

/// Step 7: Move files to output directory
///
/// This step delegates **all moving logic** to the selected moving strategy
/// (Shortcut, Duplicate-Copy, Reverse-Shortcut, JSON, Nothing).
/// It processes **only the primary file** of each entity (per the new model).
/// Secondary files were already removed/moved in Step 3.
///
/// Notes:
/// - Optional Pixel .MP/.MV → .mp4 transform is applied ONLY to the entity's
///   primary file (and the entity is updated in the collection before moving).
/// - No direct album manipulation here; strategies are responsible for it.
/// - We keep progress and a concise summary based on the results reported
///   by MediaEntityMovingService/strategies.
class MoveFilesStep extends ProcessingStep {
  const MoveFilesStep() : super('Move Files');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    print('');
    final stopwatch = Stopwatch()..start();

    try {
      print('[Step 7/8] Moving files to Output folder (this may take a while)...');

      // 1) Optional pre-pass: transform Pixel .MP/.MV → .mp4 on PRIMARY files.
      int transformedCount = 0;
      if (context.config.transformPixelMp) {
        transformedCount = await _transformPixelPrimaries(context);
        if (context.config.verbose) {
          print('Transformed $transformedCount Pixel .MP/.MV primary files to .mp4');
        }
      }

      // 2) Move entities via strategies
      final progressBar = FillingBar(
        desc: '[Step 7/8] Moving entities',
        total: context.mediaCollection.length,
        width: 50,
      );

      final movingContext = MovingContext(
        outputDirectory: context.outputDirectory,
        dateDivision: context.config.dateDivision,
        albumBehavior: context.config.albumBehavior,
      );

      final movingService = MediaEntityMovingService();

      // keep original primary paths to diagnose leftovers if desired
      final originalPrimaryPaths = <String>[];
      for (final e in context.mediaCollection.entities) {
        originalPrimaryPaths.add(e.primaryFile.path);
      }

      int entitiesProcessed = 0;
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
      )) {
        entitiesProcessed++;
        progressBar.update(entitiesProcessed);
      }

      // 3) Counters / summary (computed from lastResults)
      int primaryMovedCount = 0;
      int nonPrimaryMoves = 0; // should be 0 under the new pipeline
      int symlinksCreated = 0;

      bool _samePath(final String a, final String b) =>
          a.replaceAll('\\', '/').toLowerCase() ==
          b.replaceAll('\\', '/').toLowerCase();

      for (final r in movingService.lastResults) {
        if (!r.success) continue;
        switch (r.operation.operationType) {
          case MediaEntityOperationType.move:
            final src = r.operation.sourceFile.path;
            final prim = r.operation.mediaEntity.primaryFile.path;
            if (_samePath(src, prim)) {
              primaryMovedCount++;
            } else {
              nonPrimaryMoves++;
            }
            break;
          case MediaEntityOperationType.createSymlink:
          case MediaEntityOperationType.createReverseSymlink:
            symlinksCreated++;
            break;
          case MediaEntityOperationType.copy:
          case MediaEntityOperationType.createJsonReference:
            // not counted in headline
            break;
        }
      }

      // 4) Lightweight leftover diagnosis (primaries only)
      if (context.config.verbose) {
        final movedPrimarySources = <String>{};
        for (final r in movingService.lastResults) {
          if (!r.success) continue;
          if (r.operation.operationType == MediaEntityOperationType.move) {
            movedPrimarySources.add(r.operation.sourceFile.path);
          }
        }

        final leftovers = <String>[];
        for (final p in originalPrimaryPaths) {
          final f = File(p);
          if (!movedPrimarySources.contains(p) && f.existsSync()) {
            leftovers.add(p);
          }
        }

        if (leftovers.isEmpty) {
          print('\n[Verification] No leftover primary source files detected.');
        } else {
          print('\n[Verification] Leftover primary sources still present on disk:');
          for (final p in leftovers) {
            print('  • $p');
          }
          print('  Total leftovers: ${leftovers.length}\n');
        }
      }

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'entitiesProcessed': entitiesProcessed,
          'transformedCount': transformedCount,
          'albumBehavior': context.config.albumBehavior.value,
          'primaryMovedCount': primaryMovedCount,
          'nonPrimaryMoves': nonPrimaryMoves,
          'symlinksCreated': symlinksCreated,
        },
        message:
            'Moved $primaryMovedCount primary files, created $symlinksCreated symlinks'
            '${nonPrimaryMoves > 0 ? ', non-primary moves: $nonPrimaryMoves' : ''}'
            '${transformedCount > 0 ? ', transformed $transformedCount Pixel files to .mp4' : ''}',
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

  /// Transform Pixel .MP/.MV → .mp4 ONLY for primary files,
  /// updating the entities in the collection before moving.
  Future<int> _transformPixelPrimaries(final ProcessingContext context) async {
    int transformed = 0;

    final collection = context.mediaCollection;
    final entities = collection.asList(); // snapshot

    for (int idx = 0; idx < entities.length; idx++) {
      final entity = entities[idx];
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      if (lower.endsWith('.mp') || lower.endsWith('.mv')) {
        final dot = primary.path.lastIndexOf('.');
        final newPath = dot > 0
            ? '${primary.path.substring(0, dot)}.mp4'
            : '${primary.path}.mp4';

        try {
          final renamed = await primary.rename(newPath);

          // Rebuild the entity WITHOUT using withPrimaryFile(...)
          final updated = MediaEntity(
            primaryFile: renamed,
            secondaryFiles: entity.secondaryFiles,
            belongToAlbums: entity.belongToAlbums,
            dateTaken: entity.dateTaken,
            dateAccuracy: entity.dateAccuracy,
            dateTimeExtractionMethod: entity.dateTimeExtractionMethod,
            partnershared: entity.partnershared,
          );

          collection.replaceAt(idx, updated);
          transformed++;
        } catch (e) {
          print('Warning: Failed to transform ${primary.path}: $e');
        }
      }
    }

    return transformed;
  }
}
