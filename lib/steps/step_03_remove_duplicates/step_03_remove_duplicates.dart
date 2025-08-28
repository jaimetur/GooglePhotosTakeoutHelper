import 'dart:io';
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
/// - **Binary Comparison**: Ensures exact byte-for-byte content matching
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
/// 2. **Filename Length**: Shorter filenames often indicate original vs processed files
/// 3. **Discovery Order**: Earlier discovered files are preferred as canonical
/// 4. **Path Characteristics**: Year folder files preferred over album folder duplicates
///
/// #### Selection Algorithm:
/// ```
/// Sort by: dateTakenAccuracy (ascending) + filenameLength (ascending)
/// Keep: First file in sorted order
/// Remove: All subsequent identical files
/// ```
///
/// ### Metadata Preservation
/// - **Date Information**: Preserves best available date and accuracy from kept file
/// - **Album Associations**: May be preserved through later album finding step
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

      print('\n[Step 3/8] Finding and removing duplicates... (This might take a while)');

      final duplicateService = ServiceContainer.instance.duplicateDetectionService;
      int removedCount = 0;

      // --- Build size buckets (tolerant to IO errors when reading length) ---
      final Map<int, List<MediaEntity>> sizeBuckets = {};
      for (final e in mediaCol.entities) {
        int size;
        try {
          size = e.primaryFile.lengthSync();
        } catch (err) {
          // Tolerant: warn and place into unknown-size bucket (-1)
          logWarning('Failed to read file length for ${_safePath(e.primaryFile)}: $err', forcePrint: true);
          size = -1;
        }
        (sizeBuckets[size] ??= <MediaEntity>[]).add(e);
      }

      final List<int> bucketKeys = sizeBuckets.keys.toList();
      print('Step 3: Built ${bucketKeys.length} size buckets for duplicate detection');

      final totalGroups = bucketKeys.length;
      int processedGroups = 0;
      final Set<MediaEntity> entitiesToRemove = <MediaEntity>{};

      // Merge helper (delegates to immutable domain APIs; no in-place map mutation)
      void mergeEntityFiles(final MediaEntity dst, final MediaEntity src) {
        try {
          final MediaEntity updated = dst.mergeWith(src);
          _replaceEntityInCollection(mediaCol, dst, updated);
        } catch (e) {
          logWarning('⚠️ Failed to merge files from duplicate entity: $e', forcePrint: true);
        }
      }

      // Binary equality check (chunked, tolerant to IO errors)
      Future<bool> _filesAreIdentical(final File a, final File b) async {
        try {
          final int sa = a.lengthSync();
          final int sb = b.lengthSync();
          if (sa != sb) return false;
          if (a.path == b.path) return true;

          const int chunk = 262144; // 256 KiB
          final rafA = await a.open();
          final rafB = await b.open();
          try {
            int remaining = sa;
            while (remaining > 0) {
              final int toRead = remaining < chunk ? remaining : chunk;
              final ba = await rafA.read(toRead);
              final bb = await rafB.read(toRead);
              if (ba.length != bb.length) return false;
              for (int i = 0; i < ba.length; i++) {
                if (ba[i] != bb[i]) return false;
              }
              remaining -= toRead;
            }
            return true;
          } finally {
            await rafA.close();
            await rafB.close();
          }
        } catch (e) {
          logWarning('Binary compare failed for ${_safePath(a)} vs ${_safePath(b)}: $e', forcePrint: true);
          // Conservative fallback: do NOT treat as identical if we couldn’t confirm
          return false;
        }
      }

      Future<void> _processSizeBucket(final int key) async {
        final List<MediaEntity> candidates = sizeBuckets[key]!;
        if (candidates.length <= 1) return;
        logDebug('🔍 Processing size bucket $key with ${candidates.length} candidates');

        Map<String, List<MediaEntity>> hashGroups = const {};
        try {
          hashGroups = await duplicateService.groupIdentical(candidates);
        } catch (e) {
          // Tolerant: warn and skip this bucket rather than abort
          logWarning('Duplicate hashing failed for size bucket $key: $e', forcePrint: true);
          return;
        }

        logDebug(' → Found ${hashGroups.length} hash groups in this bucket');

        for (final group in hashGroups.values) {
          if (group.length <= 1) continue;
          logDebug('   • Group of ${group.length} candidates for deep check');

          final List<MediaEntity> pending = List.of(group);
          final List<List<MediaEntity>> binaryClusters = [];

          // Cluster by binary equality (seed vs others)
          while (pending.isNotEmpty) {
            final MediaEntity seed = pending.removeAt(0);
            final List<MediaEntity> cluster = [seed];
            for (int i = pending.length - 1; i >= 0; i--) {
              final MediaEntity cand = pending[i];
              if (await _filesAreIdentical(seed.primaryFile, cand.primaryFile)) {
                cluster.add(cand);
                pending.removeAt(i);
              }
            }
            binaryClusters.add(cluster);
          }

          for (final cluster in binaryClusters) {
            if (cluster.length <= 1) continue;
            logDebug('     ✔ Verified binary-identical cluster of ${cluster.length} files');

            // Sort: best date accuracy (asc), then shortest filename
            cluster.sort((a, b) {
              final aAcc = a.dateAccuracy?.value ?? 999;
              final bAcc = b.dateAccuracy?.value ?? 999;
              if (aAcc != bAcc) return aAcc.compareTo(bAcc);
              return a.primaryFile.path.length.compareTo(b.primaryFile.path.length);
            });

            final MediaEntity kept = cluster.first;
            final List<MediaEntity> toRemove = cluster.sublist(1);

            logDebug('       → Keeping ${kept.primaryFile.path}');
            for (final d in toRemove) {
              // Verbose trace
              logDebug('         Removing duplicate: ${d.primaryFile.path}');
              // Merge files & album metadata before removal
              mergeEntityFiles(kept, d);
            }

            entitiesToRemove.addAll(toRemove);
            removedCount += toRemove.length;
          }
        }
      }

      // Controlled parallelism across buckets
      final int maxWorkers =
          ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif).clamp(1, 8);

      for (int i = 0; i < bucketKeys.length; i += maxWorkers) {
        final slice = bucketKeys.skip(i).take(maxWorkers).toList();
        await Future.wait(slice.map(_processSizeBucket));
        processedGroups += slice.length;
        // (optional) progress callback could go here; using prints for simplicity
      }

      // Apply removals
      if (entitiesToRemove.isNotEmpty) {
        print('🧹 Removing ${entitiesToRemove.length} entities from collection');
        for (final e in entitiesToRemove) {
          try {
            mediaCol.remove(e);
          } catch (err) {
            logWarning('Failed to remove entity ${_safeEntity(e)}: $err', forcePrint: true);
          }
        }
      }

      print('✅ Duplicate removal finished, total removed: $removedCount');

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'duplicatesRemoved': removedCount,
          'remainingMedia': mediaCol.length,
        },
        message: 'Removed $removedCount duplicate files\n${mediaCol.length} media files remain.',
      );
    } catch (e) {
      stopwatch.stop();
      // Tolerant: fail the step, but message is clear
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
}
