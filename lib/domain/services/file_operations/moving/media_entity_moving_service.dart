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

  /// Returns the exact number of *low-level operations* that would be performed.
  ///
  /// Semantics:
  /// - Each File entry in `mediaEntity.files.files` generally maps to 1 operation
  ///   (primary + per-album placement). Depending on album behavior, a placement
  ///   can be a real copy/move or a symlink/shortcut.
  /// - JSON mode: only 1 operation per entity (materialize in `ALL_PHOTOS`).
  /// - Shortcut/Reverse/Nothing/Duplicate modes: equals the number of placements
  ///   (map entries). For Shortcut/Reverse/Nothing, many of those placements
  ///   may be links rather than real copies.
  ///
  /// This does **not** touch the disk and has no side effects.
  Future<int> estimateOperationCount(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async {
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

    // Count per-entity placements (low-level ops of any kind: file or link)
    int total = 0;
    final mode = _behavior(context);

    for (final entity in entityCollection.entities) {
      final placements = entity.files.files.length;

      if (mode.isJson) {
        total += 1; // only primary materialized
      } else {
        total += placements; // each placement is an op (file or link)
      }
    }

    // Note: finalize() is typically metadata-only; if it generates outputs,
    // you may add them here to the count.
    return total;
  }

  /// Returns the exact number of *real file operations* (move/copy/rename),
  /// explicitly excluding symlinks/shortcuts and JSON writes.
  ///
  /// Semantics:
  /// - Duplicate (copy) mode: every placement is a real file op → sum(placements).
  /// - JSON mode: exactly 1 real file op per entity (ALL_PHOTOS only).
  /// - Shortcut/Reverse/Nothing modes: exactly 1 real file op per entity
  ///   (the primary placement). Album placements are links or no-op.
  ///
  /// This does **not** touch the disk and has no side effects.
  Future<int> estimateRealFileOperationCount(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async {
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

    int total = 0;
    final mode = _behavior(context);

    for (final entity in entityCollection.entities) {
      final placements = entity.files.files.length;

      if (mode.isDuplicate) {
        // Each placement is a real copy
        total += placements;
      } else if (mode.isJson) {
        // Only primary materialized
        total += 1;
      } else {
        // Shortcut / Reverse / Nothing → one real file, rest links or none
        total += 1;
      }
    }
    return total;
  }

  /// Moves media entities according to the provided context using parallel processing.
  ///
  /// Progress Semantics (entity-level):
  ///   The returned stream reports the NUMBER OF ENTITIES processed, not
  ///   the number of low-level operations (move + symlink + duplicate, etc.).
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

  /// Behavior helpers --------------------------------------------------------

  _AlbumBehaviorFlags _behavior(final MovingContext context) {
    final raw = context.albumBehavior.value.toString().toLowerCase();

    final isDuplicate = raw.contains('duplicate') ||
        raw.contains('duplicate_copy') ||
        raw.contains('duplicate-copy') ||
        raw.contains('copy') ||
        raw.contains('dup') ||
        raw.contains('albumbehavior.duplicate');

    final isJson = raw.contains('json') ||
        raw.contains('albumbehavior.json');

    final isShortcut = raw.contains('shortcut') ||
        raw.contains('symlink') ||
        raw.contains('link') ||
        raw.contains('albumbehavior.shortcut');

    final isReverse = raw.contains('reverse') ||
        raw.contains('albumbehavior.reverse');

    final isNothing = raw.contains('nothing') ||
        raw.contains('none') ||
        raw.contains('albumbehavior.nothing');

    return _AlbumBehaviorFlags(
      isDuplicate: isDuplicate,
      isJson: isJson,
      isShortcut: isShortcut,
      isReverse: isReverse,
      isNothing: isNothing,
    );
  }
}

class _AlbumBehaviorFlags {
  const _AlbumBehaviorFlags({
    required this.isDuplicate,
    required this.isJson,
    required this.isShortcut,
    required this.isReverse,
    required this.isNothing,
  });

  final bool isDuplicate;
  final bool isJson;
  final bool isShortcut;
  final bool isReverse;
  final bool isNothing;
}

// Concurrency now managed via package:pool.
