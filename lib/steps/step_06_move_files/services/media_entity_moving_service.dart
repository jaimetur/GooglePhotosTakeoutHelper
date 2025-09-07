import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';

/// Modern media moving service using immutable MediaEntity
///
/// This service coordinates all the moving logic components and provides
/// a clean interface for moving media files according to configuration.
///— Uses MediaEntity exclusively for better performance and immutability.
///
/// ⚠️ Model note:
/// MediaEntity now exposes:
///   - `primaryFile` (the only physical source to move/copy/link),
///   - `secondaryFiles` (kept as metadata; duplicates already removed/moved in Step 3),
///   - album associations via `albumsMap` / `albumNames`.
/// There is NO `files` map anymore. This service therefore expects only one
/// physical "move" per entity (the primary).
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

  // Keeps the last full set of results for verification/reporting purposes
  final List<MediaEntityMovingResult> _lastResults = [];

  /// Expose an immutable view of the last results after a run
  List<MediaEntityMovingResult> get lastResults =>
      List.unmodifiable(_lastResults);

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
          errorMessage:
              'No MOVE operation emitted by strategy for primary file',
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
        logError('[Step 6/8] [Error] Strategy finalization failed: $e');
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

              await for (final r in strategy.processMediaEntity(
                entity,
                context,
              )) {
                results.add(r);
                if (r.operation.operationType ==
                    MediaEntityOperationType.move) {
                  if (_samePath(
                    r.operation.sourceFile.path,
                    primarySourcePath,
                  )) {
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
                    errorMessage:
                        'No MOVE operation emitted by strategy for primary file',
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
        logError('[Step 6/8] [Error] Strategy finalization failed: $e');
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
    logPrint('[Step 6/8] [${operation.operationType.name.toUpperCase()}] $status: ${operation.sourceFile.path}');
    if (result.resultFile != null) {
      logPrint('[Step 6/8]   → ${result.resultFile!.path}');
    }
  }

  void _logError(final MediaEntityMovingResult result) {
    logPrint('[Step 6/8] [Error] Failed to process ${result.operation.sourceFile.path}: ${result.errorMessage}');
  }

  // Print Summary
  void _printSummary(final List<MediaEntityMovingResult> results) {
    // Totals per operation kind
    int primaryMoves = 0;
    int nonPrimaryMoves = 0;
    int copiesAllPhotos = 0;
    int copiesAlbums = 0;
    int symlinksCreated = 0;
    int jsonRefs = 0;
    int deletes = 0;

    // NEW: per-destination breakdown (ALL_PHOTOS vs Albums)
    int primaryMovesAllPhotos = 0;
    int primaryMovesAlbums = 0;

    int nonPrimaryMovesAllPhotos = 0;
    int nonPrimaryMovesAlbums = 0;

    int symlinksAllPhotos = 0;
    int symlinksAlbums = 0;

    int jsonRefsAllPhotos = 0;
    int jsonRefsAlbums = 0;

    int deletesAllPhotos = 0;
    int deletesAlbums = 0;

    int failures = 0;

    // NEW: total operations breakdown (independent of success)
    int totalOpsAllPhotos = 0;
    int totalOpsAlbums = 0;

    for (final r in results) {
      final op = r.operation;

      // Accumulate TOTAL operations split by target kind (album vs main)
      if (op.isAlbumFile) {
        totalOpsAlbums++;
      } else {
        totalOpsAllPhotos++;
      }

      if (!r.success) {
        failures++;
        continue;
      }

      switch (op.operationType) {
        case MediaEntityOperationType.move:
          final src = op.sourceFile.path;
          final prim = op.mediaEntity.primaryFile.sourcePath; // usar sourcePath
          final isPrimary = _samePath(src, prim);
          if (isPrimary) {
            primaryMoves++;
            if (op.isAlbumFile) {
              primaryMovesAlbums++;
            } else {
              primaryMovesAllPhotos++;
            }
          } else {
            nonPrimaryMoves++;
            if (op.isAlbumFile) {
              nonPrimaryMovesAlbums++;
            } else {
              nonPrimaryMovesAllPhotos++;
            }
          }
          break;

        case MediaEntityOperationType.copy:
          if (op.isAlbumFile) {
            copiesAlbums++;
          } else {
            copiesAllPhotos++;
          }
          break;

        case MediaEntityOperationType.createSymlink:
        case MediaEntityOperationType.createReverseSymlink:
          symlinksCreated++;
          if (op.isAlbumFile) {
            symlinksAlbums++;
          } else {
            symlinksAllPhotos++;
          }
          break;

        case MediaEntityOperationType.createJsonReference:
          jsonRefs++;
          if (op.isAlbumFile) {
            jsonRefsAlbums++;
          } else {
            jsonRefsAllPhotos++;
          }
          break;

        case MediaEntityOperationType.delete:
          deletes++;
          if (op.isAlbumFile) {
            deletesAlbums++;
          } else {
            deletesAllPhotos++;
          }
          break;
      }
    }

    final totalOps = results.length;
    final computedOps =
        primaryMoves +
        nonPrimaryMoves +
        copiesAllPhotos +
        copiesAlbums +
        symlinksCreated +
        jsonRefs +
        deletes +
        failures;

    print('');  // print to force new line after progress bar
    const int detailsCol = 50; // starting column for the parenthesis block
    logPrint('[Step 6/8] === Moving Files Summary ===');
    logPrint('${'[Step 6/8]     Primary files moved: $primaryMoves'.padRight(detailsCol)}(ALL_PHOTOS: $primaryMovesAllPhotos, Albums: $primaryMovesAlbums)');
    logPrint('${'[Step 6/8]     Non-primary moves: $nonPrimaryMoves'.padRight(detailsCol)}(ALL_PHOTOS: $nonPrimaryMovesAllPhotos, Albums: $nonPrimaryMovesAlbums)');
    logPrint('${'[Step 6/8]     Duplicated copies created: ${copiesAllPhotos + copiesAlbums}'.padRight(detailsCol)}(ALL_PHOTOS: $copiesAllPhotos, Albums: $copiesAlbums)');
    logPrint('${'[Step 6/8]     Symlinks created: $symlinksCreated'.padRight(detailsCol)}(ALL_PHOTOS: $symlinksAllPhotos, Albums: $symlinksAlbums)');
    logPrint('${'[Step 6/8]     JSON refs created: $jsonRefs'.padRight(detailsCol)}(ALL_PHOTOS: $jsonRefsAllPhotos, Albums: $jsonRefsAlbums)');
    logPrint('${'[Step 6/8]     Deleted from source: $deletes'.padRight(detailsCol)}(ALL_PHOTOS: $deletesAllPhotos, Albums: $deletesAlbums)');
    logPrint('${'[Step 6/8]     Failures: $failures'.padRight(detailsCol)}(ALL_PHOTOS: ${results.where((final r) => !r.success && !r.operation.isAlbumFile).length}, Albums: ${results.where((final r) => !r.success && r.operation.isAlbumFile).length})');
    logPrint('${'[Step 6/8]     Total operations: $totalOps${computedOps != totalOps ? ' (computed: $computedOps)' : ''}'.padRight(detailsCol)}(ALL_PHOTOS: $totalOpsAllPhotos, Albums: $totalOpsAlbums)');

    if (failures > 0) {
      logError('[Step 6/8] Errors encountered:');
      results.where((final r) => !r.success).take(5).forEach((final result) {
        logError('[Step 6/8]   • ${result.operation.sourceFile.path}: ${result.errorMessage}');
      });
      final extra = failures - 5;
      if (extra > 0) logError('[Step 6/8]   ... and $extra more errors');
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

/// Represents a single file moving operation
class MediaEntityMovingOperation {
  const MediaEntityMovingOperation({
    required this.sourceFile,
    required this.targetDirectory,
    required this.operationType,
    required this.mediaEntity,
    this.albumKey,
  });

  final File sourceFile;
  final Directory targetDirectory;
  final MediaEntityOperationType operationType;
  final MediaEntity mediaEntity;
  final String? albumKey;

  File get targetFile =>
      File('${targetDirectory.path}/${sourceFile.uri.pathSegments.last}');

  bool get isAlbumFile => albumKey != null;
  bool get isMainFile => albumKey == null;
}

enum MediaEntityOperationType {
  move,
  copy,
  createSymlink,
  createReverseSymlink,
  createJsonReference,
  delete, // NEW: represents a deletion from source (no output artifact)
}

/// Operation result
class MediaEntityMovingResult {
  const MediaEntityMovingResult({
    required this.operation,
    required this.success,
    required this.duration,
    this.resultFile,
    this.errorMessage,
  });

  factory MediaEntityMovingResult.success({
    required final MediaEntityMovingOperation operation,
    required final File resultFile,
    required final Duration duration,
  }) => MediaEntityMovingResult(
    operation: operation,
    success: true,
    resultFile: resultFile,
    duration: duration,
  );

  factory MediaEntityMovingResult.failure({
    required final MediaEntityMovingOperation operation,
    required final String errorMessage,
    required final Duration duration,
  }) => MediaEntityMovingResult(
    operation: operation,
    success: false,
    errorMessage: errorMessage,
    duration: duration,
  );

  final MediaEntityMovingOperation operation;
  final bool success;
  final File? resultFile;
  final Duration duration;
  final String? errorMessage;

  bool get isSuccess => success;
  bool get isFailure => !success;
}

/// Base class for MediaEntity moving strategies (unchanged public API)
abstract class MediaEntityMovingStrategy {
  const MediaEntityMovingStrategy();

  String get name;
  bool get createsShortcuts;
  bool get createsDuplicates;

  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  );

  Future<List<MediaEntityMovingResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async => [];

  void validateContext(final MovingContext context) {}
}

/// Factory to create strategy by AlbumBehavior
class MediaEntityMovingStrategyFactory {
  const MediaEntityMovingStrategyFactory(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  MediaEntityMovingStrategy createStrategy(final AlbumBehavior albumBehavior) {
    switch (albumBehavior) {
      case AlbumBehavior.shortcut:
        return ShortcutMovingStrategy(_fileService, _pathService, _symlinkService);
      case AlbumBehavior.duplicateCopy:
        return DuplicateCopyMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.reverseShortcut:
        return ReverseShortcutMovingStrategy(_fileService, _pathService, _symlinkService);
      case AlbumBehavior.json:
        return JsonMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.nothing:
        return NothingMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.ignoreAlbums: // NEW: wire the new strategy
        return IgnoreAlbumsMovingStrategy(_fileService, _pathService);
    }
  }
}
