import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:gpth/gpth-lib.dart';

/// Step 3: Remove duplicate media files
///
/// This essential step identifies and eliminates duplicate files based on content hashing,
/// which is crucial for Google Photos Takeout exports that often contain multiple copies
/// of the same photo across different albums and year folders.
///
/// ## Duplicate Detection Strategy
///
/// ### Content-Based Identification
/// - **Hash Algorithm**: Uses SHA-256 cryptographic hashing for reliable content comparison
/// - **Size Pre-filtering**: Groups files by size before hashing to optimize performance
/// - **Binary Comparison**: Ensures exact byte-by-byte content matching
/// - **Metadata Independence**: Focuses on file content, ignoring metadata differences
///
/// ### Two-Phase Processing
/// 1. **Size Grouping**: Groups files by identical file sizes (cheap comparison)
/// 2. **Hash Verification**: Calculates hashes only for files with matching sizes
/// 3. **Performance Optimization**: Avoids expensive hash calculations for unique sizes
/// 4. **Memory Efficiency**: Processes groups incrementally to manage memory usage
///
/// ## Duplicate Resolution Logic
///
/// ### Best Copy Selection
/// When multiple identical files are found, the algorithm selects the best copy using:
///
/// #### Primary Criteria (in priority order):
/// 1. **Date Accuracy**: Files with better date extraction accuracy (lower number = better)
/// 2. **Filename Length**: Shorter *filename* length (basename) is preferred
/// 3. **Year vs Album Preference**: On ties, prefer files from Year folders (no album metadata)
/// 4. **Path Length**: Shorter full path as final tie-breaker
///
/// #### Selection Algorithm:
/// ```
/// Sort by: dateTakenAccuracy (ascending) + basename length (ascending) + prefer Year over Album + full path length (ascending)
/// Keep: First file in sorted order
/// Remove: All subsequent identical files
/// ```
///
/// ### Metadata Preservation
/// - **Date Information**: Preserves best available date and accuracy from kept file
/// - **Album Associations**: Preserved and merged in `belongToAlbums`
/// - **EXIF Data**: Maintains original EXIF information from selected file
/// - **JSON Metadata**: Keeps associated JSON file with selected media file
///
/// ## Performance note (updated):
/// For maximum throughput on very large datasets, this step **pre-buckets by file size**, then
/// sub-buckets by **extension**, then splits again using a **quick signature** (FNV-1a32 of the
/// first up-to-64KB). Only within these tiny buckets we call `duplicateService.groupIdentical(...)`,
/// which runs the full content-hash grouping on a very reduced candidate set. This greatly cuts I/O.
class RemoveDuplicatesStep extends ProcessingStep with LoggerMixin {
  RemoveDuplicatesStep() : super('Remove Duplicates');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();
    final mediaCol = context.mediaCollection;

    try {
      if (mediaCol.isEmpty) {
        stopwatch.stop();
        return StepResult.success(
          stepName: name,
          duration: stopwatch.elapsed,
          data: {'duplicatesRemoved': 0, 'remainingMedia': 0},
          message: 'No media to process.',
        );
      }

      print('\n[Step 3/8] Removing duplicates (this may take a while)...');
      if (context.config.keepDuplicates) {
        print('[Step 3/8] Flag `--keep-duplicates` detected. Duplicates will be moved to `_Duplicates` subfolder within output folder');
      }

      final duplicateService = ServiceContainer.instance.duplicateDetectionService;
      final bool verify = _isVerifyEnabled();
      final MediaHashService verifier = verify ? MediaHashService() : MediaHashService(maxCacheSize: 1);

      int removedCount = 0;

      // ───────────────────────────────────────────────────────────────────────
      // OLD-PIPELINE CORE (restored):
      // size bucket → extension sub-bucket → quick signature sub-bucket
      // → groupIdentical() only inside small quick-buckets
      // ───────────────────────────────────────────────────────────────────────

      // 1) Pre-bucket by file size (cheap)
      final Map<int, List<MediaEntity>> sizeBuckets = <int, List<MediaEntity>>{};
      for (final e in mediaCol.entities) {
        int size;
        try {
          size = e.primaryFile.lengthSync();
        } catch (_) {
          size = -1; // group for unreadable size
        }
        (sizeBuckets[size] ??= <MediaEntity>[]).add(e);
      }
      final List<int> sizeKeys = sizeBuckets.keys.toList();
      final int totalSizeBuckets = sizeKeys.length;

      // Concurrency cap borrowed from your infra (kept conservative)
      final int maxWorkers = ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif).clamp(1, 8);
      int processedSizeBuckets = 0;

      // Accumulate duplicates to remove and replacements to apply
      final Set<MediaEntity> entitiesToRemove = <MediaEntity>{};
      final Map<MediaEntity, MediaEntity> replacements = <MediaEntity, MediaEntity>{};

      // Process size buckets in slices for mild parallelism
      for (int i = 0; i < sizeKeys.length; i += maxWorkers) {
        final slice = sizeKeys.skip(i).take(maxWorkers).toList();

        await Future.wait(slice.map((sizeKey) async {
          final List<MediaEntity> candidates = sizeBuckets[sizeKey]!;
          if (candidates.length <= 1) {
            processedSizeBuckets++;
            return;
          }

          // 2) Sub-bucket by extension (avoids mixing types with same size)
          final Map<String, List<MediaEntity>> extBuckets = <String, List<MediaEntity>>{};
          for (final e in candidates) {
            final String ext = _extOf(e.primaryFile.path);
            (extBuckets[ext] ??= <MediaEntity>[]).add(e);
          }

          for (final extGroup in extBuckets.values) {
            if (extGroup.length <= 1) continue;

            // 3) Quick signature (FNV-1a32 of head up-to-64KB) to split large groups cheaply
            final Map<String, List<MediaEntity>> quickBuckets = <String, List<MediaEntity>>{};
            for (final e in extGroup) {
              String sig;
              try {
                final int size = e.primaryFile.lengthSync();
                final String ext = _extOf(e.primaryFile.path);
                sig = await _quickSignature(e.primaryFile, size, ext);
              } catch (_) {
                sig = 'qsig-err';
              }
              (quickBuckets[sig] ??= <MediaEntity>[]).add(e);
            }

            // 4) Only inside tiny quick-buckets run the expensive grouping
            for (final q in quickBuckets.values) {
              if (q.length <= 1) continue;

              // Full content-hash grouping from your service
              final Map<String, List<MediaEntity>> hashGroups = await duplicateService.groupIdentical(q);

              for (final group in hashGroups.values) {
                if (group.length <= 1) continue;

                // Keep your current "best copy" policy:
                // accuracy (asc) → basename length (asc) → prefer Year → path length (asc) → lex
                group.sort((a, b) {
                  final aAcc = a.dateAccuracy?.value ?? 999;
                  final bAcc = b.dateAccuracy?.value ?? 999;
                  if (aAcc != bAcc) return aAcc.compareTo(bAcc);

                  final aBaseLen = path.basename(a.primaryFile.path).length;
                  final bBaseLen = path.basename(b.primaryFile.path).length;
                  if (aBaseLen != bBaseLen) return aBaseLen.compareTo(bBaseLen);

                  final aYear = _isYearEntity(a);
                  final bYear = _isYearEntity(b);
                  if (aYear != bYear) return aYear ? -1 : 1; // prefer Year

                  final aPathLen = a.primaryFile.path.length;
                  final bPathLen = b.primaryFile.path.length;
                  if (aPathLen != bPathLen) return aPathLen.compareTo(bPathLen);

                  return a.primaryFile.path.compareTo(b.primaryFile.path);
                });

                final MediaEntity kept0 = group.first;
                final List<MediaEntity> toRemove = group.sublist(1);

                MediaEntity kept = kept0;

                if (verify) {
                  // Optional verification by content-hash before merging/removing
                  try {
                    final String keptHash = await verifier.calculateFileHash(kept.primaryFile);
                    for (final d in toRemove) {
                      try {
                        final String dupHash = await verifier.calculateFileHash(d.primaryFile);
                        if (dupHash != keptHash) {
                          logWarning('Verification mismatch. Will NOT remove ${d.primaryFile.path} (hash differs from kept).', forcePrint: true);
                          continue;
                        }
                        kept = kept.mergeWith(d);
                        entitiesToRemove.add(d);
                        removedCount++;
                      } catch (e) {
                        logWarning('Verification failed for ${d.primaryFile.path}: $e. Skipping removal for safety.', forcePrint: true);
                      }
                    }
                  } catch (e) {
                    logWarning('Could not hash kept file ${_safePath(kept.primaryFile)} for verification: $e. Skipping removals for this group.', forcePrint: true);
                  }
                } else {
                  for (final d in toRemove) {
                    kept = kept.mergeWith(d);
                    entitiesToRemove.add(d);
                    removedCount++;
                  }
                }

                // Remember replacement (apply after all grouping finishes)
                if (!identical(kept0, kept)) {
                  replacements[kept0] = kept;
                }
              }
            }
          }

          processedSizeBuckets++;
          if ((processedSizeBuckets % 50) == 0) {
            logDebug('[Step 3/8] Progress: processed $processedSizeBuckets/$totalSizeBuckets size-buckets...');
          }
        }));
      }

      // Apply replacements in place (stable, linear pass)
      if (replacements.isNotEmpty) {
        for (int i = 0; i < mediaCol.length; i++) {
          final MediaEntity cur = mediaCol[i];
          final MediaEntity? rep = replacements[cur];
          if (rep != null) {
            mediaCol[i] = rep;
          }
        }
      }

      // Materialize "keep" list and replace the whole collection once (O(n))
      if (entitiesToRemove.isNotEmpty) {
        print('[Step 3/8] Removing ${entitiesToRemove.length} files from media collection');

        // Physical move/delete as per config
        final bool moved = await _removeOrQuarantineDuplicates(entitiesToRemove, context);

        final List<MediaEntity> keep = <MediaEntity>[];
        for (final e in mediaCol.entities) {
          if (!entitiesToRemove.contains(e)) keep.add(e);
        }
        mediaCol.replaceAll(keep);

        if (moved) {
          print('[Step 3/8] Duplicates moved to _Duplicates (flag --keep-duplicates = true)');
        } else {
          print('[Step 3/8] Duplicates deleted from input folder.');
        }
      }

      print('[Step 3/8] Remove Duplicates finished, total duplicates found: $removedCount');

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'duplicatesRemoved': removedCount,
          'remainingMedia': mediaCol.length,
        },
        message: 'Removed $removedCount duplicate files from input folder\n   ${mediaCol.length} media files remain.',
      );
    } catch (e) {
      stopwatch.stop();
      return StepResult.failure(
        stepName: name,
        duration: stopwatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to remove duplicates: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) => context.mediaCollection.isEmpty;

  // ——— helpers ————————————————————————————————————————————————————————————————

  bool _isVerifyEnabled() {
    try {
      final v = Platform.environment['GPTH_VERIFY_DUPLICATES'];
      if (v == null) return false;
      final s = v.trim().toLowerCase();
      return s == '1' || s == 'true' || s == 'yes' || s == 'on';
    } catch (_) {
      return false;
    }
  }

  /// Reads the "move duplicates" flag from available configuration sources.
  /// Priority:
  /// 1) config.keepDuplicates (preferred)
  /// 2) Env var GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER = 1/true/yes/on
  /// 3) Default false
  bool _shouldMoveDuplicatesToFolder(final ProcessingContext context) {
    try {
      final dynamic keepDuplicates = context.config.keepDuplicates;
      if (keepDuplicates is bool) return keepDuplicates;
    } catch (_) {
      // ignore and fallback
    }
    try {
      final env = Platform.environment['GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER'];
      if (env != null) {
        final s = env.trim().toLowerCase();
        return s == '1' || s == 'true' || s == 'yes' || s == 'on';
      }
    } catch (_) {
      // ignore
    }
    return false;
  }

  String _safePath(final File f) {
    try {
      return f.path;
    } catch (_) {
      return '<unknown-file>';
    }
  }

  Future<bool> _removeOrQuarantineDuplicates(
    final Set<MediaEntity> duplicates,
    final ProcessingContext context,
  ) async {
    // If config says "move to _Duplicates", move; otherwise delete from input
    final bool moveToDuplicates = _shouldMoveDuplicatesToFolder(context);

    final String inputRoot = context.inputDirectory.path;
    final String outputRoot = context.outputDirectory.path;

    for (final e in duplicates) {
      final File f = e.primaryFile;

      // Compute relative path inside input; if it fails, fallback to basename only
      String rel;
      try {
        rel = path.relative(f.path, from: inputRoot);
      } catch (_) {
        rel = path.basename(f.path);
      }

      try {
        if (moveToDuplicates) {
          final String destPath = path.join(outputRoot, '_Duplicates', rel);
          final Directory destDir = Directory(path.dirname(destPath));
          if (!await destDir.exists()) {
            await destDir.create(recursive: true);
          }
          try {
            await f.rename(destPath);
          } catch (_) {
            // Cross-device fallback: copy then delete
            await f.copy(destPath);
            await f.delete();
          }
        } else {
          await f.delete();
        }
      } catch (ioe) {
        logWarning('Failed to remove/move duplicate ${f.path}: $ioe', forcePrint: true);
      }
    }
    return moveToDuplicates;
  }

  // ===== Old-pipeline helpers =====

  /// Lowercase extension without dot, safe for hidden files.
  String _extOf(final String p) {
    final int slash = p.lastIndexOf(Platform.pathSeparator);
    final String base = (slash >= 0) ? p.substring(slash + 1) : p;
    final int dot = base.lastIndexOf('.');
    if (dot <= 0) return ''; // no ext or hidden like ".gitignore"
    return base.substring(dot + 1).toLowerCase();
  }

  /// Quick signature: size|ext|FNV1a32(head up-to-64KB)
  Future<String> _quickSignature(final File file, final int size, final String ext) async {
    final int toRead = size > 0 ? (size < 65536 ? size : 65536) : 65536;
    List<int> head = const [];
    try {
      final raf = await file.open();
      try {
        head = await raf.read(toRead);
      } finally {
        await raf.close();
      }
    } catch (_) {
      head = const [];
    }

    // FNV-1a 32-bit hash
    int hash = 0x811C9DC5;
    for (final b in head) {
      hash ^= (b & 0xFF);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '$size|$ext|$hash';
  }

  /// Year-based entities discovered in Step 2 have no album metadata.
  bool _isYearEntity(final MediaEntity e) => e.belongToAlbums.isEmpty;
}
