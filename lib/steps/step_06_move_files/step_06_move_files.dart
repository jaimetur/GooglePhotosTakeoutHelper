import 'package:console_bars/console_bars.dart';
import 'package:gpth/gpth-lib.dart';

/// Step 6: Move files to output directory
///
/// Delegates the moving logic to the selected strategy (Nothing, JSON, Shortcut,
/// Reverse-Shortcut, Duplicate-Copy). Now we consider both primaryFile and
/// secondaryFiles per strategy requirements.
///
/// IMPORTANT (FileEntity model):
/// - After each move/copy/symlink, strategies MUST update the involved FileEntity:
///   fe.targetPath = <final path in output>;
///   fe.isShortcut = true when a shortcut is created (false otherwise).
class MoveFilesStep extends ProcessingStep {
  const MoveFilesStep() : super('Move Files');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    print('');
    final stopwatch = Stopwatch()..start();

    try {
      print('[Step 6/8] Moving files to Output folder (this may take a while)...');

      // Optional pre-pass: transform Pixel .MP/.MV → .mp4 ONLY on primary files (in-place, still in input).
      int transformedCount = 0;
      if (context.config.transformPixelMp) {
        transformedCount = await _transformPixelPrimaries(context);
        if (context.config.verbose) {
          print('Transformed $transformedCount Pixel .MP/.MV primary files to .mp4');
        }
      }

      final progressBar = FillingBar(
        desc: '[Step 6/8] Moving entities',
        total: context.mediaCollection.length,
        width: 50,
      );

      final movingContext = MovingContext(
        outputDirectory: context.outputDirectory,
        dateDivision: context.config.dateDivision,
        albumBehavior: context.config.albumBehavior,
      );

      final movingService = MediaEntityMovingService();

      int entitiesProcessed = 0;
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
      )) {
        entitiesProcessed++;
        progressBar.update(entitiesProcessed);
      }

      // Summary based on lastResults from service
      int primaryMovedCount = 0;
      int nonPrimaryMoves = 0;
      int symlinksCreated = 0;

      bool _samePath(final String a, final String b) =>
          a.replaceAll('\\', '/').toLowerCase() ==
          b.replaceAll('\\', '/').toLowerCase();

      for (final r in movingService.lastResults) {
        if (!r.success) continue;
        switch (r.operation.operationType) {
          case MediaEntityOperationType.move:
            final src = r.operation.sourceFile.path;
            final prim = r.operation.mediaEntity.primaryFile.sourcePath;
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
            // not headline
            break;
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

  /// Transform Pixel .MP/.MV → .mp4 ONLY for primary files (in input).
  /// Since it still lives in input, update the FileEntity **sourcePath**.
  Future<int> _transformPixelPrimaries(final ProcessingContext context) async {
    int transformed = 0;

    final collection = context.mediaCollection;
    final entities = collection.asList(); // snapshot

    for (final entity in entities) {
      final primary = entity.primaryFile;
      final lower = primary.path.toLowerCase();

      if (lower.endsWith('.mp') || lower.endsWith('.mv')) {
        final oldPath = primary.path;
        final dot = oldPath.lastIndexOf('.');
        final newPath =
            dot > 0 ? '${oldPath.substring(0, dot)}.mp4' : '$oldPath.mp4';

        try {
          final renamed = await primary.asFile().rename(newPath);
          // IMPORTANT: still input → update sourcePath, not targetPath
          primary.sourcePath = renamed.path;
          transformed++;
        } catch (e) {
          print('Warning: Failed to transform ${primary.path}: $e');
        }
      }
    }

    return transformed;
  }
}
