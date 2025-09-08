import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

/// Step 7: Write EXIF data to output files (physical files only)
///
/// Single rule (no per-strategy branching here):
///   • Process every FileEntity whose `targetPath` is not null AND `isShortcut == false`.
///   • GPS sidecar JSON is resolved using the *primary* entity's `sourcePath`.
///   • The entity's `dateTaken`/`dateAccuracy` are the authoritative timestamp/quality.
///
/// Why this shape:
///   • Step 6 (Move Files) already performed all physical moves/copies/shortcuts and
///     annotated each FileEntity with `targetPath` and `isShortcut`.
///   • We trust those flags to decide what to embed. Shortcuts are never written.
///   • This keeps Step 7 independent from album strategies.
///
/// This step embeds GPS coordinates and datetime information directly into media file
/// EXIF metadata, ensuring that location and timing data is preserved permanently with
/// each photo and video, independent of external metadata files.
///
/// ## Purpose and Benefits
///
/// ### Metadata Preservation
/// - **Permanent Embedding**: GPS and datetime become part of the file itself
/// - **Software Compatibility**: Works with all photo viewers and editing applications
/// - **Future-Proofing**: Data remains accessible even if JSON files are lost
/// - **Standard Compliance**: Uses standard EXIF tags recognized by all photo software
///
/// ### Data Sources
/// - **GPS Coordinates**: Extracted from Google Photos JSON metadata files
/// - **DateTime Information**: Uses accurately extracted photo creation timestamps
/// - **Timezone Handling**: Properly handles timezone conversion and UTC timestamps
/// - **Precision Preservation**: Maintains full coordinate and timestamp precision
///
/// ## EXIF Writing Process
///
/// ### GPS Coordinate Processing
/// 1. **JSON Extraction**: Reads GPS data from associated `.json` metadata files
/// 2. **Coordinate Conversion**: Converts decimal degrees to EXIF DMS (Degrees/Minutes/Seconds) format
/// 3. **Reference Assignment**: Sets proper hemisphere references (N/S, E/W)
/// 4. **Precision Handling**: Maintains coordinate accuracy to GPS precision limits
/// 5. **Validation**: Verifies coordinates are within valid Earth coordinate ranges
///
/// ### DateTime Embedding
/// 1. **Source Selection**: Uses the most accurate datetime from extraction step
/// 2. **Format Conversion**: Converts to EXIF datetime format (YYYY:MM:DD HH:MM:SS)
/// 3. **Tag Assignment**: Writes to appropriate EXIF datetime tags
/// 4. **Timezone Preservation**: Includes timezone information when available
/// 5. **Consistency Check**: Ensures all datetime tags are synchronized
///
/// ### EXIF Tag Management
/// - **Standard Tags**: Uses industry-standard EXIF tag numbers and formats
/// - **Multiple Tags**: Writes to primary and subsecond datetime tags
/// - **GPS Tags**: Populates comprehensive GPS tag set (latitude, longitude, altitude, etc.)
/// - **Metadata Preservation**: Maintains existing EXIF data while adding new information
///
/// ## Configuration and Control
///
/// ### Processing Options
/// - **Enable/Disable**: Controlled by `writeExif` configuration setting
/// - **Selective Processing**: Only processes files that lack existing EXIF datetime
/// - **Overwrite Protection**: Avoids overwriting existing accurate EXIF data
/// - **Source Filtering**: Only writes data extracted from reliable sources
///
/// ### Quality Control
/// - **Data Validation**: Verifies GPS coordinates and datetime values before writing
/// - **Format Verification**: Ensures data meets EXIF standard requirements
/// - **Error Detection**: Identifies and reports files that cannot be processed
/// - **Integrity Checking**: Confirms EXIF data was written correctly
///
/// ## Technical Implementation
///
/// ### File Format Support
/// - **JPEG Files**: Full EXIF support with standard embedding
/// - **TIFF Files**: Native EXIF support with comprehensive tag coverage
/// - **RAW Formats**: Uses ExifTool for advanced RAW file EXIF writing
/// - **Video Files**: Limited metadata support where format allows
///
/// ### ExifTool Integration
/// - **External Tool**: Uses ExifTool for comprehensive format support
/// - **Fallback Support**: Uses built-in EXIF writing when ExifTool unavailable
/// - **Format Coverage**: Supports hundreds of image and video formats
/// - **Advanced Features**: Handles complex metadata scenarios and edge cases
///
/// ### Performance Optimization
/// - **Batch Processing**: Groups multiple files for efficient processing
/// - **Memory Management**: Processes files without loading full content
/// - **I/O Minimization**: Optimizes file read/write operations
///
/// - **Progress Tracking**: Provides user feedback for long-running operations
///
/// ## Error Handling and Recovery
///
/// ### File Access Issues
/// - **Permission Errors**: Gracefully handles read-only or protected files
/// - **File Locks**: Manages files locked by other applications
/// - **Corrupted Files**: Skips files with corrupted EXIF segments
/// - **Format Limitations**: Handles unsupported file formats appropriately
///
/// ### Data Integrity Protection
/// - **Backup Creation**: Optionally creates backups before modifying files
/// - **Rollback Capability**: Can restore original files if issues occur
/// - **Verification**: Confirms EXIF data was written correctly
/// - **Partial Failure Handling**: Continues processing when individual files fail
///
/// ### External Tool Dependencies
/// - **ExifTool Detection**: Automatically detects ExifTool availability
/// - **Fallback Mechanisms**: Uses alternative methods when ExifTool unavailable
/// - **Version Compatibility**: Works with different ExifTool versions
/// - **Error Recovery**: Handles ExifTool execution errors gracefully
///
/// ## Data Quality and Validation
///
/// ### GPS Coordinate Validation
/// - **Range Checking**: Ensures coordinates are within valid Earth bounds
/// - **Precision Limits**: Respects GPS precision limitations
/// - **Format Verification**: Validates coordinate format before writing
/// - **Reference Consistency**: Ensures hemisphere references match coordinate signs
///
/// ### DateTime Validation
/// - **Reasonable Dates**: Rejects obviously incorrect dates (future/prehistoric)
/// - **Format Compliance**: Ensures datetime meets EXIF standard requirements
/// - **Timezone Handling**: Properly manages timezone information
/// - **Accuracy Tracking**: Preserves information about date extraction accuracy
///
/// ## Integration and Dependencies
///
/// ### Prerequisites
/// - **Date Extraction**: Requires completed date extraction from Step 4
/// - **JSON Processing**: Needs JSON metadata files for GPS coordinate extraction
/// - **File Accessibility**: Files must be writable for EXIF modification
/// - **Tool Availability**: ExifTool recommended for best format support
///
/// ### Step Coordination
/// - **After Date Extraction**: Runs after accurate datetime determination
/// - **Before File Moving**: Embeds metadata before final file organization
/// - **Coordinate with Album Finding**: May benefit from consolidated file information
/// - **Performance Consideration**: Balances thoroughness with processing speed
///
/// ## User Benefits and Use Cases
///
/// ### Photo Management
/// - **Geotagging**: Enables location-based photo organization and mapping
/// - **Timeline Accuracy**: Ensures correct chronological sorting in all applications
/// - **Software Compatibility**: Works with Adobe Lightroom, Apple Photos, Google Photos web
/// - **Archive Longevity**: Creates self-contained files with embedded metadata
///
/// ### Professional Workflows
/// - **Client Delivery**: Photos delivered with proper embedded metadata
/// - **Stock Photography**: Images have complete location and timing information
/// - **Legal Documentation**: Embedded metadata provides verifiable timestamps
/// - **Scientific Research**: Preserves precise location and timing data
///
/// ## Statistics and Reporting
///
/// ### Processing Metrics
/// - **GPS Coordinates Written**: Count of files with GPS data successfully embedded
/// - **DateTime Updates**: Number of files with datetime information added
/// - **Processing Performance**: Files processed per second and total duration
/// - **Error Tracking**: Files that couldn't be processed and reasons why
///
/// ### Quality Metrics
/// - **Data Source Breakdown**: Statistics on GPS/datetime data sources
/// - **Format Coverage**: Which file formats were successfully processed
/// - **Tool Usage**: Whether ExifTool or built-in methods were used
/// - **Validation Results**: How many files passed data validation checks

class WriteExifStep extends ProcessingStep with LoggerMixin {
  const WriteExifStep() : super('Write EXIF Data');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final sw = Stopwatch()..start();

    try {
      final collection = context.mediaCollection;

      logPrint('[Step 7/8] Writing EXIF data on physical files in output (this may take a while)...');
      if (!context.config.writeExif) {
        sw.stop();
        return StepResult.success(
          stepName: name,
          duration: sw.elapsed,
          data: {
            'coordinatesWritten': 0,
            'dateTimesWritten': 0,
            'skipped': true,
          },
          message: 'EXIF writing skipped per configuration',
        );
      }

      // Tooling
      final exifTool = ServiceContainer.instance.exifTool; // may be null
      final bool nativeOnly = exifTool == null;
      if (nativeOnly) {
        logWarning('[Step 7/8] ExifTool not available, native-only support.', forcePrint: true);
      } else {
        logPrint('[Step 7/8] ExifTool enabled');
      }

      // Get and print maxConcurrency
      final int maxConcurrency = ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif);
      logPrint('[Step 7/8] Starting $maxConcurrency threads (exif concurrency)');

      // Batching config
      final bool enableExifToolBatch = _resolveBatchingPreference(exifTool);
      final progressBar = FillingBar(
        desc: '[ INFO  ] [Step 7/8] Writing EXIF data',
        total: collection.length,
        width: 50,
      );
      final _UnsupportedPolicy unsupportedPolicy = _resolveUnsupportedPolicy();

      final ExifWriterService? exifWriter = (exifTool != null) ? ExifWriterService(exifTool) : null;

      // Batch queues (images/videos)
      final bool isWindows = Platform.isWindows;
      final int baseBatchSize = isWindows ? 100 : 200;
      final int maxImageBatch = _resolveInt('maxExifImageBatchSize', defaultValue: 500);
      final int maxVideoBatch = _resolveInt('maxExifVideoBatchSize', defaultValue: 24);

      // NEW: group batches by an identical tag-set to avoid cross-file tag bleeding.
      final Map<String, List<MapEntry<File, Map<String, dynamic>>>> pendingImagesByTagset = {};
      final Map<String, List<MapEntry<File, Map<String, dynamic>>>> pendingVideosByTagset = {};

      String stableTagsetKey(final Map<String, dynamic> tags) {
        // Deterministic signature: sorted keys + '=' + stringified value
        final keys = tags.keys.toList()..sort();
        final buf = StringBuffer();
        for (final k in keys) {
          buf.write(k);
          buf.write('=');
          final v = tags[k];
          buf.write(v is String ? v : v.toString());
          buf.write('\u0001'); // non-printable separator
        }
        return buf.toString();
      }

      int totalQueued(final Map<String, List<MapEntry<File, Map<String, dynamic>>>> byTagset) {
        int n = 0;
        for (final list in byTagset.values) {
          n += list.length;
        }
        return n;
      }

      // --- Helpers to preserve OS mtime around writes (tool-agnostic) ---
      Future<T> preserveMTime<T>(final File f, final Future<T> Function() op) async {
        DateTime? before;
        try {
          before = await f.lastModified();
        } catch (_) {}
        T out;
        try {
          out = await op();
        } finally {
          if (before != null) {
            try {
              await f.setLastModified(before);
            } catch (_) {}
          }
        }
        return out;
      }

      Map<File, DateTime> snapshotMtimes(final List<MapEntry<File, Map<String, dynamic>>> chunk) {
        final m = <File, DateTime>{};
        for (final e in chunk) {
          try {
            m[e.key] = e.key.lastModifiedSync();
          } catch (_) {}
        }
        return m;
      }

      Future<void> restoreMtimes(final Map<File, DateTime> snap) async {
        for (final kv in snap.entries) {
          try {
            await kv.key.setLastModified(kv.value);
          } catch (_) {}
        }
      }

      // SECOND-BAR: counters and bar holder for the final flush (created later)
      FillingBar? finalFlushBar;
      int finalFlushTotal = 0;
      int finalFlushDone = 0;

      // NEW (B): track JPEGs that must be written via XMP (broken EXIF, e.g. Truncated InteropIFD)
      // Values are lowercased absolute paths.
      final Set<String> _forceJpegXmp = <String>{};

      // Safe batched write (splits on failure to isolate bad files)
      Future<void> writeBatchSafe(
        final List<MapEntry<File, Map<String, dynamic>>> queue, {
        required final bool useArgFile,
        required final bool isVideoBatch,
      }) async {
        if (queue.isEmpty || exifWriter == null) return;

        Future<void> splitAndWrite(final List<MapEntry<File, Map<String, dynamic>>> chunk) async {
          if (chunk.isEmpty) return;
          if (chunk.length == 1) {
            final entry = chunk.first;
            final snap = snapshotMtimes(chunk); // snapshot for single too
            try {
              // CHANGE: when the batch has a single file, call the single method so fallback
              // metrics (Recovered/Fail) are accounted correctly in ExifWriterService.
              await preserveMTime(entry.key, () async {
                // NOTE: ExifWriterService should internally add `-P` (preserve file times).
                await exifWriter.writeTagsWithExifTool(entry.key, entry.value);
              });
            } catch (e) {
              if (!_shouldSilenceExiftoolError(e)) {
                logWarning(
                  isVideoBatch
                      ? '[Step 7/8] Per-file video write failed: ${entry.key.path} -> $e'
                      : '[Step 7/8] Per-file write failed: ${entry.key.path} -> $e',
                );
              }
              await _tryDeleteTmp(entry.key);
            } finally {
              await restoreMtimes(snap); // preserve file mtime regardless of ExifTool behavior
            }
            // SECOND-BAR: advance when a chunk finishes (here chunk = 1)
            if (finalFlushBar != null) {
              finalFlushDone += 1;
              finalFlushBar.update(finalFlushDone);
            }
            return;
          }

          final mid = chunk.length >> 1;
          final left = chunk.sublist(0, mid);
          final right = chunk.sublist(mid);

          // Snapshot before writing the batch (because ExifTool may replace files)
          final snap = snapshotMtimes(chunk);

          try {
            await exifWriter.writeTagsWithExifToolUsingBatch(chunk, useArgFileWhenLarge: useArgFile);
          } catch (e) {
            await _tryDeleteTmpForChunk(chunk);

            // ─────────────────────────────────────────────────────────────────
            // NEW (C): smarter split — parse stderr, lift out only the bad files,
            // retry the rest as a single batch, and process the bad ones separately.
            // If we can't identify them, fall back to recursive halving.
            // ─────────────────────────────────────────────────────────────────
            final String errStr = e.toString();
            final Set<String> badPaths = _extractBadPathsFromExifError(errStr);
            final bool truncated = errStr.contains('Truncated InteropIFD');

            if (badPaths.isNotEmpty) {
              // Separate good vs bad using parsed paths
              final List<MapEntry<File, Map<String, dynamic>>> bad = <MapEntry<File, Map<String, dynamic>>>[];
              final List<MapEntry<File, Map<String, dynamic>>> good = <MapEntry<File, Map<String, Map<String, dynamic>>>>[].cast<MapEntry<File, Map<String, dynamic>>>();
              for (final entry in chunk) {
                final lower = entry.key.path.toLowerCase();
                if (badPaths.contains(lower)) {
                  bad.add(entry);
                } else {
                  good.add(entry);
                }
              }

              // Mark JPEG bad files to be written via XMP if the error is the truncated IFD one (B)
              if (truncated) {
                for (final b in bad) {
                  final lower = b.key.path.toLowerCase();
                  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                    _forceJpegXmp.add(lower);
                    _retagEntryToXmpIfJpeg(b); // convert tags in-place to XMP for this retry path
                  }
                }
              }

              // Restore mtimes for the failed chunk before the re-attempts (best-effort)
              await restoreMtimes(snap);

              // Retry the good ones together (single batch)
              if (good.isNotEmpty) {
                await writeBatchSafe(good, useArgFile: useArgFile, isVideoBatch: isVideoBatch);
              }

              // Bad ones: process individually (per-file) so they can't block
              for (final entry in bad) {
                final singleSnap = snapshotMtimes([entry]);
                try {
                  await preserveMTime(entry.key, () async {
                    await exifWriter.writeTagsWithExifTool(entry.key, entry.value);
                  });
                } catch (e2) {
                  if (!_shouldSilenceExiftoolError(e2)) {
                    logWarning(
                      isVideoBatch
                          ? '[Step 7/8] Per-file video write failed: ${entry.key.path} -> $e2'
                          : '[Step 7/8] Per-file write failed: ${entry.key.path} -> $e2',
                    );
                  }
                  await _tryDeleteTmp(entry.key);
                } finally {
                  await restoreMtimes(singleSnap);
                }
                // SECOND-BAR: advance one tick per bad file handled individually
                if (finalFlushBar != null) {
                  finalFlushDone += 1;
                  finalFlushBar.update(finalFlushDone);
                }
              }

              // We've handled both good and bad; stop here.
              return;
            }

            // If we couldn't identify the bad paths, use the previous recursive split.
            if (!_shouldSilenceExiftoolError(e)) {
              logWarning(
                isVideoBatch
                    ? '[Step 7/8] Video batch flush failed (${chunk.length} files) - splitting: $e'
                    : '[Step 7/8] Batch flush failed (${chunk.length} files) - splitting: $e',
              );
            }
            // Restore mtimes for the failed chunk before splitting (best-effort)
            await restoreMtimes(snap);
            await splitAndWrite(left);
            await splitAndWrite(right);
            return;
          }

          // On success, restore mtimes for the whole chunk
          await restoreMtimes(snap);

          // SECOND-BAR: advance by the whole chunk when it succeeds
          if (finalFlushBar != null) {
            finalFlushDone += chunk.length;
            finalFlushBar.update(finalFlushDone);
          }
        }

        await splitAndWrite(queue);
      }

      // Flush helpers (iterate by homogeneous tag-set)
      Future<void> flushMapByTagset(
        final Map<String, List<MapEntry<File, Map<String, dynamic>>>> byTagset, {
        required final bool useArgFile,
        required final bool isVideoBatch,
        required final int capPerChunk,
      }) async {
        if (nativeOnly || !enableExifToolBatch) return;
        if (byTagset.isEmpty) return;
        if (exifWriter == null) {
          byTagset.clear();
          return;
        }

        final keys = byTagset.keys.toList();
        for (final k in keys) {
          final list = byTagset[k];
          if (list == null || list.isEmpty) {
            byTagset.remove(k);
            continue;
          }

          while (list.length > capPerChunk) {
            final sub = list.sublist(0, capPerChunk);
            await writeBatchSafe(sub, useArgFile: true, isVideoBatch: isVideoBatch);
            list.removeRange(0, sub.length);
          }

          await writeBatchSafe(list, useArgFile: useArgFile, isVideoBatch: isVideoBatch);
          byTagset.remove(k);
        }
      }

      Future<void> flushImageBatch({required final bool useArgFile}) =>
          flushMapByTagset(pendingImagesByTagset, useArgFile: useArgFile, isVideoBatch: false, capPerChunk: maxImageBatch);
      Future<void> flushVideoBatch({required final bool useArgFile}) =>
          flushMapByTagset(pendingVideosByTagset, useArgFile: useArgFile, isVideoBatch: true, capPerChunk: maxVideoBatch);

      Future<void> maybeFlushThresholds() async {
        if (nativeOnly || !enableExifToolBatch) return;
        final int targetImageBatch = baseBatchSize.clamp(1, maxImageBatch).toInt();
        final int targetVideoBatch = 12.clamp(1, maxVideoBatch).toInt();

        for (final entry in pendingImagesByTagset.entries.toList()) {
          if (entry.value.length >= targetImageBatch) {
            await writeBatchSafe(entry.value, useArgFile: true, isVideoBatch: false);
            pendingImagesByTagset.remove(entry.key);
          }
        }
        for (final entry in pendingVideosByTagset.entries.toList()) {
          if (entry.value.length >= targetVideoBatch) {
            await writeBatchSafe(entry.value, useArgFile: true, isVideoBatch: true);
            pendingVideosByTagset.remove(entry.key);
          }
        }
      }

      // Per-file EXIF/XMP write (file already in output). Uses entity's dateTaken and
      // GPS coords previously extracted from the primary sidecar JSON.
      Future<Map<String, bool>> writeForFile({
        required final File file,
        required final bool markAsPrimary,
        required final DateTime? effectiveDate,
        required final coordsFromPrimary,
      }) async {
        bool gpsWrittenThis = false;
        bool dtWrittenThis = false;

        try {
          final lower = file.path.toLowerCase();

          // MIME guess — extension first, header as fallback (cheap and robust)
          String? mimeHeader;
          String? mimeExt;
          if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
            mimeHeader = 'image/jpeg';
            mimeExt = 'image/jpeg';
          } else if (lower.endsWith('.heic')) {
            mimeHeader = 'image/heic';
            mimeExt = 'image/heic';
          } else if (lower.endsWith('.png')) {
            mimeHeader = 'image/png';
            mimeExt = 'image/png';
          } else if (lower.endsWith('.mp4')) {
            mimeHeader = 'video/mp4';
            mimeExt = 'video/mp4';
          } else if (lower.endsWith('.mov')) {
            mimeHeader = 'video/quicktime';
            mimeExt = 'video/quicktime';
          } else {
            try {
              final header = await file.openRead(0, 128).first;
              mimeHeader = lookupMimeType(file.path, headerBytes: header);
              mimeExt = lookupMimeType(file.path);
            } catch (_) {
              mimeHeader = lookupMimeType(file.path);
              mimeExt = mimeHeader;
            }
          }

          final tagsToWrite = <String, dynamic>{};

          // Decide writing namespace for non-JPEG images:
          //  - JPEG: EXIF native (and/or ExifTool fallback tags without XMP).
          //  - PNG: write XMP tags to avoid EXIF/IFD pointer issues.
          final bool isPng = mimeHeader == 'image/png' || lower.endsWith('.png');

          // NEW (B): Treat as “broken JPEG” (write XMP instead of EXIF/native)
          final bool isJpeg = lower.endsWith('.jpg') || lower.endsWith('.jpeg');
          final bool forceXmpJpeg = isJpeg && _forceJpegXmp.contains(lower);

          // GPS (if primary coords available)
          try {
            final coords = coordsFromPrimary;
            if (coords != null) {
              if (isJpeg && !forceXmpJpeg) {
                if (!nativeOnly && exifWriter != null) {
                  if (effectiveDate != null) {
                    // IMPORTANT: preserve OS mtime around native JPEG combined write
                    final ok = await preserveMTime(file, () async => exifWriter.writeCombinedNativeJpeg(file, effectiveDate, coords));
                    if (ok) {
                      gpsWrittenThis = true;
                      dtWrittenThis = true;
                    } else {
                      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                      final dt = exifFormat.format(effectiveDate);
                      tagsToWrite['DateTimeOriginal'] = '"$dt"';
                      tagsToWrite['DateTimeDigitized'] = '"$dt"';
                      tagsToWrite['DateTime'] = '"$dt"';
                      tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                      tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                      tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                      tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                      ExifWriterService.markFallbackCombinedTried(file);
                    }
                  } else {
                    final ok = await preserveMTime(file, () async => exifWriter.writeGpsNativeJpeg(file, coords));
                    if (ok) {
                      gpsWrittenThis = true;
                    } else {
                      tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                      tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                      tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                      tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                      ExifWriterService.markFallbackGpsTried(file);
                    }
                  }
                } else {
                  // Native-only: enqueue GPS via ExifTool tags map (if ExifTool later available)
                  tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                  tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                  tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                  tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                }
              } else {
                // Non-JPEG or forced-XMP JPEG: rely on ExifTool only.
                // For PNG specifically, write XMP GPS tags to avoid EXIF IFD pointer issues.
                if (!nativeOnly) {
                  if (isPng || forceXmpJpeg) {
                    // XMP does not need Ref letters; coordinates are signed.
                    tagsToWrite['XMP:GPSLatitude'] = coords.toDD().latitude.toString();
                    tagsToWrite['XMP:GPSLongitude'] = coords.toDD().longitude.toString();
                  } else {
                    tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                    tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                    tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                    tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                  }
                }
              }
            }
          } catch (e) {
            logWarning('[Step 7/8] Failed to prepare GPS tags for ${file.path}: $e', forcePrint: true);
          }

          // Date/time from entity
          try {
            if (effectiveDate != null) {
              if (isJpeg && !forceXmpJpeg) {
                if (!dtWrittenThis && !nativeOnly && exifWriter != null) {
                  final ok = await preserveMTime(file, () async => exifWriter.writeDateTimeNativeJpeg(file, effectiveDate));
                  if (ok) {
                    dtWrittenThis = true;
                  } else {
                    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                    final dt = exifFormat.format(effectiveDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    ExifWriterService.markFallbackDateTried(file);
                  }
                }
              } else {
                if (!nativeOnly) {
                  if (isPng || forceXmpJpeg) {
                    // Write XMP datetime for PNG and for forced-XMP JPEG
                    // Use XMP standard: CreateDate and DateTimeOriginal
                    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                    final dt = exifFormat.format(effectiveDate);
                    tagsToWrite['XMP:CreateDate'] = '"$dt"';
                    tagsToWrite['XMP:DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['XMP:ModifyDate'] = '"$dt"';
                  } else {
                    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                    final dt = exifFormat.format(effectiveDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                  }
                }
              }
            }
          } catch (e) {
            logWarning('[Step 7/8] Failed to prepare DateTime tags for ${file.path}: $e', forcePrint: true);
          }

          // Write (per-file or batch)
          try {
            if (!nativeOnly && tagsToWrite.isNotEmpty) {
              final bool isVideo = (mimeHeader ?? '').startsWith('video/');
              final bool isUnsupported = _isDefinitelyUnsupportedForWrite(
                mimeHeader: mimeHeader,
                mimeExt: mimeExt,
                pathLower: lower,
              );

              if (isUnsupported && !unsupportedPolicy.forceProcessUnsupportedFormats) {
                if (!unsupportedPolicy.silenceUnsupportedWarnings) {
                  // Skip unsupported files (if not forced by configuration)
                  final detectedFmt = _describeUnsupported(
                    mimeHeader: mimeHeader,
                    mimeExt: mimeExt,
                    pathLower: lower,
                  );
                  logWarning('[Step 7/8] Skipping $detectedFmt file - ExifTool cannot write $detectedFmt: ${file.path}', forcePrint: true);
                }
              }
              else {
                // Write with ExifTool without Batches
                if (!enableExifToolBatch) {
                  // Respect configuration: no batching → per-file write (preserving mtime)
                  try {
                    await preserveMTime(file, () async {
                      // NOTE: ExifWriterService should internally add `-P` (preserve file times).
                      // Register primary/secondary hint so ExifWriterService can split correctly.
                      ExifWriterService.setPrimaryHint(file, markAsPrimary);
                      await exifWriter!.writeTagsWithExifTool(file, tagsToWrite);
                    });
                  } catch (e) {
                    if (!_shouldSilenceExiftoolError(e)) {
                      logWarning(isVideo ? '[Step 7/8] Per-file video write failed: ${file.path} -> $e' : '[Step 7/8] Per-file write failed: ${file.path} -> $e');
                    }
                    await _tryDeleteTmp(file);
                  }
                }
                // Write with ExifTool in Batches
                else {
                  // Register primary/secondary hint before enqueueing to batch.
                  ExifWriterService.setPrimaryHint(file, markAsPrimary);
                  final key = stableTagsetKey(tagsToWrite);
                  if (isVideo) {
                    (pendingVideosByTagset[key] ??= <MapEntry<File, Map<String, dynamic>>>[]).add(MapEntry(file, tagsToWrite));
                  } else {
                    (pendingImagesByTagset[key] ??= <MapEntry<File, Map<String, dynamic>>>[]).add(MapEntry(file, tagsToWrite));
                  }
                }
              }
            }
          } catch (e) {
            if (!_shouldSilenceExiftoolError(e)) {
              logWarning('[Step 7/8] Failed to enqueue EXIF tags for ${file.path}: $e');
            }
          }

          // Unique-file instrumentation counts (primary vs secondary)
          if (gpsWrittenThis) {
            ExifWriterService.markGpsTouchedFromStep5(file, isPrimary: markAsPrimary);
          }
          if (dtWrittenThis) {
            ExifWriterService.markDateTouchedFromStep5(file, isPrimary: markAsPrimary);
          }
        } catch (e) {
          logError('[Step 7/8] EXIF write failed for ${file.path}: $e', forcePrint: true);
        }

        return {'gps': gpsWrittenThis, 'date': dtWrittenThis};
      }

      int completedEntities = 0;
      int gpsWrittenTotal = 0;
      int dateWrittenTotal = 0;

      // Process entities with bounded concurrency
      for (int i = 0; i < collection.length; i += maxConcurrency) {
        final slice = collection.asList().skip(i).take(maxConcurrency).toList(growable: false);

        final results = await Future.wait(
          slice.map((final entity) async {
            int localGps = 0;
            int localDate = 0;

            // Read GPS from primary sidecar JSON (input side) once per entity
            dynamic coordsFromPrimary;
            try {
              final primarySourceFile = File(entity.primaryFile.sourcePath);
              coordsFromPrimary = await jsonCoordinatesExtractor(primarySourceFile);
            } catch (_) {
              coordsFromPrimary = null;
            }

            // Iterate over all FileEntity elements and process output physical files only
            final List<FileEntity> allFiles = <FileEntity>[
              entity.primaryFile,
              ...entity.secondaryFiles,
            ];

            for (final fe in allFiles) {
              final String? outPath = fe.targetPath;
              if (outPath == null || fe.isShortcut) continue;

              final outFile = File(outPath);
              if (!await outFile.exists()) continue;

              final r = await writeForFile(
                file: outFile,
                markAsPrimary: identical(fe, entity.primaryFile),
                effectiveDate: entity.dateTaken,
                coordsFromPrimary: coordsFromPrimary,
              );
              if (r['gps'] == true) localGps++;
              if (r['date'] == true) localDate++;
            }

            return {'gps': localGps, 'date': localDate};
          }),
        );

        for (final r in results) {
          gpsWrittenTotal += r['gps'] ?? 0;
          dateWrittenTotal += r['date'] ?? 0;
          completedEntities++;
          progressBar.update(completedEntities);
        }

        if (!nativeOnly && enableExifToolBatch) await maybeFlushThresholds();
      }

      // ── Telemetry before final flush (helps diagnose "stalls" at N/N-1) ──
      if (!nativeOnly && enableExifToolBatch) {
        final int imagesQueued = totalQueued(pendingImagesByTagset);
        final int videosQueued = totalQueued(pendingVideosByTagset);
        print(''); // Forze breakline after progress bar
        logPrint('[Step 7/8] Pending before final flush → Images: $imagesQueued, Videos: $videosQueued');

        // SECOND-BAR: create and initialize the final flush bar ONLY now,
        // after the first bar has completed.
        finalFlushTotal = imagesQueued + videosQueued;
        if (finalFlushTotal > 0) {
          finalFlushBar = FillingBar(
            desc: '[ INFO  ] [Step 7/8] Flushing pending EXIF writes',
            total: finalFlushTotal,
            width: 50,
          );
        }
      }

      // Final batch flush (if batching was used). Use the old heuristic to decide argfile.
      if (!nativeOnly && enableExifToolBatch) {
        final int imagesQueued = totalQueued(pendingImagesByTagset);
        final int videosQueued = totalQueued(pendingVideosByTagset);
        final bool flushImagesWithArg = imagesQueued > (Platform.isWindows ? 30 : 60);
        final bool flushVideosWithArg = videosQueued > 6;
        await flushImageBatch(useArgFile: flushImagesWithArg);
        await flushVideoBatch(useArgFile: flushVideosWithArg);

        // SECOND-BAR: ensure it ends at 100% even si hubo splits/errores contados
        if (finalFlushBar != null) {
          finalFlushDone = finalFlushTotal;
          finalFlushBar.update(finalFlushDone);
          print(''); // salto de línea tras la segunda barra
        }
      } else {
        pendingImagesByTagset.clear();
        pendingVideosByTagset.clear();
      }

      // Unique-file metrics
      final gpsTotal = ExifWriterService.uniqueGpsFilesCount;
      final gpsPrim = ExifWriterService.uniqueGpsPrimaryCount;
      final gpsSec = ExifWriterService.uniqueGpsSecondaryCount;
      final dtTotal = ExifWriterService.uniqueDateFilesCount;
      final dtPrim = ExifWriterService.uniqueDatePrimaryCount;
      final dtSec = ExifWriterService.uniqueDateSecondaryCount;

      print('');  // print to force new line after progress bar
      if (gpsTotal > 0) {
        logPrint('[Step 7/8] $gpsTotal files got GPS set in EXIF data (primary=$gpsPrim, secondary=$gpsSec)');
      }
      if (dtTotal > 0) {
        logPrint('[Step 7/8] $dtTotal files got DateTime set in EXIF data (primary=$dtPrim, secondary=$dtSec)');
      }
      logPrint('[Step 7/8] Processed ${collection.entities.length} entities; touched ${ExifWriterService.uniqueFilesTouchedCount} files');

      final int touchedFilesBeforeReset = ExifWriterService.uniqueFilesTouchedCount;
      final int touchedGpsBeforeReset = ExifWriterService.uniqueGpsFilesCount;
      final int touchedDateBeforeReset = ExifWriterService.uniqueDateFilesCount;

      // Dump internal writer stats (resets counters)
      ExifWriterService.dumpWriterStats(logger: this);

      sw.stop();
      return StepResult.success(
        stepName: name,
        duration: sw.elapsed,
        data: {
          'coordinatesWritten': touchedGpsBeforeReset,
          'dateTimesWritten': touchedDateBeforeReset,
          'rawGpsWrites': gpsWrittenTotal,
          'rawDateWrites': dateWrittenTotal,
          'skipped': false,
        },
        message: 'Wrote EXIF data to $touchedFilesBeforeReset files',
      );
    } catch (e) {
      sw.stop();
      if (!_shouldSilenceExiftoolError(e)) {
        logError('[Step 7/8] Failed to write EXIF data: $e', forcePrint: true);
      }
      return StepResult.failure(
        stepName: name,
        duration: sw.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to write EXIF data',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) => context.mediaCollection.isEmpty;

  // ------------------------------- Utilities --------------------------------

  bool _resolveBatchingPreference(final Object? exifTool) {
    if (exifTool == null) return false;
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.enableExifToolBatch;
      if (v is bool) return v;
    } catch (_) {}
    // If not found enableExifToolBatch in config, enable batching by default.
    return true;
  }

  _UnsupportedPolicy _resolveUnsupportedPolicy() {
    bool force = false;
    bool silence = false;
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      if (dyn.forceProcessUnsupportedFormats is bool) {
        force = dyn.forceProcessUnsupportedFormats as bool;
      }
      if (dyn.silenceUnsupportedWarnings is bool) {
        silence = dyn.silenceUnsupportedWarnings as bool;
      }
    } catch (_) {}
    return _UnsupportedPolicy(
      forceProcessUnsupportedFormats: force,
      silenceUnsupportedWarnings: silence,
    );
  }

  bool _isDefinitelyUnsupportedForWrite({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    if (pathLower.endsWith('.avi') ||
        pathLower.endsWith('.mpg') ||
        pathLower.endsWith('.mpeg') ||
        pathLower.endsWith('.bmp')) {
      return true;
    }
    if (mimeHeader == 'video/x-msvideo' || mimeExt == 'video/x-msvideo') {
      return true; // AVI
    }
    if ((mimeHeader ?? '').contains('mpeg') || (mimeExt ?? '').contains('mpeg')) {
      return true; // MPG/MPEG
    }
    if ((mimeHeader ?? '') == 'image/bmp' || (mimeExt ?? '') == 'image/bmp') {
      return true; // BMP
    }
    return false;
  }

  String _describeUnsupported({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    if (pathLower.endsWith('.avi') ||
        mimeHeader == 'video/x-msvideo' ||
        mimeExt == 'video/x-msvideo') {
      return 'AVI';
    }
    if (pathLower.endsWith('.mpg') ||
        pathLower.endsWith('.mpeg') ||
        (mimeHeader ?? '').contains('mpeg') ||
        (mimeExt ?? '').contains('mpeg')) {
      return 'MPEG';
    }
    if (pathLower.endsWith('.bmp') ||
        mimeHeader == 'image/bmp' ||
        mimeExt == 'image/bmp') {
      return 'BMP';
    }
    return 'unsupported';
  }

  bool _shouldSilenceExiftoolError(final Object e) {
    final s = e.toString();
    if (s.contains('Truncated InteropIFD directory')) return true;
    return false;
  }

  Future<void> _tryDeleteTmp(final File f) async {
    try {
      final tmp = File('${f.path}_exiftool_tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  Future<void> _tryDeleteTmpForChunk(
    final List<MapEntry<File, Map<String, dynamic>>> chunk,
  ) async {
    for (final e in chunk) {
      await _tryDeleteTmp(e.key);
    }
  }

  int _resolveInt(final String name, {required final int defaultValue}) {
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.toJson != null ? (dyn.toJson()[name]) : (dyn[name]);
      if (v is int) return v;
      if (v is String) return int.tryParse(v) ?? defaultValue;
    } catch (_) {}
    return defaultValue;
  }

  // ─────────────────────────────── NEW HELPERS ───────────────────────────────
  /// Extract absolute paths from exiftool stderr lines like:
  /// "Error: Truncated InteropIFD directory - /abs/path/file.jpg"
  Set<String> _extractBadPathsFromExifError(final Object error) {
    final out = <String>{};
    final s = error.toString();
    for (final line in s.split('\n')) {
      final idx = line.lastIndexOf(' - /');
      if (idx > 0) {
        final p = line.substring(idx + 3).trim(); // after " - "
        if (p.isNotEmpty) {
          out.add(p.toLowerCase());
        }
      }
      // Windows-style paths (e.g., " - C:\path\file.jpg")
      final winIdx = line.lastIndexOf(' - ');
      if (winIdx > 0 && line.length > winIdx + 3) {
        final tail = line.substring(winIdx + 3).trim();
        if (tail.contains(':\\') && !tail.contains(' /')) {
          out.add(tail.toLowerCase());
        }
      }
    }
    return out;
  }

  /// Convert pending EXIF tags for a JPEG entry into XMP tags in place (B).
  /// Date: uses existing EXIF dt when present; GPS: converts to signed and drops Ref letters.
  void _retagEntryToXmpIfJpeg(final MapEntry<File, Map<String, dynamic>> entry) {
    final lower = entry.key.path.toLowerCase();
    if (!(lower.endsWith('.jpg') || lower.endsWith('.jpeg'))) return;
    final tags = entry.value;

    // DateTime mapping
    final dynamic dtVal = tags['DateTimeOriginal'] ?? tags['DateTimeDigitized'] ?? tags['DateTime'];
    tags.remove('DateTimeOriginal');
    tags.remove('DateTimeDigitized');
    tags.remove('DateTime');
    if (dtVal != null) {
      tags['XMP:CreateDate'] = dtVal;
      tags['XMP:DateTimeOriginal'] = dtVal;
      tags['XMP:ModifyDate'] = dtVal;
    }

    // GPS mapping
    double? _toDouble(dynamic v) {
      try {
        if (v == null) return null;
        final s = v.toString().trim().replaceAll('"', '');
        return double.tryParse(s);
      } catch (_) {
        return null;
      }
    }

    final latRef = (tags['GPSLatitudeRef'] ?? '').toString().toUpperCase();
    final lonRef = (tags['GPSLongitudeRef'] ?? '').toString().toUpperCase();
    double? lat = _toDouble(tags['GPSLatitude']);
    double? lon = _toDouble(tags['GPSLongitude']);
    if (lat != null && latRef == 'S') lat = -lat;
    if (lon != null && lonRef == 'W') lon = -lon;

    tags.remove('GPSLatitude');
    tags.remove('GPSLongitude');
    tags.remove('GPSLatitudeRef');
    tags.remove('GPSLongitudeRef');

    if (lat != null && lon != null) {
      tags['XMP:GPSLatitude'] = lat.toString();
      tags['XMP:GPSLongitude'] = lon.toString();
    }
  }
}

class _UnsupportedPolicy {
  const _UnsupportedPolicy({
    required this.forceProcessUnsupportedFormats,
    required this.silenceUnsupportedWarnings,
  });
  final bool forceProcessUnsupportedFormats;
  final bool silenceUnsupportedWarnings;
}
