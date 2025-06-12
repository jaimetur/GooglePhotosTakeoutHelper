import 'dart:async';

import '../../../media.dart';
import 'file_operation_service.dart';
import 'moving_context_model.dart';
import 'path_generator_service.dart';
import 'shortcut_service.dart';
import 'strategies/moving_strategy.dart';
import 'strategies/moving_strategy_factory.dart';

/// Main service that orchestrates the media moving operations
///
/// This service coordinates all the moving logic components and provides
/// a clean interface for moving media files according to configuration.
class MediaMovingService {
  MediaMovingService()
    : _strategyFactory = MovingStrategyFactory(
        FileOperationService(),
        PathGeneratorService(),
        ShortcutService(),
      );

  /// Custom constructor for dependency injection (useful for testing)
  MediaMovingService.withDependencies({
    required final FileOperationService fileService,
    required final PathGeneratorService pathService,
    required final ShortcutService shortcutService,
  }) : _strategyFactory = MovingStrategyFactory(
         fileService,
         pathService,
         shortcutService,
       );
  final MovingStrategyFactory _strategyFactory;

  /// Moves a list of media files according to the provided context
  ///
  /// [mediaList] List of media files to process
  /// [context] Configuration and context for the moving operations
  /// Returns a stream of progress updates (number of files processed)
  Stream<int> moveMediaFiles(
    final List<Media> mediaList,
    final MovingContext context,
  ) async* {
    // Create the appropriate strategy for the album behavior
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);

    // Validate the context for this strategy
    strategy.validateContext(context);

    int processedCount = 0;
    final List<MovingResult> allResults = [];

    // Process each media file
    for (final media in mediaList) {
      await for (final result in strategy.processMedia(media, context)) {
        allResults.add(result);

        if (!result.success) {
          // Log error but continue processing
          print(
            '[Error] Failed to process ${result.operation.sourceFile.path}: '
            '${result.errorMessage}',
          );
        }

        if (context.verbose) {
          _logResult(result);
        }
      }

      processedCount++;
      yield processedCount;
    }

    // Perform any finalization steps
    try {
      final finalizationResults = await strategy.finalize(context, mediaList);
      allResults.addAll(finalizationResults);

      for (final result in finalizationResults) {
        if (!result.success) {
          print('[Error] Finalization failed: ${result.errorMessage}');
        } else if (context.verbose) {
          _logResult(result);
        }
      }
    } catch (e) {
      print('[Error] Strategy finalization failed: $e');
    }

    // Print summary
    _printSummary(allResults, strategy);
  }

  /// Logs the result of a moving operation
  void _logResult(final MovingResult result) {
    final operation = result.operation;
    final duration = result.duration.inMilliseconds;

    if (result.success) {
      print(
        '[${operation.operationType.name}] '
        '${operation.sourceFile.path} -> '
        '${result.resultFile?.path ?? 'unknown'} '
        '(${duration}ms)',
      );
    } else {
      print('[ERROR] ${operation.sourceFile.path}: ${result.errorMessage}');
    }
  }

  /// Prints a summary of the moving operations
  void _printSummary(
    final List<MovingResult> results,
    final MovingStrategy strategy,
  ) {
    final successful = results.where((final r) => r.success).length;
    final failed = results.where((final r) => !r.success).length;
    final totalDuration = results
        .map((final r) => r.duration.inMilliseconds)
        .fold(0, (final a, final b) => a + b);

    print('\n=== Moving Summary (${strategy.name} strategy) ===');
    print('Total operations: ${results.length}');
    print('Successful: $successful');
    print('Failed: $failed');
    print('Total time: ${totalDuration}ms');

    if (strategy.createsShortcuts) {
      final shortcuts = results
          .where(
            (final r) =>
                r.operation.operationType == MovingOperationType.createShortcut,
          )
          .length;
      print('Shortcuts created: $shortcuts');
    }

    if (strategy.createsDuplicates) {
      final copies = results
          .where(
            (final r) => r.operation.operationType == MovingOperationType.copy,
          )
          .length;
      print('Files copied: $copies');
    }
  }
}
