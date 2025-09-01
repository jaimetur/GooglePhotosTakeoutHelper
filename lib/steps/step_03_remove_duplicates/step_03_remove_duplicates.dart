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
/// ## Performance note (added):
/// For maximum throughput on very large datasets, this step calls `DuplicateDetectionService.groupIdenticalFast(...)`,
/// which pre-clusters by file size and a small tri-sample fingerprint before running full hashes only inside
/// those subgroups. This dramatically reduces I/O and CPU when many files share sizes but are not identical.
class RemoveDuplicatesStep extends ProcessingStep with LoggerMixin {
  RemoveDuplicatesStep() : super('Remove Duplicates');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final totalSw = Stopwatch()..start();
    final mediaCol = context.mediaCollection;

    // ────────────────────────────────────────────────────────────────────────────
    // Telemetry / Performance instrumentation (aggregate over the whole step)
    // ────────────────────────────────────────────────────────────────────────────
    final _Telemetry telem = _Telemetry();

    try {
      if (mediaCol.isEmpty) {
        totalSw.stop();
        return StepResult.success(
          stepName: name,
          duration: totalSw.elapsed,
          data: {'duplicatesRemoved': 0, 'remainingMedia': 0},
          message: 'No media to process.',
        );
      }

      print('\n[Step 3/8] Removing duplicates (this may take a while)...');
      if (context.config.keepDuplicates) {
        print(
          '[Step 3/8] Flag `--keep-duplicates` detected. Duplicates will be moved to `_Duplicates` subfolder within output folder',
        );
      }

      final duplicateService = ServiceContainer.instance.duplicateDetectionService;
      final bool verify = _isVerifyEnabled();
      final MediaHashService verifier =
          verify ? MediaHashService() : MediaHashService(maxCacheSize: 1);

      // ────────────────────────────────────────────────────────────────────────
      // 1) SIZE BUCKETS (cheap pre-partition)  ── old fast pipeline restored
      // ────────────────────────────────────────────────────────────────────────
      final sizeSw = Stopwatch()..start();
      final Map<int, List<MediaEntity>> sizeBuckets = <int, List<MediaEntity>>{};
      for (final e in mediaCol.entities) {
        int size;
        try {
          size = e.primaryFile.lengthSync();
        } catch (_) {
          size = -1; // unprocessable bucket
        }
        (sizeBuckets[size] ??= <MediaEntity>[]).add(e);
      }
      sizeSw.stop();
      telem.msSizeScan += sizeSw.elapsedMilliseconds;
      telem.sizeBuckets = sizeBuckets.length;
      telem.filesTotal = mediaCol.length;

      // Concurrency cap (kept conservative to avoid I/O thrash)
      final int maxWorkers =
          ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif).clamp(1, 8);

      // Process buckets in slices
      final bucketKeys = sizeBuckets.keys.toList();
      int processedGroups = 0;
      final int totalGroups = bucketKeys.length;

      // We will aggregate: replacements to apply and entities to remove
      final List<_Replacement> pendingReplacements = <_Replacement>[];
      final Set<MediaEntity> entitiesToRemove = <MediaEntity>{};

      Future<_BucketOutcome> _processSizeBucket(final int sizeKey) async {
        final _BucketStats bs = _BucketStats();
        final List<_Replacement> localRepl = <_Replacement>[];
        final Set<MediaEntity> localToRemove = <MediaEntity>{};

        final List<MediaEntity> candidates = sizeBuckets[sizeKey]!;
        if (candidates.length <= 1) {
          return _BucketOutcome(bs, localRepl, localToRemove);
        }

        // ────────────────────────────────────────────────────────────────────
        // 2) EXTENSION SUB-BUCKETS (avoid mixing media types with same size)
        // ────────────────────────────────────────────────────────────────────
        final extSw = Stopwatch()..start();
        final Map<String, List<MediaEntity>> extBuckets = <String, List<MediaEntity>>{};
        for (final e in candidates) {
          final String ext = _extOf(e.primaryFile.path);
          (extBuckets[ext] ??= <MediaEntity>[]).add(e);
        }
        extSw.stop();
        bs.msExtBucket += extSw.elapsedMilliseconds;
        bs.extBuckets += extBuckets.length;

        for (final entry in extBuckets.entries) {
          final List<MediaEntity> extGroup = entry.value;
          if (extGroup.length <= 1) continue;

          // ────────────────────────────────────────────────────────────────
          // 3) QUICK SIGNATURE (size | ext | FNV-1a head up to 64KB) split
          // ────────────────────────────────────────────────────────────────
          final qsigSw = Stopwatch()..start();
          final Map<String, List<MediaEntity>> quickBuckets =
              <String, List<MediaEntity>>{};
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
          qsigSw.stop();
          bs.msQuickSig += qsigSw.elapsedMilliseconds;
          bs.quickBuckets += quickBuckets.length;

          // ────────────────────────────────────────────────────────────────
          // 4) HASH GROUPING only inside each tiny quick-bucket
          // ────────────────────────────────────────────────────────────────
          for (final q in quickBuckets.values) {
            if (q.length <= 1) continue;

            final hashSw = Stopwatch()..start();
            // NOTE: we use the standard groupIdentical here (full content hash + verify equality)
            final Map<String, List<MediaEntity>> hashGroups =
                await duplicateService.groupIdentical(q);
            hashSw.stop();
            bs.msHashGroups += hashSw.elapsedMilliseconds;
            bs.hashGroups += hashGroups.length;

            // Resolve each duplicate group
            for (final group in hashGroups.values) {
              if (group.length <= 1) continue;

              // Sort by: date accuracy (asc) → basename length (asc) → prefer Year → full path length (asc) → path lex
              group.sort((a, b) {
                final aAcc = a.dateAccuracy?.value ?? 999;
                final bAcc = b.dateAccuracy?.value ?? 999;
                if (aAcc != bAcc) return aAcc.compareTo(bAcc);

                final aBaseLen = path.basename(a.primaryFile.path).length;
                final bBaseLen = path.basename(b.primaryFile.path).length;
                if (aBaseLen != bBaseLen) return aBaseLen.compareTo(bBaseLen);

                final aYear = a.belongToAlbums.isEmpty;
                final bYear = b.belongToAlbums.isEmpty;
                if (aYear != bYear) return aYear ? -1 : 1; // prefer Year

                final aPathLen = a.primaryFile.path.length;
                final bPathLen = b.primaryFile.path.length;
                if (aPathLen != bPathLen) return aPathLen.compareTo(bPathLen);

                return a.primaryFile.path.compareTo(b.primaryFile.path);
              });

              final MediaEntity kept0 = group.first;
              final List<MediaEntity> toRemove = group.sublist(1);

              // Merge metadata using immutable MediaEntity.mergeWith
              final mergeSw = Stopwatch()..start();
              MediaEntity kept = kept0;

              if (verify) {
                try {
                  final String keptHash =
                      await verifier.calculateFileHash(kept.primaryFile);
                  for (final d in toRemove) {
                    try {
                      final String dupHash =
                          await verifier.calculateFileHash(d.primaryFile);
                      if (dupHash != keptHash) {
                        logWarning(
                          'Verification mismatch. Will NOT remove ${d.primaryFile.path} (hash differs from kept).',
                          forcePrint: true,
                        );
                        continue;
                      }
                      kept = kept.mergeWith(d);
                      localToRemove.add(d);
                      bs.duplicatesRemoved++;
                    } catch (e) {
                      logWarning(
                        'Verification failed for ${d.primaryFile.path}: $e. Skipping removal for safety.',
                        forcePrint: true,
                      );
                    }
                  }
                } catch (e) {
                  logWarning(
                    'Could not hash kept file ${_safePath(kept.primaryFile)} for verification: $e. Skipping removals for this group.',
                    forcePrint: true,
                  );
                }
              } else {
                for (final d in toRemove) {
                  kept = kept.mergeWith(d);
                  localToRemove.add(d);
                  bs.duplicatesRemoved++;
                }
              }

              // Defer collection mutation: record replacement (kept0 → kept)
              localRepl.add(_Replacement(kept0: kept0, kept: kept));
              mergeSw.stop();
              bs.msMergeReplace += mergeSw.elapsedMilliseconds;
            }
          }
        }

        return _BucketOutcome(bs, localRepl, localToRemove);
      }

      for (int i = 0; i < bucketKeys.length; i += maxWorkers) {
        final slice = bucketKeys.skip(i).take(maxWorkers).toList(growable: false);
        final outcomes = await Future.wait(slice.map(_processSizeBucket));

        // Aggregate telemetry and outcomes
        for (final out in outcomes) {
          telem.addStats(out.stats);
          pendingReplacements.addAll(out.replacements);
          entitiesToRemove.addAll(out.toRemove);
        }

        processedGroups += slice.length;
        if ((processedGroups % 50) == 0) {
          logDebug('[Step 3/8] Progress: processed $processedGroups/$totalGroups size groups...');
        }
      }

      // Apply replacements sequentially (safe mutation of collection)
      for (final r in pendingReplacements) {
        _replaceEntityInCollection(mediaCol, r.kept0, r.kept);
      }

      // Apply removals (and physically delete/move duplicates according to configuration)
      int removedCount = entitiesToRemove.length;
      if (entitiesToRemove.isNotEmpty) {
        print('[Step 3/8] Removing ${entitiesToRemove.length} files from media collection');

        final ioSw = Stopwatch()..start();
        final bool moved =
            await _removeOrQuarantineDuplicates(entitiesToRemove, context);
        ioSw.stop();
        telem.msRemoveIO += ioSw.elapsedMilliseconds;

        for (final e in entitiesToRemove) {
          try {
            mediaCol.remove(e);
          } catch (err) {
            logWarning(
              'Failed to remove entity ${_safeEntity(e)}: $err',
              forcePrint: true,
            );
          }
        }
        if (moved) {
          print(
            '[Step 3/8] Duplicates moved to _Duplicates (flag --keep-duplicates = true)',
          );
        } else {
          print('[Step 3/8] Duplicates deleted from input folder.');
        }
      }

      print('[Step 3/8] Remove Duplicates finished, total duplicates found: $removedCount');

      totalSw.stop();
      telem.msTotal = totalSw.elapsedMilliseconds;

      // ────────────────────────────────────────────────────────────────────────
      // Telemetry summary (compact, human-friendly)
      // ────────────────────────────────────────────────────────────────────────
      _printTelemetry(telem);

      return StepResult.success(
        stepName: name,
        duration: totalSw.elapsed,
        data: {
          'duplicatesRemoved': removedCount,
          'remainingMedia': mediaCol.length,
          // expose some key telemetry for programmatic consumption
          'sizeBuckets': telem.sizeBuckets,
          'quickBuckets': telem.quickBuckets,
          'hashGroups': telem.hashGroups,
          'msTotal': telem.msTotal,
          'msSizeScan': telem.msSizeScan,
          'msQuickSig': telem.msQuickSig,
          'msHashGroups': telem.msHashGroups,
          'msMergeReplace': telem.msMergeReplace,
          'msRemoveIO': telem.msRemoveIO,
        },
        message:
            'Removed $removedCount duplicate files from input folder\n   ${mediaCol.length} media files remain.',
      );
    } catch (e) {
      totalSw.stop();
      return StepResult.failure(
        stepName: name,
        duration: totalSw.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to remove duplicates: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;

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
  /// 1) ServiceContainer.instance.globalConfig.moveDuplicatesToDuplicatesFolder (dynamic, if present)
  /// 2) Env var GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER = 1/true/yes/on
  /// 3) Default false
  bool _shouldMoveDuplicatesToFolder(final ProcessingContext context) {
    try {
      // final dynamic cfg = ServiceContainer.instance.globalConfig;
      // final dynamic v = cfg?.moveDuplicatesToDuplicatesFolder;
      final dynamic keepDuplicates = context.config.keepDuplicates;
      if (keepDuplicates is bool) return keepDuplicates;
    } catch (_) {
      // ignore and fallback
    }
    try {
      final env =
          Platform.environment['GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER'];
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

  String _safeEntity(final MediaEntity e) {
    try {
      return e.primaryFile.path;
    } catch (_) {
      return '<unknown-entity>';
    }
  }

  void _replaceEntityInCollection(
    final MediaEntityCollection col,
    final MediaEntity oldE,
    final MediaEntity newE,
  ) {
    // Cheap linear replace using operators exposed by your collection
    for (int i = 0; i < col.length; i++) {
      try {
        if (identical(col[i], oldE) || col[i] == oldE) {
          col[i] = newE;
          return;
        }
      } catch (_) {
        // ignore and continue
      }
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
        logWarning('Failed to remove/move duplicate ${f.path}: $ioe',
            forcePrint: true);
      }
    }
    return moveToDuplicates;
  }

  // Helper: lowercase extension
  String _extOf(final String p) {
    final int slash = p.lastIndexOf(Platform.pathSeparator);
    final String base = (slash >= 0) ? p.substring(slash + 1) : p;
    final int dot = base.lastIndexOf('.');
    if (dot <= 0) return '';
    return base.substring(dot + 1).toLowerCase();
  }

  // Helper: quick signature (size | ext | FNV-1a32 of head up to 64 KB)
  Future<String> _quickSignature(
    final File file,
    final int size,
    final String ext,
  ) async {
    final int toRead =
        size > 0 ? (size < 65536 ? size : 65536) : 65536; // 64 KiB cap
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

    // FNV-1a 32-bit
    int hash = 0x811C9DC5;
    for (final b in head) {
      hash ^= (b & 0xFF);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '$size|$ext|$hash';
  }

  void _printTelemetry(final _Telemetry t) {
    String ms(num v) => '${v.toStringAsFixed(0)} ms';
    print(''); // spacing
    print('[Step 3/8] Telemetry summary:');
    print('  Files total           : ${t.filesTotal}');
    print('  Size buckets          : ${t.sizeBuckets}');
    print('  Ext buckets           : ${t.extBuckets}');
    print('  Quick buckets         : ${t.quickBuckets}');
    print('  Hash groups           : ${t.hashGroups}');
    print('  Duplicates removed    : ${t.duplicatesRemoved}');
    print('  Time total            : ${ms(t.msTotal)}');
    print('    - Size scan         : ${ms(t.msSizeScan)}');
    print('    - Ext bucketing     : ${ms(t.msExtBucket)}');
    print('    - Quick signature   : ${ms(t.msQuickSig)}');
    print('    - Hash grouping     : ${ms(t.msHashGroups)}');
    print('    - Merge/replace     : ${ms(t.msMergeReplace)}');
    print('    - Remove/IO         : ${ms(t.msRemoveIO)}');
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Telemetry support types
// ──────────────────────────────────────────────────────────────────────────────

class _Telemetry {
  int filesTotal = 0;
  int sizeBuckets = 0;
  int extBuckets = 0;
  int quickBuckets = 0;
  int hashGroups = 0;
  int duplicatesRemoved = 0;

  num msTotal = 0;
  num msSizeScan = 0;
  num msExtBucket = 0;
  num msQuickSig = 0;
  num msHashGroups = 0;
  num msMergeReplace = 0;
  num msRemoveIO = 0;

  void addStats(final _BucketStats s) {
    extBuckets += s.extBuckets;
    quickBuckets += s.quickBuckets;
    hashGroups += s.hashGroups;
    duplicatesRemoved += s.duplicatesRemoved;
    msExtBucket += s.msExtBucket;
    msQuickSig += s.msQuickSig;
    msHashGroups += s.msHashGroups;
    msMergeReplace += s.msMergeReplace;
  }
}

class _BucketStats {
  int extBuckets = 0;
  int quickBuckets = 0;
  int hashGroups = 0;
  int duplicatesRemoved = 0;

  num msExtBucket = 0;
  num msQuickSig = 0;
  num msHashGroups = 0;
  num msMergeReplace = 0;
}

class _BucketOutcome {
  _BucketOutcome(this.stats, this.replacements, this.toRemove);
  final _BucketStats stats;
  final List<_Replacement> replacements;
  final Set<MediaEntity> toRemove;
}

class _Replacement {
  _Replacement({required this.kept0, required this.kept});
  final MediaEntity kept0;
  final MediaEntity kept;
}
