import 'dart:async';

import '../../../../shared/concurrency_manager.dart';
import '../../../../shared/global_pools.dart';
import '../../../models/media_entity_collection.dart';
import '../../core/logging_service.dart';
import 'file_operation_service.dart';
import 'moving_context_model.dart';
import 'path_generator_service.dart';
import 'strategies/media_entity_moving_strategy.dart';
import 'strategies/media_entity_moving_strategy_factory.dart';
import 'symlink_service.dart';

/// Modern media moving service using immutable MediaEntity
///
/// This service coordinates all the moving logic components and provides
/// a clean interface for moving media files according to configuration.
/// Uses MediaEntity exclusively for better performance and immutability.
class MediaEntityMovingService with LoggerMixin {
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

  /// Returns the exact number of low-level operations that would be performed.
  ///
  /// Semantics:
  /// - Each File entry in `mediaEntity.files.files` generally maps to 1 operation
  ///   (primary move + per-album copy/symlink/shortcut depending on album behavior).
  /// - JSON mode: we only move to `ALL_PHOTOS` → exactly 1 operation per entity.
  /// - Nothing/Shortcut/Duplicate/ReverseShortcut modes: equals to the number of
  ///   placements (map entries).
  ///
  /// This does **not** touch the disk and has no side effects.
  Future<int> estimateOperationCount(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async {
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

    // Count per-entity placements
    int total = 0;
    for (final entity in entityCollection.entities) {
      final placements = entity.files.files.length;

      // JSON mode → only primary placement is materialized
      if (_isJsonMode(context)) {
        total += 1;
      } else {
        total += placements;
      }
    }

    // Optionally include finalize() outputs if those generate files;
    // by default, finalize is metadata-only and does not add file ops to count.
    return total;
  }

  /// Moves media entities according to the provided context using parallel processing
  ///
  /// Progress Semantics CHANGE (entity-level):
  ///   The returned stream now reports the NUMBER OF ENTITIES processed, not
  ///   the number of low-level file operations (move + symlink + duplicate, etc.).
  ///   Each MediaEntity contributes +1 to the progress count regardless of how
  ///   many underlying operations its strategy performs. This provides a
  ///   stable, cross-platform progress metric (Windows symlink limitations
  ///   previously caused inconsistent counts).
  ///
  /// [entityCollection] Collection of media entities to process
  /// [context] Configuration and context for the moving operations
  /// [maxConcurrent] Maximum number of concurrent operations (optional)
  /// [batchSize] Number of entities to process in each batch
  /// Returns a stream of progress updates (number of entities processed)
  Stream<int> moveMediaEntities(
    final MediaEntityCollection entityCollection,
    final MovingContext context, {
    int? maxConcurrent,
    final int batchSize = 100,
    final void Function(MediaEntityMovingResult op)? onOperation,
  }) async* {
    // Derive sensible default if not provided
    maxConcurrent ??= ConcurrencyManager()
        .concurrencyFor(ConcurrencyOperation.moveCopy)
        .clamp(4, 128);
    logDebug('Starting $maxConcurrent threads (move/copy concurrency)');
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

    final entities = entityCollection.entities.toList();
    int processedCount = 0; // entity-level count
    final allResults = <MediaEntityMovingResult>[];

    // Process entities in batches to avoid overwhelming the system
    for (int i = 0; i < entities.length; i += batchSize) {
      final batchEnd = (i + batchSize).clamp(0, entities.length);
      final batch = entities.sublist(i, batchEnd);

      // Process batch with controlled concurrency
      final futures = <Future<List<MediaEntityMovingResult>>>[];
      final pool = GlobalPools.poolFor(ConcurrencyOperation.moveCopy);
      for (final entity in batch) {
        futures.add(
          pool.withResource(() async {
            final results = <MediaEntityMovingResult>[];
            // ignore: prefer_foreach
            await for (final result in strategy.processMediaEntity(
              entity,
              context,
            )) {
              results.add(result);
              if (onOperation != null) onOperation(result);
            }
            return results;
          }),
        );
      }

      // Wait for batch completion
      final batchResults = await Future.wait(futures);
      batchResults.forEach(allResults.addAll);

      // Increment by number of entities in this batch (entity-level progress)
      processedCount += batchResults.length;
      yield processedCount; // entities processed so far
    }

    // Finalize
    final finalizationResults = await strategy.finalize(context, entities);
    for (final r in finalizationResults) {
      allResults.add(r);
      if (onOperation != null) onOperation(r);
    }

    if (context.verbose) {
      _printSummary(allResults, strategy);
    }
  }

  void _printSummary(
    final List<MediaEntityMovingResult> results,
    final MediaEntityMovingStrategy strategy,
  ) {
    final successful = results.where((final r) => r.success).length;
    final failed = results.where((final r) => !r.success).length;

    print('\n=== Moving Summary (${strategy.name}) ===');
    print('Successful operations: $successful');
    print('Failed operations: $failed');
    print('Total operations: ${results.length}');

    if (failed > 0) {
      print('\nErrors encountered:');
      results.where((final r) => !r.success).take(5).forEach((final result) {
        print(
          '  • ${result.operation.sourceFile.path}: ${result.errorMessage}',
        );
      });
      if (failed > 5) {
        print('  ... and ${failed - 5} more errors');
      }
    }
  }

  bool _isJsonMode(final MovingContext context) {
    // English comment: detect the JSON behavior. Adjust if your enum/value differs.
    // Many codebases expose something like: context.albumBehavior.value == 'json'
    final value = context.albumBehavior.value.toString().toLowerCase();
    return value.contains('json');
  }
}

// Concurrency now managed via package:pool.
