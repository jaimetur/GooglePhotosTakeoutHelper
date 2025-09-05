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
    int failures = 0;

    // NEW: per-destination breakdown (ALL_PHOTOS vs Albums)
    int primaryMovesAllPhotos = 0;
    int primaryMovesAlbums = 0;

    int nonPrimaryMovesAllPhotos = 0;
    int nonPrimaryMovesAlbums = 0;

    int symlinksAllPhotos = 0;
    int symlinksAlbums = 0;

    int jsonRefsAllPhotos = 0;
    int jsonRefsAlbums = 0;

    int failuresAllPhotos = 0;
    int failuresAlbums = 0;

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
        if (op.isAlbumFile) {
          failuresAlbums++;
        } else {
          failuresAllPhotos++;
        }
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
        failures;

    const int detailsCol = 50; // starting column for the parenthesis block
    logPrint('[Step 6/8] === Moving Files Summary ===');
    logPrint('${'[Step 6/8] \tPrimary files moved: $primaryMoves'.padRight(detailsCol)}(ALL_PHOTOS: $primaryMovesAllPhotos, Albums: $primaryMovesAlbums)');
    logPrint('${'[Step 6/8] \tNon-primary moves: $nonPrimaryMoves'.padRight(detailsCol)}(ALL_PHOTOS: $nonPrimaryMovesAllPhotos, Albums: $nonPrimaryMovesAlbums)');
    logPrint('${'[Step 6/8] \tDuplicated copies created: ${copiesAllPhotos + copiesAlbums}'.padRight(detailsCol)}(ALL_PHOTOS: $copiesAllPhotos, Albums: $copiesAlbums)');
    logPrint('${'[Step 6/8] \tSymlinks created: $symlinksCreated'.padRight(detailsCol)}(ALL_PHOTOS: $symlinksAllPhotos, Albums: $symlinksAlbums)');
    logPrint('${'[Step 6/8] \tJSON refs created: $jsonRefs'.padRight(detailsCol)}(ALL_PHOTOS: $jsonRefsAllPhotos, Albums: $jsonRefsAlbums)');
    logPrint('${'[Step 6/8] \ttFailures: $failures'.padRight(detailsCol)}(ALL_PHOTOS: $failuresAllPhotos, Albums: $failuresAlbums)');
    final totalLeft = '[Step 6/8] \tTotal operations: $totalOps${computedOps != totalOps ? ' (computed: $computedOps)' : ''}';
    logPrint('${totalLeft.padRight(detailsCol)}(ALL_PHOTOS: $totalOpsAllPhotos, Albums: $totalOpsAlbums)');

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

// (resto del archivo sin cambios)


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
        return ShortcutMovingStrategy(
          _fileService,
          _pathService,
          _symlinkService,
        );
      case AlbumBehavior.duplicateCopy:
        return DuplicateCopyMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.reverseShortcut:
        return ReverseShortcutMovingStrategy(
          _fileService,
          _pathService,
          _symlinkService,
        );
      case AlbumBehavior.json:
        return JsonMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.nothing:
        return NothingMovingStrategy(_fileService, _pathService);
    }
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// Common helpers to avoid code duplication across strategies
/// (centralized in this service module so strategies can import and reuse them)
/// ─────────────────────────────────────────────────────────────────────────
class MovingStrategyUtils {
  const MovingStrategyUtils._();

  /// Generate ALL_PHOTOS target directory (date-structured if needed).
  static Directory allPhotosDir(
    final PathGeneratorService pathService,
    final MediaEntity entity,
    final MovingContext context,
  ) => pathService.generateTargetDirectory(
      null,
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnerShared,
    );

  /// Generate Albums/<albumName> target directory (date-structured if needed).
  static Directory albumDir(
    final PathGeneratorService pathService,
    final String albumName,
    final MediaEntity entity,
    final MovingContext context,
  ) => pathService.generateTargetDirectory(
      albumName,
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnerShared,
    );

  /// Returns true if 'child' path equals or is a subpath of 'parent'.
  static bool isSubPath(final String child, final String parent) {
    final String c = child.replaceAll('\\', '/');
    final String p = parent.replaceAll('\\', '/');
    return c == p || c.startsWith('$p/');
  }

  /// Returns the directory (without trailing slash) of a path, handling both separators.
  static String dirOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? '' : normalized.substring(0, idx);
  }

  /// Infer album name for a given file source directory using albumsMap metadata.
  /// Returns null if no album matches.
  static String? inferAlbumForSourceDir(
    final MediaEntity entity,
    final String fileSourceDir,
  ) {
    for (final entry in entity.albumsMap.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (isSubPath(fileSourceDir, src)) return entry.key;
      }
    }
    return entity.albumNames.isNotEmpty ? entity.albumNames.first : null;
  }

  /// Compute the list of album names a given file (by its source directory) belonged to.
  static List<String> albumsForFile(
    final MediaEntity entity,
    final FileEntity file,
  ) {
    final fileDir = dirOf(file.sourcePath);
    final List<String> result = <String>[];
    for (final entry in entity.albumsMap.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (isSubPath(fileDir, src)) {
          result.add(entry.key);
          break;
        }
      }
    }
    return result;
  }

  /// Predicate: whether [file] belonged to the given [albumName] according to sourceDirectories.
  static bool fileBelongsToAlbum(
    final MediaEntity entity,
    final FileEntity file,
    final String albumName,
  ) {
    final info = entity.albumsMap[albumName];
    if (info == null || info.sourceDirectories.isEmpty) return false;
    final fileDir = dirOf(file.sourcePath);
    for (final src in info.sourceDirectories) {
      if (isSubPath(fileDir, src)) return true;
    }
    return false;
  }

  /// Create a symlink to [target] inside [dir] and try to rename it to [preferredBasename].
  /// On name collision, appends " (n)" before extension.
  static Future<File> createSymlinkWithPreferredName(
    final SymlinkService symlinkService,
    final Directory dir,
    final File target,
    final String preferredBasename,
  ) async {
    final File link = await symlinkService.createSymlink(dir, target);
    final String currentBase = link.uri.pathSegments.last;
    if (currentBase == preferredBasename) return link;

    final String finalBasename = _resolveUniqueBasename(dir, preferredBasename);
    final String desiredPath = '${dir.path}/$finalBasename';
    try {
      return await link.rename(desiredPath);
    } catch (_) {
      return link;
    }
  }

  static String _resolveUniqueBasename(final Directory dir, final String base) {
    final int dot = base.lastIndexOf('.');
    final String stem = dot > 0 ? base.substring(0, dot) : base;
    final String ext = dot > 0 ? base.substring(dot) : '';
    String candidate = base;
    int idx = 1;
    while (_existsAny('${dir.path}/$candidate')) {
      candidate = '$stem ($idx)$ext';
      idx++;
    }
    return candidate;
  }

  static bool _existsAny(final String fullPath) {
    try {
      return File(fullPath).existsSync() ||
          Link(fullPath).existsSync() ||
          Directory(fullPath).existsSync();
    } catch (_) {
      return false;
    }
  }
}
