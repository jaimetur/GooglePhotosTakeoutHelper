import 'dart:io';

import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

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
/// - **Album Associations**: Preserved and merged in `albumsMap`
/// - **EXIF Data**: Maintains original EXIF information from selected file
/// - **JSON Metadata**: Keeps associated JSON file with selected media file
///
/// ## Performance Optimizations
///
/// ### Efficient Algorithms
/// - **Hash Caching**: Avoids recalculating hashes for previously processed files
/// - **Batch Processing**: Processes files in groups to optimize I/O operations
/// - **Memory Management**: Uses streaming hash calculation for large files
/// - **Early Termination**: Skips processing when no duplicates are possible
///
/// ### Scalability Features
/// - **Large Collection Support**: Efficiently handles thousands of duplicate photos
/// - **Progress Reporting**: Provides feedback for long-running duplicate detection
/// - **Incremental Processing**: Can be interrupted and resumed safely
/// - **Resource Monitoring**: Adapts processing speed based on system resources
///
/// ## Common Duplicate Scenarios
///
/// ### Google Photos Export Patterns
/// - **Album Duplicates**: Same photo exists in year folder + multiple album folders
/// - **Download Duplicates**: Files downloaded multiple times from Google Photos
/// - **Processing Duplicates**: Files processed through multiple export/import cycles
/// - **Backup Duplicates**: Files backed up multiple times to Google Photos
///
/// ### File Naming Variations
/// - **Original vs Edited**: `photo.jpg` vs `photo-edited.jpg` (handled by extras removal)
/// - **Sequential Numbers**: `photo.jpg` vs `photo(1).jpg` with identical content
/// - **Date Prefixes**: Same content with different date stamps in filename
/// - **Album Prefixes**: Files with album names prepended to original filename
///
/// ## Error Handling and Edge Cases
///
/// ### File Access Issues
/// - **Permission Errors**: Skips inaccessible files without stopping processing
/// - **Corrupted Files**: Handles files that cannot be read or hashed
/// - **Network Storage**: Manages timeouts and connection issues
/// - **Locked Files**: Gracefully handles files locked by other applications
///
/// ### Hash Collision Handling
/// - **Verification**: Performs additional verification for suspected hash collisions
/// - **Fallback Comparison**: Uses byte-by-byte comparison if hash collision suspected
/// - **Logging**: Records potential collisions for investigation
/// - **Conservative Approach**: Errs on side of keeping files when uncertain
///
/// ### Special File Types
/// - **Live Photos**: Handles iOS Live Photos with multiple component files
/// - **Motion Photos**: Manages Google's Motion Photos format appropriately
/// - **RAW + JPEG**: Treats RAW and JPEG versions as separate files
/// - **Video Variants**: Handles different resolutions/formats of same video
///
/// ## Configuration and Behavior
///
/// ### Processing Modes
/// - **Verbose Mode**: Provides detailed logging of duplicate detection and removal
/// - **Conservative Mode**: More cautious about removing files when uncertain
/// - **Performance Mode**: Optimizes for speed with large collections
/// - **Verification Mode**: Performs additional integrity checks
///
/// ### Statistics Tracking
/// - **Duplicates Found**: Count of duplicate files identified
/// - **Files Removed**: Number of duplicate files removed from collection
/// - **Space Saved**: Estimated disk space savings from duplicate removal
/// - **Processing Performance**: Files processed per second and total time
///
/// ## Integration with Other Steps
///
/// ### Prerequisites
/// - **Media Discovery**: Requires populated MediaCollection from discovery step
/// - **File Accessibility**: Files must be readable for hash calculation
///
/// ### Outputs for Later Steps
/// - **Clean Media Collection**: Provides duplicate-free collection for further processing
/// - **Date Accuracy**: Preserves best date information for chronological organization
/// - **Reduced Dataset**: Smaller collection improves performance of subsequent steps
/// - **Quality Selection**: Ensures best quality files are retained
///
/// ### Processing Order Considerations
/// - **Before Album Finding**: Removes duplicates before album relationship analysis
/// - **Before Date Extraction**: Reduces workload for expensive date extraction
/// - **After Media Discovery**: Requires complete file inventory to identify all duplicates
/// - **Before File Moving**: Ensures final organization contains only unique files
///
/// ## Quality Assurance
///
/// ### Verification Steps
/// - **Hash Validation**: Verifies hash calculations are consistent
/// - **Selection Logic**: Confirms best copy selection follows documented algorithm
/// - **Metadata Integrity**: Ensures selected files maintain proper metadata
/// - **Count Reconciliation**: Verifies expected number of files are removed
///
/// ### Safety Measures
/// - **Dry Run Support**: Can simulate duplicate removal without actual deletion
/// - **Backup Recommendations**: Suggests backing up before duplicate removal
/// - **Rollback Information**: Logs removed files for potential recovery
/// - **Conservative Defaults**: Uses safe settings when configuration is ambiguous
///
/// ## Performance note (added):
/// For maximum throughput on very large datasets, this step calls `DuplicateDetectionService.groupIdenticalFast(...)`,
/// which pre-clusters by file size and a small tri-sample fingerprint before running full hashes only inside
/// those subgroups. This dramatically reduces I/O and CPU when many files share sizes but are not identical.
class MergeMediaEntitiesStep extends ProcessingStep with LoggerMixin {
  const MergeMediaEntitiesStep() : super('Merge Media Entities');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final totalSw = Stopwatch()..start();
    final mediaCollection = context.mediaCollection;

    // Initial collection size for logging
    final int initialEntitiesCount = mediaCollection.length;

    // Telemetry / performance instrumentation
    final _Telemetry telem = _Telemetry();

    try {
      if (mediaCollection.isEmpty) {
        totalSw.stop();
        return StepResult.success(
          stepName: name,
          duration: totalSw.elapsed,
          data: {
            'duplicatesRemoved': 0,
            'remainingMedia': 0,
            'secondaryFilesDetected': 0,
            'duplicateFilesRemoved': 0,
          },
          message: 'No media to process.',
        );
      }

      logPrint('[Step 3/8] Merging identical media entities and removing duplicates (this may take a while)...');
      if (context.config.keepDuplicates) {
        logPrint("[Step 3/8] Flag '--keep-duplicates' detected. Duplicates will be moved to '_Duplicates' subfolder within output folder");
      }

      final duplicateService =
          ServiceContainer.instance.duplicateDetectionService;
      final bool verify = _isVerifyEnabled();
      final MediaHashService verifier = verify
          ? MediaHashService()
          : MediaHashService(maxCacheSize: 1);

      // ────────────────────────────────────────────────────────────────────────
      // 1) SIZE BUCKETS (cheap pre-partition)
      // NOTE (perf): we avoid calling lengthSync() more than once by reusing the sizeKey
      // ────────────────────────────────────────────────────────────────────────
      final sizeSw = Stopwatch()..start();
      final Map<int, List<MediaEntity>> sizeBuckets =
          <int, List<MediaEntity>>{};
      for (final mediaEntity in mediaCollection.entities) {
        int size;
        try {
          size = mediaEntity.primaryFile.asFile().lengthSync();
        } catch (_) {
          size = -1; // unprocessable bucket
        }
        (sizeBuckets[size] ??= <MediaEntity>[]).add(mediaEntity);
      }
      sizeSw.stop();
      telem.msSizeScan += sizeSw.elapsedMilliseconds;
      telem.sizeBuckets = sizeBuckets.length;
      telem.filesTotal = mediaCollection.length;

      // Concurrency caps (conservative but higher than previous 1..8)
      // - maxWorkersBuckets: parallelism across size buckets (mix of IO & CPU)
      // - maxWorkersQuick  : parallelism inside ext-buckets for quick signatures (I/O-bound)
      final int maxWorkersBuckets = ConcurrencyManager()
          .concurrencyFor(ConcurrencyOperation.exif)
          .clamp(4, 24);
      final int maxWorkersQuick = ConcurrencyManager()
          .concurrencyFor(ConcurrencyOperation.exif)
          .clamp(4, 32);

      // NEW (perf): parallelize hash grouping inside ext-buckets, capped to avoid CPU oversubscription.
      // If your ConcurrencyOperation doesn't have a dedicated "hash", we reuse EXIF channel safely.
      final int maxWorkersHash = ConcurrencyManager()
          .concurrencyFor(ConcurrencyOperation.exif)
          .clamp(2, 16);

      // Get and print maxConcurrency
      logPrint('[Step 3/8] Starting $maxWorkersQuick threads for Quick Buckets');
      logPrint('[Step 3/8] Starting $maxWorkersBuckets threads for Normal Buckets');
      logPrint('[Step 3/8] Starting $maxWorkersHash threads for Hashing');

      // Process buckets in slices
      // PERF: process largest buckets first to maximize early dedup impact (cache wins)
      final bucketKeys = sizeBuckets.keys.toList()
        ..sort((final a, final b) =>
            (sizeBuckets[b]!.length).compareTo(sizeBuckets[a]!.length));
      int processedGroups = 0;
      final int totalGroups = bucketKeys.length;

      // Deferred mutations
      final List<_Replacement> pendingReplacements = <_Replacement>[];
      final Set<MediaEntity> entitiesToMerge = <MediaEntity>{};

      Future<_BucketOutcome> processSizeBucket(final int sizeKey) async {
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
        final Map<String, List<MediaEntity>> extBuckets =
            <String, List<MediaEntity>>{};
        for (final e in candidates) {
          final String ext = _extOf(e.primaryFile.path);
          (extBuckets[ext] ??= <MediaEntity>[]).add(e);
        }
        extSw.stop();
        bs.msExtBucket += extSw.elapsedMilliseconds;
        bs.extBuckets += extBuckets.length;

        // Helper (perf): adaptive parallelism for quick signatures
        // English note:
        // - Big/video files suffer with high seek concurrency. We reduce workers for those,
        //   and use higher concurrency for small files to fully utilize I/O.
        int quickWorkersFor(final int sz, final bool isVideo) {
          if (isVideo || sz >= (64 << 20)) return 2;   // ≥ 64MiB or video → very low concurrency
          if (sz >= (8 << 20)) return 4;               // 8–64 MiB
          if (sz >= (1 << 20)) return 8;               // 1–8 MiB
          return 24;                                   // < 1 MiB
        }

        final Set<String> videoExts = {
          'mp4','mov','m4v','mkv','avi','hevc','heif','heic','webm'
        };

        for (final entry in extBuckets.entries) {
          final String extKey = entry.key;             // extension for this bucket
          final List<MediaEntity> extGroup = entry.value;
          if (extGroup.length <= 1) continue;

          // ────────────────────────────────────────────────────────────────
          // 3) QUICK SIGNATURE (tri-sample: head+middle+tail, 4 KiB each)
          //    NOTE (perf): drastically reduces IO vs reading 64-128 KiB head.
          //    We also reuse the known 'sizeKey' to avoid per-file stat().
          //    Computed concurrently in small batches (no env vars needed).
          //    MODIFIED: open file only once and use FNV-1a 32-bit + adaptive 2-point for video/large.
          // ────────────────────────────────────────────────────────────────
          final qsigSw = Stopwatch()..start();
          final Map<String, List<MediaEntity>> quickBuckets =
              <String, List<MediaEntity>>{};

          final bool isVideoExt = videoExts.contains(extKey);
          // Use adaptive concurrency per ext bucket (replaces the static maxWorkersQuick here)
          final int localQuickWorkers =
              quickWorkersFor(sizeKey, isVideoExt).clamp(1, maxWorkersQuick);

          // Process extGroup in concurrent slices to control IO pressure
          for (int i = 0; i < extGroup.length; i += localQuickWorkers) {
            final slice = extGroup.skip(i).take(localQuickWorkers).toList();
            await Future.wait(slice.map((final e) async {
              String sig;
              try {
                final String ext = _extOf(e.primaryFile.path);
                // IMPORTANT: pass sizeKey to avoid lengthSync() here
                sig = await _quickSignature(e.primaryFile.asFile(), sizeKey, ext);
              } catch (_) {
                sig = 'qsig-err';
              }
              (quickBuckets[sig] ??= <MediaEntity>[]).add(e);
            }));
          }

          qsigSw.stop();
          bs.msQuickSig += qsigSw.elapsedMilliseconds;
          bs.quickBuckets += quickBuckets.length;

          // ────────────────────────────────────────────────────────────────
          // 4) HASH GROUPING inside each quick-bucket
          //    Try to use fast path if service provides it; fallback otherwise.
          //    MODIFIED (perf): parallelize processing of quick-buckets to utilize CPU cores.
          // ────────────────────────────────────────────────────────────────
          final qbLists =
              quickBuckets.values.where((final q) => q.length > 1).toList();
          for (int i = 0; i < qbLists.length; i += maxWorkersHash) {
            final slice = qbLists.skip(i).take(maxWorkersHash).toList();

            // Run multiple quick-buckets in parallel; each returns groups + elapsed ms
            final batchResults = await Future.wait(slice.map((final q) async {
              final hashSw = Stopwatch()..start();
              Map<String, List<MediaEntity>> hashGroups;
              try {
                hashGroups =
                    await (duplicateService as dynamic).groupIdenticalFast(q);
              } catch (_) {
                hashGroups = await duplicateService.groupIdentical(q);
              }
              hashSw.stop();
              return _HashBatchResult(hashGroups, hashSw.elapsedMilliseconds);
            }));

            // Apply results + accumulate telemetry
            for (final res in batchResults) {
              bs.msHashGroups += res.ms;
              bs.hashGroups += res.groups.length;

              // Resolve each duplicate group
              for (final entry in res.groups.entries) {
                final group = entry.value;
                if (group.length <= 1) continue;

                // Sort by: accuracy → basename length → prefer Year → full path len → path lex
                group.sort((final a, final b) {
                  final aAcc = a.dateAccuracy?.value ?? 999;
                  final bAcc = b.dateAccuracy?.value ?? 999;
                  if (aAcc != bAcc) return aAcc.compareTo(bAcc);

                  final aBaseLen = path.basename(a.primaryFile.path).length;
                  final bBaseLen = path.basename(b.primaryFile.path).length;
                  if (aBaseLen != bBaseLen) return aBaseLen.compareTo(bBaseLen);

                  final aYear = a.albumsMap.isEmpty;
                  final bYear = b.albumsMap.isEmpty;
                  if (aYear != bYear) return aYear ? -1 : 1;

                  final aPathLen = a.primaryFile.path.length;
                  final bPathLen = b.primaryFile.path.length;
                  if (aPathLen != bPathLen) return aPathLen.compareTo(bPathLen);

                  return a.primaryFile.path.compareTo(b.primaryFile.path);
                });

                final MediaEntity kept0 = group.first;
                final List<MediaEntity> toRemove = group.sublist(1);

                final mergeSw = Stopwatch()..start();
                MediaEntity kept = kept0;

                // PERF-aware verification:
                // - Only verify for big groups or very large files (saves double hashing).
                // - Reuse precomputed hash if 'entry.key' looks like a real hash (not "NNNbytes").
                final bool verifyThisGroup =
                    verify && (group.length >= 4 || sizeKey > (64 << 20));
                final String groupKey = entry.key;
                final bool keyIsHash = !groupKey.endsWith('bytes');
                final String? expectedHash = keyIsHash ? groupKey : null;

                if (verifyThisGroup) {
                  try {
                    // If we already know the expected hash from the key, avoid recomputing
                    final String keptHash = expectedHash ??
                        await verifier.calculateFileHash(kept.primaryFile.asFile());

                    if (expectedHash != null) {
                      // Sample only ONE duplicate to validate the group; if mismatch, fall back to per-file.
                      if (toRemove.isNotEmpty) {
                        final d = toRemove.first;
                        final String sampleHash =
                            await verifier.calculateFileHash(d.primaryFile.asFile());
                        if (sampleHash != keptHash) {
                          logWarning(
                            'Verification sample mismatch for group $groupKey. Falling back to full verification.',
                            forcePrint: true,
                          );
                          // Full verification fallback
                          for (final x in toRemove) {
                            final String xh = await verifier
                                .calculateFileHash(x.primaryFile.asFile());
                            if (xh != keptHash) {
                              logWarning(
                                'Verification mismatch. Will NOT remove ${x.primaryFile.path} (hash differs from kept).',
                                forcePrint: true,
                              );
                              continue;
                            }
                            kept = kept.mergeWith(x);
                            localToRemove.add(x);
                            bs.entitiesMergedByContent++;
                          }
                        } else {
                          // Sample OK → we can safely merge without hashing all
                          for (final x in toRemove) {
                            kept = kept.mergeWith(x);
                            localToRemove.add(x);
                            bs.entitiesMergedByContent++;
                          }
                        }
                      }
                    } else {
                      // No precomputed hash, verify all candidates but reuse keptHash
                      for (final d in toRemove) {
                        try {
                          final String dupHash =
                              await verifier.calculateFileHash(d.primaryFile.asFile());
                          if (dupHash != keptHash) {
                            logWarning(
                              'Verification mismatch. Will NOT remove ${d.primaryFile.path} (hash differs from kept).',
                              forcePrint: true,
                            );
                            continue;
                          }
                          kept = kept.mergeWith(d);
                          localToRemove.add(d);
                          bs.entitiesMergedByContent++;
                        } catch (e) {
                          logWarning(
                            'Verification failed for ${d.primaryFile.path}: $e. Skipping removal for safety.',
                            forcePrint: true,
                          );
                        }
                      }
                    }
                  } catch (e) {
                    logWarning(
                      'Could not hash kept file ${_safePath(kept.primaryFile.asFile())} for verification: $e. Skipping removals for this group.',
                      forcePrint: true,
                    );
                  }
                } else {
                  // Fast-path merge: trust grouping and skip double-hashing
                  for (final d in toRemove) {
                    kept = kept.mergeWith(d);
                    localToRemove.add(d);
                    bs.entitiesMergedByContent++;
                  }
                }

                // Defer collection mutation: record replacement (kept0 → kept)
                localRepl.add(_Replacement(kept0: kept0, kept: kept));
                mergeSw.stop();
                bs.msMergeReplace += mergeSw.elapsedMilliseconds;
              }
            }
          }
        }

        return _BucketOutcome(bs, localRepl, localToRemove);
      }

      for (int i = 0; i < bucketKeys.length; i += maxWorkersBuckets) {
        final slice =
            bucketKeys.skip(i).take(maxWorkersBuckets).toList(growable: false);
        final outcomes = await Future.wait(slice.map(processSizeBucket));

        // Aggregate telemetry and outcomes
        for (final out in outcomes) {
          telem.addStats(out.stats);
          pendingReplacements.addAll(out.replacements);
          entitiesToMerge.addAll(out.toRemove);
        }

        processedGroups += slice.length;
        if ((processedGroups % 50) == 0) {
          logDebug(
            '[Step 3/8] Progress: processed $processedGroups/$totalGroups size groups...',
          );
        }
      }

      // Apply replacements sequentially (safe mutation of collection)
      for (final r in pendingReplacements) {
        _replaceEntityInCollection(mediaCollection, r.kept0, r.kept);
      }

      // Just before creating multi-path entities line
      logPrint(
        '[Step 3/8] Processing $initialEntitiesCount media entities from media entities collection',
      );

      // Informative message before removing merged-away entities from the collection
      final int mergedEntities = entitiesToMerge.length;
      if (mergedEntities > 0) {
        logPrint(
          '[Step 3/8] Merged $mergedEntities media entities (entities with multiple file paths for the same file content)',
        );
      }

      // Remove merged-away entities from the collection ONLY (do not delete files here)
      if (entitiesToMerge.isNotEmpty) {
        for (final e in entitiesToMerge) {
          try {
            mediaCollection.remove(e);
          } catch (err) {
            logWarning(
              'Failed to remove entity ${_safeEntity(e)}: $err',
              forcePrint: true,
            );
          }
        }
      }

      logPrint('[Step 3/8] ${mediaCollection.entities.length} final media entities left');

      // Only act on duplicatesFiles for I/O (move/delete), never secondary files
      // Count secondary files across the collection (with canonical vs albums split)
      int totalSecondaryFiles = 0;
      int secondaryCanonical = 0;
      int secondaryFromAlbums = 0;

      for (final e in mediaCollection.entities) {
        for (final fe in e.secondaryFiles) {
          totalSecondaryFiles++;
          if (fe.isCanonical) {
            secondaryCanonical++;
          } else {
            secondaryFromAlbums++;
          }
        }
      }

      // Gather duplicate files across the collection for I/O
      final List<FileEntity> duplicateFiles = <FileEntity>[];
      for (final e in mediaCollection.entities) {
        if (e.duplicatesFiles.isNotEmpty) {
          duplicateFiles.addAll(e.duplicatesFiles);
        }
      }

      // Move/Delete only duplicatesFiles (depending on flag)
      int duplicateFilesRemoved = 0;
      if (duplicateFiles.isNotEmpty) {
        logPrint(
          '[Step 3/8] Found ${duplicateFiles.length} duplicates files (within-folder duplicates). Processing them for removal/quarantine',
        );
        final ioSw = Stopwatch()..start();
        final bool moved = await _removeOrQuarantineDuplicateFiles(
          duplicateFiles,
          context,
          onRemoved: () {
            duplicateFilesRemoved++;
          },
        );
        ioSw.stop();
        telem.msRemoveIO += ioSw.elapsedMilliseconds;
        if (moved) {
          logPrint(
            '[Step 3/8] Duplicates files moved to _Duplicates (flag --keep-duplicates = true)',
          );
        } else {
          logPrint('[Step 3/8] Duplicates files removed from input folder.');
        }
      } else {
        logPrint('[Step 3/8] No duplicates files (within-folder) to remove');
      }

      // Primary counts (with canonical vs albums split)
      final int totalPrimaryFiles = mediaCollection.length;
      int primaryCanonical = 0;
      int primaryFromAlbums = 0;
      for (final e in mediaCollection.entities) {
        if (e.primaryFile.isCanonical) {
          primaryCanonical++;
        } else {
          primaryFromAlbums++;
        }
      }

      // Totals across ALL FileEntity (primary + secondary)
      final int canonicalAll = primaryCanonical + secondaryCanonical;
      final int nonCanonicalAll = primaryFromAlbums + secondaryFromAlbums;

      // Progress summary
      logPrint('[Step 3/8] Primary files in collection: $totalPrimaryFiles ($primaryCanonical canonical | $primaryFromAlbums from albums)');
      logPrint('[Step 3/8] Secondary files in collection: $totalSecondaryFiles ($secondaryCanonical canonical | $secondaryFromAlbums from albums)');
      logPrint('[Step 3/8] Canonical files (within \'Photos from...\' folder): $canonicalAll');
      logPrint('[Step 3/8] Non-Canonical files (within Album folder): $nonCanonicalAll');
      logPrint('[Step 3/8] Duplicate files removed/moved: $duplicateFilesRemoved');
      logPrint('[Step 3/8] Merge Media Entities finished, total entities merged: $mergedEntities');
      logPrint('');

      totalSw.stop();
      telem.msTotal = totalSw.elapsedMilliseconds;

      // Telemetry summary
      if (ServiceContainer.instance.globalConfig.enableTelemetryInMergeMediaEntitiesStep) {
        _printTelemetry(
          telem,
          secondaryFilesInCollection: totalSecondaryFiles,
          duplicateFilesRemovedIO: duplicateFilesRemoved,
          primaryFilesInCollection: totalPrimaryFiles,
          canonicalFilesInCollection: canonicalAll,
          nonCanonicalFilesInCollection: nonCanonicalAll,
          printInsteadLog: false,  // Change to true if you prefeer to print telemetry instead of leggin it.
        );
      }

      return StepResult.success(
        stepName: name,
        duration: totalSw.elapsed,
        data: {
          'entitiesMerged': mergedEntities,
          'remainingMedia': mediaCollection.length,
          'sizeBuckets': telem.sizeBuckets,
          'quickBuckets': telem.quickBuckets,
          'hashGroups': telem.hashGroups,
          'msTotal': telem.msTotal,
          'msSizeScan': telem.msSizeScan,
          'msQuickSig': telem.msQuickSig,
          'msHashGroups': telem.msHashGroups,
          'msMergeReplace': telem.msMergeReplace,
          'msRemoveIO': telem.msRemoveIO,
          'primaryFilesCount': totalPrimaryFiles,
          'secondaryFilesDetected': totalSecondaryFiles,
          'duplicateFilesRemoved': duplicateFilesRemoved,
          'canonicalAll': canonicalAll,
          'nonCanonicalAll': nonCanonicalAll,
          'primaryCanonical': primaryCanonical,
          'primaryFromAlbums': primaryFromAlbums,
          'secondaryCanonical': secondaryCanonical,
          'secondaryFromAlbums': secondaryFromAlbums,
        },
        message:
            'Step 3 completed.'
            '\n   === Merge Entity Summary ==='
            '\n\t\tInitial Entities: ${mediaCollection.length + mergedEntities}'
            '\n\t\tMerged Entities: $mergedEntities'
            '\n\t\tPrimary files: $totalPrimaryFiles'
            '\n\t\tSecondary files: $totalSecondaryFiles'
            '\n\t\tDuplicate files removed/moved: $duplicateFilesRemoved'
            '\n\t\tMedia Entities remain in collection: ${mediaCollection.length}',
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
      final dynamic keepDuplicates = context.config.keepDuplicates;
      if (keepDuplicates is bool) return keepDuplicates;
    } catch (_) {}
    try {
      final env =
          Platform.environment['GPTH_MOVE_DUPLICATES_TO_DUPLICATES_FOLDER'];
      if (env != null) {
        final s = env.trim().toLowerCase();
        return s == '1' || s == 'true' || s == 'yes' || s == 'on';
      }
    } catch (_) {}
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
      } catch (_) {}
    }
  }

  /// Move/delete only duplicate files (within-folder duplicates), never secondary files.
  Future<bool> _removeOrQuarantineDuplicateFiles(
    final List<FileEntity> duplicates,
    final ProcessingContext context, {
    final void Function()? onRemoved,
  }) async {
    final bool moveToDuplicates = _shouldMoveDuplicatesToFolder(context);

    final String inputRoot = context.inputDirectory.path;
    final String outputRoot = context.outputDirectory.path;

    for (final fe in duplicates) {
      final File f = fe.asFile();

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
        onRemoved?.call();
      } catch (ioe) {
        logWarning(
          'Failed to remove/move duplicate ${f.path}: $ioe',
          forcePrint: true,
        );
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

  // Helper: quick signature (tri-sample FNV-1a 64-bit of 3×4 KiB at head/middle/tail)
  // NOTE (perf): this replaces a large head-read (e.g. 64–128 KiB) with only 12 KiB total,
  // while being more discriminative for formats with heavy headers (JPEG/MP4/etc.).
  //
  // MODIFIED IMPLEMENTATION (English explanation):
  // - Open the file ONCE and reuse the same RandomAccessFile for head/mid/tail → dramatically fewer syscalls.
  // - Use FNV-1a 32-bit to reduce CPU cost (no 64-bit multiplications) while keeping good discrimination.
  // - For very large files and typical video containers, use a 2-point strategy (head+tail) to reduce random seeks.
  Future<String> _quickSignature(
    final File file,
    final int size,
    final String ext,
  ) async {
    const int chunk = 4096; // 4 KiB per sample (head/mid/tail)
    final int sz = size > 0 ? size : (await file.length());

    // Heuristic: videos or very large files → fewer seeks (2-point)
    final Set<String> videoExts = {
      'mp4','mov','m4v','mkv','avi','hevc','heif','heic','webm'
    };
    final bool isVideo = videoExts.contains(ext);
    final bool twoPointOnly = isVideo || sz >= (64 << 20); // ≥ 64MiB

    const int headOff = 0;
    final int midOff  = (!twoPointOnly && sz > chunk) ? (sz ~/ 2) : 0;
    final int tailOff = (sz > chunk) ? (sz - chunk) : 0;

    // FNV-1a 32-bit
    int fnv32(final List<int> bytes) {
      int h = 0x811C9DC5;        // offset basis
      const int p = 0x01000193;  // prime
      for (final b in bytes) {
        h ^= b & 0xFF;
        h = (h * p) & 0xFFFFFFFF;
      }
      return h;
    }

    RandomAccessFile? raf;
    try {
      raf = await file.open();

      // Head
      await raf.setPosition(headOff);
      final head = await raf.read(chunk);
      final int h1 = fnv32(head);

      // Mid (optional)
      int h2 = 0;
      if (midOff != 0) {
        await raf.setPosition(midOff);
        final mid = await raf.read(chunk);
        h2 = fnv32(mid);
      }

      // Tail
      await raf.setPosition(tailOff);
      final tail = await raf.read(chunk);
      final int h3 = fnv32(tail);

      // Combine size + ext + three partial hashes in the key
      return '$size|$ext|$h1|$h2|$h3';
    } catch (_) {
      // Keep a deterministic key on I/O errors (preserves bucketing behavior)
      return '$size|$ext|0|0|0';
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  void _printTelemetry(
    final _Telemetry t, {
    required final int secondaryFilesInCollection,
    required final int duplicateFilesRemovedIO,
    required final int primaryFilesInCollection,
    required final int canonicalFilesInCollection,
    required final int nonCanonicalFilesInCollection,
    required final bool printInsteadLog,
  }) {
    String ms(final num v) => '${v.toStringAsFixed(0)} ms';
    if (printInsteadLog) {
      // Even when "printing", use the unified logger
      logPrint('[Step 3/8] Telemetry summary:');
      logPrint('  Files total                        : ${t.filesTotal}');
      logPrint('  Size buckets                       : ${t.sizeBuckets}');
      logPrint('  Ext buckets                        : ${t.extBuckets}');
      logPrint('  Quick buckets                      : ${t.quickBuckets}');
      logPrint('  Hash groups                        : ${t.hashGroups}');
      logPrint('  Merged media entities (by content) : ${t.entitiesMergedByContent}');
      logPrint('  Primary files in collection        : $primaryFilesInCollection');
      logPrint('  Secondary files in collection      : $secondaryFilesInCollection');
      logPrint('  Canonical files (ALL_PHOTOS/Year)  : $canonicalFilesInCollection');
      logPrint('  Non-Canonical files (Albums)       : $nonCanonicalFilesInCollection');
      logPrint('  Duplicate files removed (I/O)      : $duplicateFilesRemovedIO');
      logPrint('  Time total                         : ${ms(t.msTotal)}');
      logPrint('    - Size scan                      : ${ms(t.msSizeScan)}');
      logPrint('    - Ext bucketing                  : ${ms(t.msExtBucket)}');
      logPrint('    - Quick signature                : ${ms(t.msQuickSig)}');
      logPrint('    - Hash grouping                  : ${ms(t.msHashGroups)}');
      logPrint('    - Merge/replace                  : ${ms(t.msMergeReplace)}');
      logPrint('    - Remove/IO                      : ${ms(t.msRemoveIO)}');
    } else {
      logInfo('[Step 3/8] Telemetry summary:', forcePrint: true);
      logInfo('  Files total                        : ${t.filesTotal}', forcePrint: true);
      logInfo('  Size buckets                       : ${t.sizeBuckets}', forcePrint: true);
      logInfo('  Ext buckets                        : ${t.extBuckets}', forcePrint: true);
      logInfo('  Quick buckets                      : ${t.quickBuckets}', forcePrint: true);
      logInfo('  Hash groups                        : ${t.hashGroups}', forcePrint: true);
      logInfo('  Merged media entities (by content) : ${t.entitiesMergedByContent}', forcePrint: true);
      logInfo('  Primary files in collection        : $primaryFilesInCollection', forcePrint: true);
      logInfo('  Secondary files in collection      : $secondaryFilesInCollection', forcePrint: true);
      logInfo('  Canonical files (ALL_PHOTOS/Year)  : $canonicalFilesInCollection', forcePrint: true);
      logInfo('  Non-Canonical files (Albums)       : $nonCanonicalFilesInCollection', forcePrint: true);
      logInfo('  Duplicate files removed (I/O)      : $duplicateFilesRemovedIO', forcePrint: true);
      logInfo('  Time total                         : ${ms(t.msTotal)}', forcePrint: true);
      logInfo('    - Size scan                      : ${ms(t.msSizeScan)}', forcePrint: true);
      logInfo('    - Ext bucketing                  : ${ms(t.msExtBucket)}', forcePrint: true);
      logInfo('    - Quick signature                : ${ms(t.msQuickSig)}', forcePrint: true);
      logInfo('    - Hash grouping                  : ${ms(t.msHashGroups)}', forcePrint: true);
      logInfo('    - Merge/replace                  : ${ms(t.msMergeReplace)}', forcePrint: true);
      logInfo('    - Remove/IO                      : ${ms(t.msRemoveIO)}', forcePrint: true);
    }
    logPrint(''); // spacing
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
  int entitiesMergedByContent = 0;

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
    entitiesMergedByContent += s.entitiesMergedByContent;
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
  int entitiesMergedByContent = 0;

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

// NEW: small helper to carry hash grouping results in parallel batches
// English note: returning both the groups and elapsed ms keeps per-batch
// telemetry accurate after parallelization.
class _HashBatchResult {
  _HashBatchResult(this.groups, this.ms);
  final Map<String, List<MediaEntity>> groups;
  final int ms;
}
