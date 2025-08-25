import 'dart:async';
import 'dart:io';

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

/// Structured counters for the final summary.
class MediaMoveCounters {
  const MediaMoveCounters({
    required this.realFiles,
    required this.symlinks,
    required this.jsonWrites,
    required this.others,
    required this.totalOpsObserved,
  });

  final int realFiles;
  final int symlinks;
  final int jsonWrites;
  final int others;
  /// All low-level ops observed (sum of all kinds).
  final int totalOpsObserved;

  Map<String, Object> toJson() => {
        'realFiles': realFiles,
        'symlinks': symlinks,
        'jsonWrites': jsonWrites,
        'others': others,
        'totalOpsObserved': totalOpsObserved,
      };
}

/// Modern media moving service using immutable MediaEntity.
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

  /// Returns the exact number of *low-level operations* that would be performed
  /// (real files + symlinks/shortcuts + json).
  Future<int> estimateOperationCount(
    final MediaEntityCollection entityCollection,
    final MovingContext context,
  ) async {
    final strategy = _strategyFactory.createStrategy(context.albumBehavior);
    strategy.validateContext(context);

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
    return total;
  }

  /// Returns the exact number of *real file operations* (move/copy/rename),
  /// explicitly excluding symlinks/shortcuts and JSON writes.
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
        total += placements; // each placement is a real copy
      } else if (mode.isJson) {
        total += 1; // only ALL_PHOTOS real file
      } else {
        // Shortcut / Reverse / Nothing → one real file, rest links or none
        total += 1;
      }
    }
    return total;
  }

  /// Moves media entities according to the provided context using parallel processing.
  ///
  /// Progress semantics (entity-level):
  ///   The returned stream reports the NUMBER OF ENTITIES processed (not low-level ops).
  ///
  /// Additional callbacks (optional, robust & type-safe):
  /// - onOperation: raw per-op callback (as before).
  /// - onRealFile(File src, File dst): fired once per real file op.
  /// - onSymlink(String linkPath, String target): fired once per symlink/shortcut op.
  /// - onJson(File jsonFile): fired once per JSON write op.
  /// - onSummary(MediaMoveCounters counters): fired once at the very end with exact totals.
  Stream<int> moveMediaEntities(
    final MediaEntityCollection entityCollection,
    final MovingContext context, {
    int? maxConcurrent,
    final int batchSize = 100,
    final void Function(MediaEntityMovingResult op)? onOperation,
    final void Function(File src, File dst)? onRealFile,
    final void Function(String linkPath, String target)? onSymlink,
    final void Function(File jsonFile)? onJson,
    final void Function(MediaMoveCounters counters)? onSummary,
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

    // Internal counters (exact)
    int realFiles = 0;
    int symlinks = 0;
    int jsonWrites = 0;
    int others = 0;

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

            await for (final result in strategy.processMediaEntity(
              entity,
              context,
            )) {
              results.add(result);
              if (onOperation != null) onOperation(result);

              // Robust classification per low-level operation (filesystem-based)
              final _OpClass oc = _classifyOpFs(result);
              switch (oc.kind) {
                case _OpKind.file:
                  realFiles++;
                  if (onRealFile != null && oc.srcFile != null && oc.dstFile != null) {
                    onRealFile(oc.srcFile!, oc.dstFile!);
                  }
                  break;
                case _OpKind.symlink:
                  symlinks++;
                  if (onSymlink != null) {
                    onSymlink(oc.linkPath ?? '', oc.linkTarget ?? '');
                  }
                  break;
                case _OpKind.json:
                  jsonWrites++;
                  if (onJson != null && oc.jsonFile != null) {
                    onJson(oc.jsonFile!);
                  }
                  break;
                case _OpKind.other:
                  others++;
                  break;
              }
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

      // Some strategies may emit JSON or link ops during finalize
      final _OpClass oc = _classifyOpFs(r);
      switch (oc.kind) {
        case _OpKind.file:
          realFiles++;
          if (onRealFile != null && oc.srcFile != null && oc.dstFile != null) {
            onRealFile(oc.srcFile!, oc.dstFile!);
          }
          break;
        case _OpKind.symlink:
          symlinks++;
          if (onSymlink != null) {
            onSymlink(oc.linkPath ?? '', oc.linkTarget ?? '');
          }
          break;
        case _OpKind.json:
          jsonWrites++;
          if (onJson != null && oc.jsonFile != null) {
            onJson(oc.jsonFile!);
          }
          break;
        case _OpKind.other:
          others++;
          break;
      }
    }

    // Emit a typed summary back to the caller
    final counters = MediaMoveCounters(
      realFiles: realFiles,
      symlinks: symlinks,
      jsonWrites: jsonWrites,
      others: others,
      totalOpsObserved: realFiles + symlinks + jsonWrites + others,
    );
    if (onSummary != null) onSummary(counters);

    if (context.verbose) {
      _printSummary(allResults, strategy, counters);
    }
  }

  void _printSummary(
    final List<MediaEntityMovingResult> results,
    final MediaEntityMovingStrategy strategy,
    final MediaMoveCounters counters,
  ) {
    final successful = results.where((final r) => r.success).length;
    final failed = results.where((final r) => !r.success).length;

    print('\n=== Moving Summary (${strategy.name}) ===');
    print('Successful operations: $successful');
    print('Failed operations: $failed');
    print('Total operations: ${results.length}');
    print('Breakdown: ${counters.toJson()}');

    if (failed > 0) {
      print('\nErrors encountered:');
      results.where((final r) => !r.success).take(5).forEach((final result) {
        final dynamic src = _try(() => result.operation.sourceFile, null);
        print('  • ${_safePath(src)}: ${result.errorMessage}');
      });
      if (failed > 5) {
        print('  ... and ${failed - 5} more errors');
      }
    }
  }

  // ------------------- Filesystem-based op classification -------------------

  _OpClass _classifyOpFs(final dynamic result) {
    // Access common operation fields safely
    final dynamic op = _try(() => result.operation, null);

    final File? srcFile = _asFile(_try(() => op?.sourceFile, null));
    final File? dstFile = _asFile(_try(() => op?.destinationFile, null)) ??
        _asFile(_try(() => op?.targetFile, null));
    final String? destPath = _asString(_try(() => op?.destinationPath, null));

    // Prefer concrete File path; else fallback to destinationPath
    final String? dstPath = (dstFile?.path ?? destPath)?.toString();

    // JSON writes (naming-based; typically metadata files)
    if (_isJsonPath(dstPath)) {
      return _OpClass.json(jsonFile: _fileFromPath(dstPath));
    }

    // If we have a destination path, ask the filesystem what was actually created.
    if (dstPath != null && dstPath.isNotEmpty) {
      try {
        // Do NOT follow links so we can detect symlinks on Linux/macOS.
        final FileSystemEntityType t =
            FileSystemEntity.typeSync(dstPath, followLinks: false);

        if (t == FileSystemEntityType.link) {
          // A symbolic link or junction
          return _OpClass.symlink(linkPath: dstPath, linkTarget: _asString(_try(() => op?.targetPath, null)));
        }

        if (t == FileSystemEntityType.file) {
          // Real file materialized; ensure src != dst
          if (srcFile != null && srcFile.path != dstPath) {
            return _OpClass.file(srcFile: srcFile, dstFile: File(dstPath));
          }
        }

        // Directories / notFound / other → not something we count as a real file
        return const _OpClass.other();
      } catch (_) {
        // If stat fails, fall through to soft checks
      }
    }

    // Fallback soft checks (rare): explicit flags if strategy exposes them
    final bool explicitLinkFlag = _asBool(_try(() => op?.isSymlink, false)) ||
        _asBool(_try(() => op?.isShortcut, false)) ||
        _asBool(_try(() => op?.isLink, false));
    if (explicitLinkFlag) {
      return _OpClass.symlink(linkPath: dstPath, linkTarget: _asString(_try(() => op?.targetPath, null)));
    }

    // Unknown/metadata/no-op
    return const _OpClass.other();
  }

  File? _asFile(final dynamic v) {
    if (v is File) return v;
    final String? s = _asString(v);
    if (s == null || s.isEmpty) return null;
    return File(s);
  }

  String? _asString(final dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    try {
      return v.toString();
    } catch (_) {
      return null;
    }
  }

  bool _asBool(final dynamic v) {
    if (v is bool) return v;
    if (v is String) {
      final s = v.toLowerCase().trim();
      return s == 'true' || s == '1' || s == 'yes';
    }
    if (v is num) return v != 0;
    return false;
  }

  T _try<T>(T Function() f, T fallback) {
    try {
      return f();
    } catch (_) {
      return fallback;
    }
  }

  bool _isJsonPath(final String? p) => (p ?? '').toLowerCase().endsWith('.json');

  String _safePath(final dynamic fileLike) {
    if (fileLike is File) return fileLike.path;
    if (fileLike is String) return fileLike;
    try {
      final p = fileLike?.path;
      if (p is String) return p;
      return p?.toString() ?? '<unknown>';
    } catch (_) {
      return '<unknown>';
    }
  }

  File? _fileFromPath(final String? p) {
    if (p == null || p.isEmpty) return null;
    return File(p);
  }

  // ------------------- Behavior helpers -------------------

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

// Classification result (immutable)
class _OpClass {
  const _OpClass._(this.kind, {this.srcFile, this.dstFile, this.linkPath, this.linkTarget, this.jsonFile});

  const _OpClass.file({required File srcFile, required File dstFile})
      : this._(_OpKind.file, srcFile: srcFile, dstFile: dstFile);

  const _OpClass.symlink({String? linkPath, String? linkTarget})
      : this._(_OpKind.symlink, linkPath: linkPath, linkTarget: linkTarget);

  const _OpClass.json({File? jsonFile}) : this._(_OpKind.json, jsonFile: jsonFile);

  const _OpClass.other() : this._(_OpKind.other);

  final _OpKind kind;
  final File? srcFile;
  final File? dstFile;
  final String? linkPath;
  final String? linkTarget;
  final File? jsonFile;
}

enum _OpKind { file, symlink, json, other }
