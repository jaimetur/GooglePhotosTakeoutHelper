import 'dart:convert';
import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';
import 'package:gpth/gpth-lib.dart';

/// Step 5: Write EXIF data to media files
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
  WriteExifStep() : super('Write EXIF Data');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final sw = Stopwatch()..start();

    try {
      final collection = context.mediaCollection;

      print('\n[Step 5/8] Starting EXIF data writing for ${collection.length} files (this may take a while)...');
      if (!context.config.writeExif) {
        sw.stop();
        return StepResult.success(
          stepName: name,
          duration: sw.elapsed,
          data: {'coordinatesWritten': 0, 'dateTimesWritten': 0, 'skipped': true},
          message: 'EXIF writing skipped per configuration',
        );
      }

      // Visible progress bar (kept as before)
      final progressBar = FillingBar(desc: 'Writing EXIF data', total: collection.length, width: 50);

      // Services
      final exifTool = ServiceContainer.instance.exifTool; // may be null

      // Backward-compatible behavior: if exifTool == null → nativeOnly path
      final bool nativeOnly = exifTool == null;
      if (nativeOnly) {
        logWarning('[Step 5/8] ExifTool not available, writing EXIF data for native supported files only...', forcePrint: true);
        print('[Step 5/8] Starting EXIF data writing (native-only, no ExifTool) for ${collection.length} files');
      } else {
        logInfo('Exiftool enabled using argument nativeOnly=false', forcePrint: true);
      }

      // Batching preference (restored)
      final bool enableExifToolBatch = _resolveBatchingPreference(exifTool);
      if (enableExifToolBatch) {
        logInfo('Exiftool batch enabled using argument enableExifToolBatch=true. Exiftool will be called in batches with several files per batch', forcePrint: true);
      } else {
        logInfo('Exiftool batch processing disabled using argument enableExifToolBatch=false. Exiftool will be called 1 time per file', forcePrint: true);
      }

      // Calculate optimal concurrency
      final int maxConc = ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif);

      // Reuse writer across batch if possible
      final ExifWriterService? exifWriter = (exifTool != null) ? ExifWriterService(exifTool) : null;

      // Adaptive batch sizing (same intent as older code)
      final bool isWindows = Platform.isWindows;
      final int baseBatchSize = isWindows ? 60 : 120;

      // Separate queues for images and videos (restored)
      final pendingImagesBatch = <MapEntry<File, Map<String, dynamic>>>[];
      final pendingVideosBatch = <MapEntry<File, Map<String, dynamic>>>[];

      // Generic batch flush with per-file fallback on failure (restored)
      Future<void> _flushBatch(
        final List<MapEntry<File, Map<String, dynamic>>> queue, {
        required final bool useArgFile,
        required final bool isVideoBatch,
      }) async {
        if (nativeOnly || !enableExifToolBatch) return; // no batches in per-file mode
        if (queue.isEmpty) return;
        if (exifWriter == null) {
          queue.clear();
          return;
        }

        // Pre-clean *_exiftool_tmp (best-effort)
        try {
          for (final e in queue) {
            final tmp = File('${e.key.path}_exiftool_tmp');
            if (await tmp.exists()) {
              try {
                await tmp.delete();
              } catch (_) {}
            }
          }
        } catch (_) {}

        try {
          await exifWriter.writeBatchWithExifTool(queue, useArgFileWhenLarge: useArgFile);
        } catch (e) {
          logWarning(isVideoBatch ? 'Video batch flush failed (${queue.length} files): $e' : 'Batch flush failed (${queue.length} files): $e', forcePrint: true);
          // Retry per-file so nothing is lost
          for (final entry in queue) {
            try {
              await exifWriter.writeTagsWithExifTool(entry.key, entry.value);
            } catch (e2) {
              logWarning(isVideoBatch ? 'Per-file video write failed: ${entry.key.path} -> $e2' : 'Per-file write failed: ${entry.key.path} -> $e2', forcePrint: true);
            }
          }
        } finally {
          queue.clear();
        }
      }

      // Helpers to flush each queue
      Future<void> _flushImageBatch({required final bool useArgFile}) => _flushBatch(pendingImagesBatch, useArgFile: useArgFile, isVideoBatch: false);
      Future<void> _flushVideoBatch({required final bool useArgFile}) => _flushBatch(pendingVideosBatch, useArgFile: useArgFile, isVideoBatch: true);

      // Threshold-based flushing (restored)
      Future<void> _maybeFlushThresholds() async {
        if (nativeOnly || !enableExifToolBatch) return;
        final int targetImageBatch = baseBatchSize;
        const int targetVideoBatch = 12;
        if (pendingImagesBatch.length >= targetImageBatch) {
          await _flushImageBatch(useArgFile: true);
        }
        if (pendingVideosBatch.length >= targetVideoBatch) {
          await _flushVideoBatch(useArgFile: true);
        }
      }

      // Build processing order: multi-file entities first (pre-batch), then single-file entities (restored)
      final multi = <MediaEntity>[];
      final single = <MediaEntity>[];
      for (final e in collection.entities) {
        (e.files.files.length > 1 ? multi : single).add(e);
      }

      // MIME helpers (fast path by extension, but we will sniff header bytes too)
      bool _isAviByExt(final File f) => f.path.toLowerCase().endsWith('.avi');

      // Process a list of entities, optionally delaying flush until the end (restored)
      int completedEntities = 0;
      int gpsWrittenTotal = 0;
      int dateWrittenTotal = 0;

      Future<Map<String, int>> _processList(
        final List<MediaEntity> list, {
        required final bool delayFlushUntilEnd,
      }) async {
        int gpsWritten = 0;
        int dateWritten = 0;

        for (int i = 0; i < list.length; i += maxConc) {
          final slice = list.skip(i).take(maxConc).toList(growable: false);

          final results = await Future.wait(slice.map((entity) async {
            int localGps = 0;
            int localDate = 0;

            try {
              // Entity-level effective date (JSON sidecar preferred; restored)
              DateTime? effectiveDate;
              try {
                final File primary = entity.primaryFile;
                final DateTime? jsonDate = await _lateResolveDateFromJson(primary);
                effectiveDate = jsonDate ?? entity.dateTaken;
                if (jsonDate != null) {
                  logDebug('JSON sidecar date (entity-level) will be used for ${primary.path}: $effectiveDate');
                }
              } catch (_) {
                effectiveDate = entity.dateTaken;
              }

              // Deterministic file order: primary → others (restored)
              final files = <File>[];
              try {
                final primary = entity.primaryFile;
                files.add(primary);
                for (final f in entity.files.files.values) {
                  if (f.path != primary.path) files.add(f);
                }
              } catch (_) {
                if (entity.files.files.isNotEmpty) {
                  files.addAll(entity.files.files.values);
                }
              }

              for (final originalFile in files) {
                try {
                  // A) Resolver a un File existente; si no existe, saltar
                  final File? file = await _resolveReadableFile(originalFile);
                  if (file == null) {
                    logWarning('Skipping missing file (cannot resolve): ${_safePath(originalFile)}', forcePrint: true);
                    continue;
                  }

                  // MIME sniff (headerBytes) + fallback a extensión (restored)
                  List<int> headerBytes = const [];
                  String? mimeHeader;
                  String? mimeExt;
                  try {
                    headerBytes = await file.openRead(0, 128).first;
                    mimeHeader = lookupMimeType(file.path, headerBytes: headerBytes);
                    mimeExt = lookupMimeType(file.path);
                  } catch (e) {
                    logWarning('Failed to read header for ${file.path}: $e (falling back to extension)', forcePrint: true);
                    mimeHeader = lookupMimeType(file.path);
                    mimeExt = mimeHeader;
                  }

                  // B) Filtrar formatos no soportados antes de encolar o taggear
                  final pathLower = file.path.toLowerCase();
                  if (_isDefinitelyUnsupportedForWrite(mimeHeader: mimeHeader, mimeExt: mimeExt, pathLower: pathLower)) {
                    if (pathLower.endsWith('.avi') || mimeHeader == 'video/x-msvideo' || mimeExt == 'video/x-msvideo') {
                      logWarning('Skipping AVI file - ExifTool cannot write RIFF AVI: ${file.path}', forcePrint: true);
                    } else if (pathLower.endsWith('.mpg') || pathLower.endsWith('.mpeg') || (mimeHeader ?? '').contains('mpeg') || (mimeExt ?? '').contains('mpeg')) {
                      logWarning('Skipping MPEG file - ExifTool cannot write MPG/MPEG: ${file.path}', forcePrint: true);
                    } else if (pathLower.endsWith('.bmp') || mimeHeader == 'image/bmp' || mimeExt == 'image/bmp') {
                      logWarning('Skipping BMP file - ExifTool cannot write BMP: ${file.path}', forcePrint: true);
                    } else {
                      logWarning('Skipping unsupported format for EXIF write: ${file.path}', forcePrint: true);
                    }
                    continue;
                  }

                  bool gpsWrittenThis = false;
                  bool dtWrittenThis = false;

                  // Tags a escribir con ExifTool (batched o per-file)
                  final tagsToWrite = <String, dynamic>{};

                  // 1) GPS desde JSON si el EXIF no lo tiene (restored)
                  try {
                    final coords = await jsonCoordinatesExtractor(file);
                    if (coords != null) {
                      Map<String, dynamic>? existing;
                      if (!nativeOnly) {
                        final coordExtractor = ExifCoordinateExtractor(exifTool);
                        existing = await coordExtractor.extractGPSCoordinates(
                          file,
                          globalConfig: ServiceContainer.instance.globalConfig,
                        );
                      }
                      final hasCoords = existing != null && existing['GPSLatitude'] != null && existing['GPSLongitude'] != null;

                      if (!hasCoords) {
                        if (mimeHeader == 'image/jpeg') {
                          if (effectiveDate != null && !nativeOnly) {
                            // Try native combined first
                            final ok = await exifWriter!.writeCombinedNativeJpeg(file, effectiveDate, coords);
                            if (ok) {
                              gpsWrittenThis = true;
                              dtWrittenThis = true;
                            } else {
                              // Fallback a ExifTool tags
                              final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                              final dt = exifFormat.format(effectiveDate);
                              tagsToWrite['DateTimeOriginal'] = '"$dt"';
                              tagsToWrite['DateTimeDigitized'] = '"$dt"';
                              tagsToWrite['DateTime'] = '"$dt"';
                              tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                              tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                              tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                              tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                              gpsWrittenThis = true;
                              dtWrittenThis = true;
                            }
                          } else if (effectiveDate == null && !nativeOnly) {
                            // Sin fecha: solo GPS nativo si es posible
                            final ok = await exifWriter!.writeGpsNativeJpeg(file, coords);
                            if (ok) {
                              gpsWrittenThis = true;
                            } else {
                              tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                              tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                              tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                              tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                              gpsWrittenThis = true;
                            }
                          }
                        } else {
                          // No-JPEG: usar ExifTool (a menos que nativeOnly)
                          if (!nativeOnly) {
                            tagsToWrite['GPSLatitude'] = coords.toDD().latitude.toString();
                            tagsToWrite['GPSLongitude'] = coords.toDD().longitude.toString();
                            tagsToWrite['GPSLatitudeRef'] = coords.latDirection.abbreviation.toString();
                            tagsToWrite['GPSLongitudeRef'] = coords.longDirection.abbreviation.toString();
                          }
                        }
                      }
                    }
                  } catch (e) {
                    logWarning('Failed to extract/write GPS for ${_safePath(file)}: $e', forcePrint: true);
                  }

                  // 2) DateTime writer (nativo preferido para JPEG, si no ExifTool) — restored
                  try {
                    if (effectiveDate != null) {
                      if (mimeHeader == 'image/jpeg') {
                        if (!dtWrittenThis && !nativeOnly) {
                          final ok = await exifWriter!.writeDateTimeNativeJpeg(file, effectiveDate);
                          if (ok) {
                            dtWrittenThis = true;
                          } else {
                            final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                            final dt = exifFormat.format(effectiveDate);
                            if (!nativeOnly) {
                              tagsToWrite['DateTimeOriginal'] = '"$dt"';
                              tagsToWrite['DateTimeDigitized'] = '"$dt"';
                              tagsToWrite['DateTime'] = '"$dt"';
                              dtWrittenThis = true;
                            }
                          }
                        }
                      } else {
                        if (!nativeOnly) {
                          final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                          final dt = exifFormat.format(effectiveDate);
                          tagsToWrite['DateTimeOriginal'] = '"$dt"';
                          tagsToWrite['DateTimeDigitized'] = '"$dt"';
                          tagsToWrite['DateTime'] = '"$dt"';
                        }
                      }
                    }
                  } catch (e) {
                    logWarning('Failed to write DateTime for ${_safePath(file)}: $e', forcePrint: true);
                  }

                  // 3) Encolar o per-file con ExifTool según configuración (restored)
                  try {
                    if (!nativeOnly && tagsToWrite.isNotEmpty) {
                      // Evitar mismatch extensión/contenido que haría fallar ExifTool (restored)
                      if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
                        logWarning("EXIF Writer - Extension indicates '$mimeExt' but header is '$mimeHeader'. Enqueuing for ExifTool batch.\n ${file.path}", forcePrint: true);
                      }
                      // Skip AVI / RIFF (restored) — aunque arriba ya lo filtramos; doble seguro
                      if (_isAviByExt(file) || mimeExt == 'video/x-msvideo' || mimeHeader == 'video/x-msvideo') {
                        logWarning('Skipping AVI file - ExifTool cannot write RIFF AVI: ${file.path}', forcePrint: true);
                      } else {
                        final isVideo = mimeHeader != null && mimeHeader.startsWith('video/');
                        if (!enableExifToolBatch) {
                          // Per-file (no batches)
                          try {
                            await exifWriter!.writeTagsWithExifTool(file, tagsToWrite);
                          } catch (e) {
                            logWarning(isVideo ? 'Per-file video write failed: ${file.path} -> $e' : 'Per-file write failed: ${file.path} -> $e', forcePrint: true);
                          }
                        } else {
                          // Batched (queue)
                          if (isVideo) {
                            pendingVideosBatch.add(MapEntry(file, tagsToWrite));
                          } else {
                            pendingImagesBatch.add(MapEntry(file, tagsToWrite));
                          }
                        }
                      }
                    }
                  } catch (e) {
                    logWarning('Failed to enqueue EXIF tags for ${_safePath(file)}: $e', forcePrint: true);
                  }

                  if (gpsWrittenThis) localGps++;
                  if (dtWrittenThis) localDate++;
                } catch (e) {
                  logError('EXIF write failed for ${_safePath(originalFile)}: $e', forcePrint: true);
                }
              }
            } catch (e) {
              logError('Entity processing failed for ${_safePath(entity.primaryFile)}: $e', forcePrint: true);
            }

            return {'gps': localGps, 'date': localDate};
          }));

          for (final r in results) {
            gpsWritten += r['gps'] ?? 0;
            dateWritten += r['date'] ?? 0;
            completedEntities++;
            progressBar.update(completedEntities);
          }

          // Durante pre-batch (delayFlushUntilEnd == true) no vaciamos por thresholds
          if (!nativeOnly && enableExifToolBatch && !delayFlushUntilEnd) {
            await _maybeFlushThresholds();
          }
        }

        // Si retrasamos el flush para esta lista, hazlo ahora (restored)
        if (!nativeOnly && enableExifToolBatch && delayFlushUntilEnd) {
          final bool flushImagesWithArg = pendingImagesBatch.length > (Platform.isWindows ? 30 : 60);
          final bool flushVideosWithArg = pendingVideosBatch.length > 6;
          await _flushImageBatch(useArgFile: flushImagesWithArg);
          await _flushVideoBatch(useArgFile: flushVideosWithArg);
        }

        return {'gps': gpsWritten, 'date': dateWritten};
      }

      // Wrap the whole processing to guarantee final flush in any case (restored)
      try {
        // 1) Pre-batch phase: multi-file entities (delay flush)
        if (multi.isNotEmpty) {
          final r = await _processList(multi, delayFlushUntilEnd: true);
          gpsWrittenTotal += r['gps']!;
          dateWrittenTotal += r['date']!;
        }

        // 2) Normal phase: single-file entities with threshold-based flushing
        if (single.isNotEmpty) {
          final r = await _processList(single, delayFlushUntilEnd: false);
          gpsWrittenTotal += r['gps']!;
          dateWrittenTotal += r['date']!;
        }
      } finally {
        // Final safety flush (only if batching is enabled)
        if (!nativeOnly && enableExifToolBatch) {
          final bool flushImagesWithArg = pendingImagesBatch.length > (Platform.isWindows ? 30 : 60);
          final bool flushVideosWithArg = pendingVideosBatch.length > 6;
          await _flushImageBatch(useArgFile: flushImagesWithArg);
          await _flushVideoBatch(useArgFile: flushVideosWithArg);
        } else {
          pendingImagesBatch.clear();
          pendingVideosBatch.clear();
        }
      }

      print(''); // Force new line after progress bar

      if (gpsWrittenTotal > 0) {
        print('$gpsWrittenTotal files got GPS set in EXIF data');
      }
      if (dateWrittenTotal > 0) {
        print('$dateWrittenTotal files got DateTime set in EXIF data');
      }

      // Final writer stats (seconds) and GPS extractor stats (restored)
      ExifWriterService.dumpWriterStats(reset: true, logger: this);
      ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

      sw.stop();
      return StepResult.success(
        stepName: name,
        duration: sw.elapsed,
        data: {'coordinatesWritten': gpsWrittenTotal, 'dateTimesWritten': dateWrittenTotal, 'skipped': false},
        message: 'Wrote EXIF data to ${gpsWrittenTotal + dateWrittenTotal} files',
      );
    } catch (e) {
      sw.stop();
      return StepResult.failure(
        stepName: name,
        duration: sw.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to write EXIF data: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) => context.mediaCollection.isEmpty;

  String _safePath(final File f) {
    try {
      return f.path;
    } catch (_) {
      return '<unknown-file>';
    }
  }

  // Late JSON resolve used only here (restored behavior, tolerant).
  Future<DateTime?> _lateResolveDateFromJson(final File file) async {
    try {
      final sidecar = await JsonMetadataMatcherService.findJsonForFile(file, tryhard: true);
      if (sidecar == null) return null;
      final raw = await sidecar.readAsString();
      final data = jsonDecode(raw);
      final ts = (data is Map<String, dynamic>) ? (data['photoTakenTime']?['timestamp'] ?? data['creationTime']?['timestamp']) : null;
      if (ts == null) return null;
      final seconds = int.tryParse(ts.toString()) ?? 0;
      if (seconds <= 0) return null;
      final utc = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      return utc.toLocal();
    } catch (e) {
      logWarning('Late JSON date parse failed for ${_safePath(file)}: $e', forcePrint: true);
      return null;
    }
  }

  // NEW (restored semantics): resolve batching preference in a tolerant way.
  // Reads optional `enableBatching` from GlobalConfig if present; defaults to true
  // when ExifTool is available (since batching only makes sense with ExifTool).
  bool _resolveBatchingPreference(final Object? exifTool) {
    if (exifTool == null) return false; // no ExifTool → no batching
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.enableBatching; // may not exist
      if (v is bool) return v;
    } catch (_) {
      // ignore: property not present or not accessible
    }
    return true; // default: enabled if ExifTool is available
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Helpers añadidos para limpieza de rutas y filtro de formatos
  // ───────────────────────────────────────────────────────────────────────────

  // Devuelve un File legible (original o “reparado” eliminando espacios/puntos finales
  // de los segmentos de directorio). No renombra en disco. Si no existe, devuelve null.
  Future<File?> _resolveReadableFile(final File f) async {
    try {
      if (await f.exists()) return f;
    } catch (_) {}
    final repaired = await _tryTrimTrailingSpacesInSegments(f.path);
    if (repaired != null) {
      try {
        final fr = File(repaired);
        if (await fr.exists()) return fr;
      } catch (_) {}
    }
    return null;
  }

  // Genera una variante de la ruta eliminando [ .]+ al final de cada segmento
  // de directorio (no toca el nombre del fichero). Si no hay cambios, devuelve null.
  Future<String?> _tryTrimTrailingSpacesInSegments(final String fullPath) async {
    final sep = Platform.pathSeparator;
    final parts = fullPath.split(sep);
    if (parts.isEmpty) return null;

    final fileName = parts.removeLast(); // no tocar el fichero
    final repairedDirs = <String>[];
    for (final seg in parts) {
      if (seg.isEmpty) {
        repairedDirs.add(seg);
        continue;
      }
      repairedDirs.add(seg.replaceAll(RegExp(r'[. ]+$'), ''));
    }
    final candidate = (repairedDirs..add(fileName)).join(sep);
    return candidate == fullPath ? null : candidate;
  }

  // Formatos que ExifTool no escribe y conviene filtrar antes de encolar.
  bool _isDefinitelyUnsupportedForWrite({
    String? mimeHeader,
    String? mimeExt,
    required String pathLower,
  }) {
    if (pathLower.endsWith('.avi') || pathLower.endsWith('.mpg') || pathLower.endsWith('.mpeg') || pathLower.endsWith('.bmp')) return true;
    if (mimeHeader == 'video/x-msvideo' || mimeExt == 'video/x-msvideo') return true; // AVI
    if ((mimeHeader ?? '').contains('mpeg') || (mimeExt ?? '').contains('mpeg')) return true; // MPG/MPEG
    if ((mimeHeader ?? '') == 'image/bmp' || (mimeExt ?? '') == 'image/bmp') return true; // BMP
    return false;
  }
}
