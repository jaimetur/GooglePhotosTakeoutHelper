import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:gpth/gpth-lib.dart';

/// Modern media moving service using immutable MediaEntity
///
/// This service coordinates all the moving logic components and provides
/// a clean interface for moving media files according to configuration.
/// Uses MediaEntity exclusively for better performance and immutability.
///
/// ⚠️ Model note:
/// MediaEntity now exposes:
///   - `primaryFile` (the only physical source to move/copy/link),
///   - `secondaryFiles` (kept as metadata; duplicates already removed/moved in Step 3),
///   - album associations via `belongToAlbums` / `albumNames`.
/// There is NO `files` map anymore. This service therefore expects only one
/// physical "move" per entity (the primary).
class MediaEntityMovingService {
  MediaEntityMovingService()
      : _strategyFactory = MediaEntityMovingStrategyFactory(
          FileOperationService(),
          PathGeneratorService(),
          SymlinkService(),
        );

  /// Custom constructor for dependency injection (useful for testing)
  MediaEntityMovingService.withDependencies({
    required final FileOperationService fileService,
    required final PathGeneratorService pathService,
    required final SymlinkService symlinkService,
  }) : _strategyFactory = MediaEntityMovingStrategyFactory(
          fileService,
          pathService,
          symlinkService,
        );

  final MediaEntityMovingStrategyFactory _strategyFactory;

  // Keeps the last full set of results for verification/reporting purposes
  final List<MediaEntityMovingResult> _lastResults = [];

  /// Expose an immutable view of the last results after a run
  List<MediaEntityMovingResult> get lastResults => List.unmodifiable(_lastResults);

  /// Moves media entities according to the provided context
  ///
  /// Emits progress as "entities processed" (not operations).
  Stream<int> moveMediaEntities(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async* {
    // Reset previous results
    _lastResults.clear();

    // Create the appropriate strategy for the album behavior
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);

    // Validate the context for this strategy
    strategy.validateContext(context);

    int processedEntities = 0;
    final allResults = <MediaEntityMovingResult>[];

    // Process each media entity
    for (final entity in entityCollection.entities) {
      // We only require a single MOVE for the primary source.
      final String primarySourcePath = entity.primaryFile.path;
      var primaryMoveEmitted = false;

      await for (final result in strategy.processMediaEntity(entity, context)) {
        allResults.add(result);

        // Coverage: mark as emitted when we see a MOVE (for the primary).
        if (result.operation.operationType == MediaEntityOperationType.move) {
          // Some strategies may emit MOVE(s) for non-primary sources (legacy),
          // but the one we *require* is the one whose source is the original primary.
          final String opSrc = result.operation.sourceFile.path;
          if (_samePath(opSrc, primarySourcePath)) {
            primaryMoveEmitted = true;
          }
        }

        if (!result.success && context.verbose) {
          _logError(result);
        } else if (context.verbose) {
          _logResult(result);
        }
      }

      // Inject a synthetic failure if the strategy didn't emit the primary MOVE.
      if (!primaryMoveEmitted) {
        final syntheticOp = MediaEntityMovingOperation(
          sourceFile: File(primarySourcePath),
          targetDirectory: Directory(context.outputDirectory.path),
          operationType: MediaEntityOperationType.move, // nominal intent
          mediaEntity: entity,
        );
        final synthetic = MediaEntityMovingResult.failure(
          operation: syntheticOp,
          errorMessage: 'No MOVE operation emitted by strategy for primary file',
          duration: Duration.zero,
        );
        allResults.add(synthetic);
        if (context.verbose) {
          _logError(synthetic);
        }
      }

      processedEntities++;
      yield processedEntities;
    }

    // Finalization hook for the active strategy
    try {
      final finalizationResults = await strategy.finalize(
        context,
        entityCollection.entities.toList(),
      );
      allResults.addAll(finalizationResults);

      for (final result in finalizationResults) {
        if (!result.success && context.verbose) {
          _logError(result);
        } else if (context.verbose) {
          _logResult(result);
        }
      }
    } catch (e) {
      if (context.verbose) {
        print('[Error] Strategy finalization failed: $e');
      }
    }

    // Store results for external verification (MoveFilesStep)
    _lastResults
      ..clear()
      ..addAll(allResults);

    // Print summary
    _printSummary(allResults);
  }

  /// High-performance parallel media moving with batched operations.
  ///
  /// Emits progress as "entities processed". Concurrency is per-entity.
  Stream<int> moveMediaEntitiesParallel(
    final MediaEntityCollection entityCollection,
    final MovingContext context, {
    final int maxConcurrent = 10,
    final int batchSize = 100,
  }) async* {
    // Reset previous results
    _lastResults.clear();

    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

    final entities = entityCollection.entities.toList();
    int processedEntities = 0;
    final allResults = <MediaEntityMovingResult>[];

    // Process entities in batches to avoid overwhelming the system
    for (int i = 0; i < entities.length; i += batchSize) {
      final batchEnd = (i + batchSize).clamp(0, entities.length);
      final batch = entities.sublist(i, batchEnd);

      // Process batch with controlled concurrency
      final futures = <Future<List<MediaEntityMovingResult>>>[];
      final semaphore = _Semaphore(maxConcurrent);

      for (final entity in batch) {
        futures.add(
          semaphore.acquire().then((_) async {
            try {
              final results = <MediaEntityMovingResult>[];
              final String primarySourcePath = entity.primaryFile.path;
              var primaryMoveEmitted = false;

              await for (final r in strategy.processMediaEntity(entity, context)) {
                results.add(r);
                if (r.operation.operationType == MediaEntityOperationType.move) {
                  if (_samePath(r.operation.sourceFile.path, primarySourcePath)) {
                    primaryMoveEmitted = true;
                  }
                }
              }

              if (!primaryMoveEmitted) {
                results.add(
                  MediaEntityMovingResult.failure(
                    operation: MediaEntityMovingOperation(
                      sourceFile: File(primarySourcePath),
                      targetDirectory: Directory(context.outputDirectory.path),
                      operationType: MediaEntityOperationType.move,
                      mediaEntity: entity,
                    ),
                    errorMessage: 'No MOVE operation emitted by strategy for primary file',
                    duration: Duration.zero,
                  ),
                );
              }

              return results;
            } finally {
              semaphore.release();
            }
          }),
        );
      }

      // Wait for batch completion
      final batchResults = await Future.wait(futures);
      for (final results in batchResults) {
        allResults.addAll(results);
        processedEntities++; // one entity completed
        yield processedEntities;
      }
    }

    // Finalize
    try {
      final finalizationResults = await strategy.finalize(context, entities);
      allResults.addAll(finalizationResults);
    } catch (e) {
      if (context.verbose) {
        print('[Error] Strategy finalization failed: $e');
      }
    }

    // Store results for external verification (MoveFilesStep)
    _lastResults
      ..clear()
      ..addAll(allResults);

    // Print summary
    _printSummary(allResults);
  }

  void _logResult(final MediaEntityMovingResult result) {
    final operation = result.operation;
    final status = result.success ? 'SUCCESS' : 'FAILED';
    print('[${operation.operationType.name.toUpperCase()}] $status: ${operation.sourceFile.path}');
    if (result.resultFile != null) {
      print('  → ${result.resultFile!.path}');
    }
  }

  void _logError(final MediaEntityMovingResult result) {
    print(
      '[Error] Failed to process ${result.operation.sourceFile.path}: '
      '${result.errorMessage}',
    );
  }

  void _printSummary(final List<MediaEntityMovingResult> results) {
    int primaryMoves = 0;
    int nonPrimaryMoves = 0; // e.g., if a legacy strategy moved something else
    int symlinksCreated = 0;
    int failures = 0;

    for (final r in results) {
      if (!r.success) {
        failures++;
        continue;
      }

      switch (r.operation.operationType) {
        case MediaEntityOperationType.move:
          final src = r.operation.sourceFile.path;
          final prim = r.operation.mediaEntity.primaryFile.path;
          if (_samePath(src, prim)) {
            primaryMoves++;
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
          // not part of headline counters
          break;
      }
    }

    final totalOps = results.length;

    print('');
    print('\n=== Moving Summary ===');
    print('Primary files moved: $primaryMoves');
    print('Non-primary moves: $nonPrimaryMoves'); // should be 0 under the new pipeline
    print('Symlinks created: $symlinksCreated');
    print('Failures: $failures');
    print('Total operations: $totalOps');

    if (failures > 0) {
      print('\nErrors encountered:');
      results.where((final r) => !r.success).take(5).forEach((final result) {
        print('  • ${result.operation.sourceFile.path}: ${result.errorMessage}');
      });
      if (failures > 5) {
        print('  ... and ${failures - 5} more errors');
      }
    }
  }

  bool _samePath(final String a, final String b) =>
      a.replaceAll('\\', '/').toLowerCase() ==
      b.replaceAll('\\', '/').toLowerCase();
}

/// Simple semaphore implementation for controlling concurrency
class _Semaphore {
  _Semaphore(this.maxCount) : _currentCount = maxCount;

  final int maxCount;
  int _currentCount;
  final Queue<Completer<void>> _waitQueue = Queue<Completer<void>>();

  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeFirst();
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}
