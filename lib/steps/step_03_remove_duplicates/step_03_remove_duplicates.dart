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

      final duplicateService = ServiceContainer.instance.duplicateDetectionService;
      final bool verify = _isVerifyEnabled();
      final MediaHashService verifier = verify ? MediaHashService() : MediaHashService(maxCacheSize: 1);

      int removedCount = 0;

      // Use the fastest grouping available (size → tri-sample fingerprint → full hash within candidates)
      Map<String, List<MediaEntity>> groups = const {};
      try {
        groups = await duplicateService.groupIdenticalFast(mediaCol.entities.toList());
      } catch (e) {
        logWarning('FAST duplicate grouping failed, falling back to standard grouping: $e', forcePrint: true);
        groups = await duplicateService.groupIdentical(mediaCol.entities.toList());
      }

      final Set<MediaEntity> entitiesToRemove = <MediaEntity>{};

      bool _isSizeOnlyKey(final String k) {
        // Matches "<digits>bytes" (e.g., "12345bytes")
        if (!k.endsWith('bytes')) return false;
        final prefix = k.substring(0, k.length - 5);
        for (int i = 0; i < prefix.length; i++) {
          final c = prefix.codeUnitAt(i);
          if (c < 48 || c > 57) return false;
        }
        return true;
      }

      bool _isYearEntity(final MediaEntity e) {
        // Year-based entities discovered in Step 2 have no album metadata
        return e.belongToAlbums.isEmpty;
      }

      int processedGroups = 0;
      final int totalGroups = groups.length;

      // Iterate groups; only treat as duplicates those grouped by HASH (not by size)
      for (final entry in groups.entries) {
        final String key = entry.key;
        final List<MediaEntity> group = entry.value;

        processedGroups++;
        if (group.length <= 1) continue;

        // Ignore size-only groups even if length > 1 (they are NOT duplicates by definition)
        if (_isSizeOnlyKey(key)) {
          logDebug('Skipping size-only group "$key" with ${group.length} items (not duplicates by hash).');
          continue;
        }

        // Sort group by: date accuracy (asc) → basename length (asc) → prefer Year over Album → full path length (asc) → stable path lex
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

        // Start with kept0 and merge others into it (accumulate album metadata and secondaryFiles)
        MediaEntity kept = kept0;

        if (verify) {
          try {
            final String keptHash = await verifier.calculateFileHash(kept.primaryFile);
            for (final d in toRemove) {
              try {
                final String dupHash = await verifier.calculateFileHash(d.primaryFile);
                if (dupHash != keptHash) {
                  logWarning('Verification mismatch. Will NOT remove ${d.primaryFile.path} (hash differs from kept).', forcePrint: true);
                  continue;
                }
                kept = kept.mergeWith(d); // accumulate metadata + secondary list
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
            kept = kept.mergeWith(d); // accumulate metadata + secondary list
            entitiesToRemove.add(d);
            removedCount++;
          }
        }

        // Replace the kept entity in the collection with the merged version
        _replaceEntityInCollection(mediaCol, kept0, kept);

        if ((processedGroups % 1000) == 0) print('[Step 3/8] Progress: resolved $processedGroups/$totalGroups groups...');
      }

      // Apply removals (and physically delete/move duplicates according to configuration)
      if (entitiesToRemove.isNotEmpty) {
        print('🧹 Skipping ${entitiesToRemove.length} entities from collection');
        final bool moved = await _removeOrQuarantineDuplicates(entitiesToRemove, context);
        for (final e in entitiesToRemove) {
          try {
            mediaCol.remove(e);
          } catch (err) {
            logWarning('Failed to remove entity ${_safeEntity(e)}: $err', forcePrint: true);
          }
        }
        if (moved) {
          print('✅ Duplicates moved to _Duplicates keeping relative paths.');
        } else {
          print('✅ Duplicates deleted from input folder.');
        }
      }

      print('✅ Remove Duplicates finished, total duplicates found: $removedCount');

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'duplicatesRemoved': removedCount,
          'remainingMedia': mediaCol.length,
        },
        message: 'Removed $removedCount duplicate files (they will be moved to "_Duplicates" sub-folder in Output folder)\n${mediaCol.length} media files remain.',
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
  /// 1) ServiceContainer.instance.globalConfig.moveDuplicatesToDuplicatesFolder (dynamic, if present)
  /// 2) Env var GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER = 1/true/yes/on
  /// 3) Default false
  bool _shouldMoveDuplicatesToFolder(final ProcessingContext context) {
    try {
      final dynamic cfg = ServiceContainer.instance.globalConfig;
      final dynamic v = cfg?.moveDuplicatesToDuplicatesFolder;
      if (v is bool) return v;
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
        logWarning('Failed to remove/move duplicate ${f.path}: $ioe', forcePrint: true);
      }
    }
    return moveToDuplicates;
  }
}
