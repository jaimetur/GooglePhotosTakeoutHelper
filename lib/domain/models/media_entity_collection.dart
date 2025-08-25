import 'dart:io';
import 'dart:convert';

import '../../infrastructure/exiftool_service.dart';
import '../../shared/concurrency_manager.dart';
import '../entities/media_entity.dart';
import '../services/core/logging_service.dart';
import '../services/core/service_container.dart';
import '../services/metadata/date_extraction/json_date_extractor.dart';
import '../services/metadata/exif_writer_service.dart';
import '../services/metadata/date_extraction/exif_date_extractor.dart';
import '../services/metadata/coordinate_extraction/exif_coordinate_extractor.dart';
import '../services/metadata/json_metadata_matcher_service.dart';
import '../value_objects/date_time_extraction_method.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

/// Modern domain model representing a collection of media entities.
/// Full API: includes extractDates, writeExifData (batched), removeDuplicates,
/// findAlbums, getStatistics, entities getter and indexers.
class MediaEntityCollection with LoggerMixin {
  MediaEntityCollection([final List<MediaEntity>? initialMedia])
      : _media = initialMedia ?? [];

  final List<MediaEntity> _media;

  /// Read-only access to entities (required by moving service).
  Iterable<MediaEntity> get entities => _media;

  /// Read-only list copy.
  List<MediaEntity> get media => List.unmodifiable(_media);

  /// Number of media items in the collection
  int get length => _media.length;

  /// Whether the collection is empty
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;

  void add(final MediaEntity mediaEntity) => _media.add(mediaEntity);
  void addAll(final Iterable<MediaEntity> mediaEntities) => _media.addAll(mediaEntities);
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);
  void clear() => _media.clear();

  MediaEntity operator [](final int index) => _media[index];
  void operator []=(final int index, final MediaEntity mediaEntity) => _media[index] = mediaEntity;

  // ─────────────────────────── Step 3: Remove duplicates ────────────────────────────
  /// Uses content-based duplicate detection to identify and remove duplicate files,
  /// keeping the best version of each duplicate group.
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService = ServiceContainer.instance.duplicateDetectionService;
    int removedCount = 0;

    // Group media by album association first to preserve cross-album duplicates
    final albumGroups = <String?, List<MediaEntity>>{};
    for (final media in _media) {
      // Get the album key (null for year folder files, album name for album files)
      final albumKey = media.files.getAlbumKey();
      albumGroups.putIfAbsent(albumKey, () => []).add(media);
    }

    // Process each album group separately to avoid removing cross-album duplicates
    final entitiesToRemove = <MediaEntity>[];
    int processed = 0;
    final totalGroups = albumGroups.length;

    for (final albumGroup in albumGroups.values) {
      if (albumGroup.length <= 1) {
        processed++;
        onProgress?.call(processed, totalGroups);
        continue;
      }

      // Find duplicates within this album group only
      final hashGroups = await duplicateService.groupIdentical(albumGroup);

      for (final group in hashGroups.values) {
        if (group.length <= 1) {
          continue; // No duplicates in this group
        }

        // Sort by best date extraction quality, then file name length
        group.sort((final MediaEntity a, final MediaEntity b) {
          // Prefer files with dates from better extraction methods
          final aAccuracy = a.dateAccuracy?.value ?? 999;
          final bAccuracy = b.dateAccuracy?.value ?? 999;
          if (aAccuracy != bAccuracy) {
            return aAccuracy.compareTo(bAccuracy);
          }

          // If equal accuracy, prefer shorter file names (typically original names)
          final aLen = a.files.firstFile.path.length;
          final bLen = b.files.firstFile.path.length;
          return aLen.compareTo(bLen);
        });

        // Add all duplicates except the first (best) one to removal list
        final duplicatesToRemove = group.sublist(1);

        // Log which duplicates are being removed
        if (duplicatesToRemove.isNotEmpty) {
          final keptFile = group.first.primaryFile.path;
          logDebug('Found ${group.length} identical files, keeping: $keptFile');
          for (final duplicate in duplicatesToRemove) {
            logDebug('  Removing duplicate: ${duplicate.primaryFile.path}');
          }
        }

        entitiesToRemove.addAll(duplicatesToRemove);
        removedCount += duplicatesToRemove.length;
      }

      processed++;
      onProgress?.call(processed, totalGroups);
    }

    // Remove afterwards to avoid concurrent modification
    for (final e in entitiesToRemove) {
      _media.remove(e);
    }

    return removedCount;
  }

  // ───────────────────────────────── Step 4: Extract dates ─────────────────────────────────
  Future<Map<DateTimeExtractionMethod, int>> extractDates(
    final List<Future<DateTime?> Function(MediaEntity)> extractors, {
    final void Function(int current, int total)? onProgress,
  }) async {
    final extractionStats = <DateTimeExtractionMethod, int>{};
    var completed = 0;

    // Map extractor index to extraction method for proper tracking
    final extractorMethods = [
      DateTimeExtractionMethod.json, // JSON extractor (first priority)
      DateTimeExtractionMethod.exif, // EXIF extractor (second priority)
      DateTimeExtractionMethod.guess, // Filename guess extractor (if enabled)
      DateTimeExtractionMethod.jsonTryHard, // JSON tryhard extractor (last resort)
      DateTimeExtractionMethod.folderYear, // Folder year extractor (fallback)
    ];

    // Get optimal concurrency for EXIF operations using ConcurrencyManager
    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );
    logInfo('Starting $maxConcurrency threads (exif date extraction concurrency)', forcePrint: true);

    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();
      final batchStartIndex = i;

      final futures = batch.asMap().entries.map((final entry) async {
        final batchIndex = entry.key;
        final mediaFile = entry.value;
        final actualIndex = batchStartIndex + batchIndex;

        DateTimeExtractionMethod? extractionMethod;

        // Skip if media already has a date
        if (mediaFile.dateTaken != null) {
          extractionMethod = mediaFile.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
          return {
            'index': actualIndex,
            'mediaFile': mediaFile,
            'extractionMethod': extractionMethod,
          };
        }

        // Try each extractor in sequence until one succeeds
        bool dateFound = false;
        MediaEntity updatedMediaFile = mediaFile;

        for (int extractorIndex = 0; extractorIndex < extractors.length; extractorIndex++) {
          final extractor = extractors[extractorIndex];
          final extractedDate = await extractor(mediaFile);

          if (extractedDate != null) {
            // Determine the correct extraction method based on extractor index
            extractionMethod = extractorIndex < extractorMethods.length
                ? extractorMethods[extractorIndex]
                : DateTimeExtractionMethod.guess;

            updatedMediaFile = mediaFile.withDate(
              dateTaken: extractedDate,
              dateTimeExtractionMethod: extractionMethod,
            );

            logDebug('Date extracted for ${mediaFile.primaryFile.path}: $extractedDate (method: ${extractionMethod.name})');
            dateFound = true;
            break;
          }
        }

        if (!dateFound) {
          extractionMethod = DateTimeExtractionMethod.none;
          updatedMediaFile = mediaFile.withDate(
            dateTimeExtractionMethod: DateTimeExtractionMethod.none,
          );
        }

        return {
          'index': actualIndex,
          'mediaFile': updatedMediaFile,
          'extractionMethod': extractionMethod,
        };
      });

      // Wait for all futures in this batch to complete
      final results = await Future.wait(futures);

      // Update the media list and statistics with results from this batch
      for (final result in results) {
        final index = result['index'] as int;
        final updatedMediaFile = result['mediaFile'] as MediaEntity;
        final method = result['extractionMethod'] as DateTimeExtractionMethod;

        _media[index] = updatedMediaFile;
        extractionStats[method] = (extractionStats[method] ?? 0) + 1;
        completed++;
      }

      // Report progress
      onProgress?.call(completed, _media.length);
    }

    // >>> Print READ-EXIF stats summary (seconds) after step 4
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this, exiftoolFallbackEnabled: ServiceContainer.instance.globalConfig.fallbackToExifToolOnNativeMiss == true);

    return extractionStats;
  }

  // ──────────────────────────────── Step 5: Write EXIF ────────────────────────────────
  /// Updates EXIF metadata for media entities that have date/time information
  /// and coordinate data, tracking success statistics.
  Future<Map<String, int>> writeExifData({
    final void Function(int current, int total)? onProgress,
    bool exifToolBatching = false,
  }) async {
    // Check if ExifTool is available before proceeding
    final exifTool = ServiceContainer.instance.exifTool;
    if (exifTool == null) {
      logWarning('ExifTool not available, writing EXIF data for native supported files only');
      logInfo('[Step 5/8] Starting EXIF data writing (native-only, no ExifTool) for ${_media.length} files', forcePrint: true);
      return _writeExifDataParallel(onProgress, null, nativeOnly: true, disableExifToolBatch: true);
    }

    logInfo('[Step 5/8] Starting EXIF data writing for ${_media.length} files', forcePrint: true);

    // Always use parallel processing for optimal performance
    return _writeExifDataParallel(
      onProgress,
      exifTool,
      nativeOnly: false,
      disableExifToolBatch: !exifToolBatching,
    );
  }

  /// Parallel + adaptive batch strategy:
  /// - For JPEG: prefer native writes; combine Date+GPS when possible.
  /// - For non-JPEG: gather tags and batch via exiftool. Uses argfile for very large batches.
  /// - NEW: If native JPEG write fails → fall back to exiftool by enqueuing tags.
  /// - IMPORTANT: Per-file try/catch ensures one failure does not abort the whole step.
  Future<Map<String, int>> _writeExifDataParallel(
    final void Function(int current, int total)? onProgress,
    final ExifToolService? exifTool, {
    bool nativeOnly = false,
    bool disableExifToolBatch = true,
  }) async {
    var coordinatesWritten = 0;
    var dateTimesWritten = 0;
    var completed = 0;

    // Calculate optimal concurrency
    final maxConcurrency = ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif);

    // Reuse writer and coordinate extractor across the batch
    final ExifWriterService? exifWriter = (exifTool != null) ? ExifWriterService(exifTool) : null;
    final coordExtractor = exifTool != null ? ExifCoordinateExtractor(exifTool) : null;
    final globalConfig = ServiceContainer.instance.globalConfig;

    // Adaptive batch sizing
    final bool isWindows = Platform.isWindows;
    final int baseBatchSize = isWindows ? 60 : 120;

    // Two separated queues: images and videos
    final List<MapEntry<File, Map<String, dynamic>>> pendingImagesBatch = [];
    final List<MapEntry<File, Map<String, dynamic>>> pendingVideosBatch = [];

    Future<void> _flushBatchGeneric(
      List<MapEntry<File, Map<String, dynamic>>> queue, {
      required bool useArgFile,
      required bool isVideoBatch,
    }) async {
      if (nativeOnly || disableExifToolBatch) return; // sin lotes en modo per-file
      if (queue.isEmpty) return;
      if (exifWriter == null) {
        queue.clear();
        return;
      }

      // Limpieza previa de *_exiftool_tmp
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

      // Intento 1: batch
      try {
        await exifWriter.writeBatchWithExifTool(
          queue,
          useArgFileWhenLarge: useArgFile,
        );
      } catch (e) {
        logWarning(
          isVideoBatch
              ? 'Video batch flush failed (${queue.length} files): $e'
              : 'Batch flush failed (${queue.length} files): $e',
        );

        // Reintento por-fichero para no perder nada
        for (final entry in queue) {
          try {
            await exifWriter.writeTagsWithExifTool(entry.key, entry.value);
          } catch (e2) {
            logWarning(
              isVideoBatch
                  ? 'Per-file video write failed: ${entry.key.path} -> $e2'
                  : 'Per-file write failed: ${entry.key.path} -> $e2',
            );
          }
        }
      } finally {
        queue.clear();
      }
    }

    // Helpers for specific flush
    Future<void> _flushImageBatch({required bool useArgFile}) =>
        _flushBatchGeneric(pendingImagesBatch, useArgFile: useArgFile, isVideoBatch: false);

    Future<void> _flushVideoBatch({required bool useArgFile}) =>
        _flushBatchGeneric(pendingVideosBatch, useArgFile: useArgFile, isVideoBatch: true);

    // Wrap the whole loop so we guarantee a final flush even if an unexpected error occurs.
    try {
      for (int i = 0; i < _media.length; i += maxConcurrency) {
        final batch = _media.skip(i).take(maxConcurrency).toList();

        final futures = batch.map((final mediaEntity) async {
          // Per-file safety net: never let a single failure abort the batch.
          try {
            final file = mediaEntity.files.firstFile;

            // Cache MIME/header once with protection against stream errors.
            List<int> headerBytes = const [];
            String? mimeHeader;
            String? mimeExt;

            try {
              headerBytes = await file.openRead(0, 128).first;
              mimeHeader = lookupMimeType(file.path, headerBytes: headerBytes);
              mimeExt = lookupMimeType(file.path);
            } catch (e) {
              // Header read failed; fall back to extension-based guess.
              logWarning('Failed to read header for ${file.path}: $e (falling back to extension)');
              mimeHeader = lookupMimeType(file.path);
              mimeExt = mimeHeader;
            }

            bool gpsWritten = false;
            bool dateTimeWrittenLocal = false;

            // Accumulate tags for non-JPEG or for JPEG fallback to exiftool
            final Map<String, dynamic> tagsToWrite = {};

            // 0) Prefer JSON date if available (override any previous non-JSON date)
            DateTime? effectiveDate;
            final DateTime? jsonDate = await _lateResolveDateFromJson(file);
            if (jsonDate != null) {
              effectiveDate = jsonDate;
              logDebug('JSON sidecar date will be used for ${file.path}: $effectiveDate');
            } else {
              effectiveDate = mediaEntity.dateTaken;
            }

            // 1) GPS coordinates Writter from JSON if EXIF lacks it
            try {
              final coordinates = await jsonCoordinatesExtractor(file);
              if (coordinates != null) {
                // Check if EXIF already has GPS
                Map<String, dynamic>? existing;
                if (coordExtractor != null) {
                  existing = await coordExtractor.extractGPSCoordinates(
                    file,
                    globalConfig: globalConfig,
                  );
                }
                final hasCoords = existing != null &&
                    existing['GPSLatitude'] != null &&
                    existing['GPSLongitude'] != null;

                if (!hasCoords) {
                  if (mimeHeader == 'image/jpeg') {
                    // Try native combined; fallback a ExifTool si falla
                    if (effectiveDate != null) {
                      final ok = (exifWriter != null)
                          ? await exifWriter.writeCombinedNativeJpeg(
                              file,
                              effectiveDate,
                              coordinates,
                            )
                          : false;
                      if (ok) {
                        gpsWritten = true;
                        dateTimeWrittenLocal = true;
                      } else {
                        if (!nativeOnly) {
                          final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                          final dt = exifFormat.format(effectiveDate);
                          tagsToWrite['DateTimeOriginal'] = '"$dt"';
                          tagsToWrite['DateTimeDigitized'] = '"$dt"';
                          tagsToWrite['DateTime'] = '"$dt"';
                          tagsToWrite['GPSLatitude'] = coordinates.toDD().latitude.toString();
                          tagsToWrite['GPSLongitude'] = coordinates.toDD().longitude.toString();
                          tagsToWrite['GPSLatitudeRef'] = coordinates.latDirection.abbreviation.toString();
                          tagsToWrite['GPSLongitudeRef'] = coordinates.longDirection.abbreviation.toString();
                          gpsWritten = true;
                          dateTimeWrittenLocal = true;
                        }
                      }
                    } else {
                      final ok = (exifWriter != null)
                          ? await exifWriter.writeGpsNativeJpeg(file, coordinates)
                          : false;
                      if (ok) {
                        gpsWritten = true;
                      } else {
                        if (!nativeOnly) {
                          tagsToWrite['GPSLatitude'] = coordinates.toDD().latitude.toString();
                          tagsToWrite['GPSLongitude'] = coordinates.toDD().longitude.toString();
                          tagsToWrite['GPSLatitudeRef'] = coordinates.latDirection.abbreviation.toString();
                          tagsToWrite['GPSLongitudeRef'] = coordinates.longDirection.abbreviation.toString();
                          gpsWritten = true;
                        }
                      }
                    }
                  } else {
                    // Non-JPEG → exiftool si no estamos en nativeOnly
                    if (!nativeOnly) {
                      tagsToWrite['GPSLatitude'] = coordinates.toDD().latitude.toString();
                      tagsToWrite['GPSLongitude'] = coordinates.toDD().longitude.toString();
                      tagsToWrite['GPSLatitudeRef'] = coordinates.latDirection.abbreviation.toString();
                      tagsToWrite['GPSLongitudeRef'] = coordinates.longDirection.abbreviation.toString();
                    }
                  }
                }
              }
            } catch (e) {
              // GPS extraction/writing failure for this file is logged; continue.
              logWarning('Failed to extract/write GPS for ${file.path}: $e');
            }

            // 2) Native Exif Writer (now also when originally null but resolved from JSON)
            try {
              if (effectiveDate != null) {
                if (mimeHeader == 'image/jpeg') {
                  if (!dateTimeWrittenLocal) {
                    final ok = (exifWriter != null)
                        ? await exifWriter.writeDateTimeNativeJpeg(file, effectiveDate)
                        : false;
                    if (ok) {
                      dateTimeWrittenLocal = true;
                    } else {
                      if (!nativeOnly) {
                        final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                        final dt = exifFormat.format(effectiveDate);
                        tagsToWrite['DateTimeOriginal'] = '"$dt"';
                        tagsToWrite['DateTimeDigitized'] = '"$dt"';
                        tagsToWrite['DateTime'] = '"$dt"';
                        dateTimeWrittenLocal = true;
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
              // DateTime write failure for this file is logged; continue.
              logWarning('Failed to write DateTime for ${file.path}: $e');
            }

            // 3) Encolar o escribir per-file con ExifTool según configuración
            try {
              if (!nativeOnly && tagsToWrite.isNotEmpty) {
                // Avoid extension/content mismatch that would make exiftool fail
                if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
                  logWarning("EXIF Writer - Extension indicates '$mimeExt' but header is '$mimeHeader'. Enqueuing for ExifTool batch.\n ${file.path}");
                }
                if (mimeExt == 'video/x-msvideo' || mimeHeader == 'video/x-msvideo') {
                  logWarning('Skipping AVI file - ExifTool cannot write RIFF AVI: ${file.path}');
                } else {
                  final isVideo = (mimeHeader != null && mimeHeader.startsWith('video/'));
                  if (disableExifToolBatch) {
                    // escritura por archivo (sin lotes)
                    if (exifWriter != null) {
                      try {
                        await exifWriter.writeTagsWithExifTool(file, tagsToWrite);
                      } catch (e) {
                        logWarning(
                          isVideo
                              ? 'Per-file video write failed: ${file.path} -> $e'
                              : 'Per-file write failed: ${file.path} -> $e',
                        );
                      }
                    }
                  } else {
                    // escritura en lote (cola)
                    if (isVideo) {
                      pendingVideosBatch.add(MapEntry(file, tagsToWrite));
                    } else {
                      pendingImagesBatch.add(MapEntry(file, tagsToWrite));
                    }
                  }
                }
              }
            } catch (e) {
              // Enqueue/flush preparation failed for this file; continue.
              logWarning('Failed to enqueue EXIF tags for ${file.path}: $e');
            }

            return {'gps': gpsWritten, 'dateTime': dateTimeWrittenLocal};
          } catch (e) {
            // Defensive catch-all for any unexpected per-file error.
            // This guarantees we continue with the next file.
            final pathSafe = () {
              try { return mediaEntity.files.firstFile.path; } catch (_) { return '<unknown>'; }
            }();
            logError('EXIF write failed for $pathSafe: $e', forcePrint: true);
            return {'gps': false, 'dateTime': false};
          }
        });

        final results = await Future.wait(futures);

        for (final result in results) {
          if (result['gps'] == true) coordinatesWritten++;
          if (result['dateTime'] == true) dateTimesWritten++;
          completed++;
        }

        onProgress?.call(completed, _media.length);

        // Flushed serializados: imágenes y vídeos por separado (solo si hay lotes)
        if (!nativeOnly && !disableExifToolBatch) {
          final int targetImageBatch = baseBatchSize;
          final int targetVideoBatch = 12; // lotes pequeños para vídeos
          if (pendingImagesBatch.length >= targetImageBatch) {
            await _flushImageBatch(useArgFile: true);
          }
          if (pendingVideosBatch.length >= targetVideoBatch) {
            await _flushVideoBatch(useArgFile: true);
          }
        }
      }
    } finally {
      // Flush any remaining batches (solo si hay lotes)
      if (!nativeOnly && !disableExifToolBatch) {
        final bool flushImagesWithArg = pendingImagesBatch.length > (Platform.isWindows ? 30 : 60);
        final bool flushVideosWithArg = pendingVideosBatch.length > 6;
        await _flushImageBatch(useArgFile: flushImagesWithArg);
        await _flushVideoBatch(useArgFile: flushVideosWithArg);
      } else {
        pendingImagesBatch.clear();
        pendingVideosBatch.clear();
      }
    }

    if (coordinatesWritten > 0) {
      logInfo('$coordinatesWritten files got GPS set in EXIF data', forcePrint: true);
    }
    if (dateTimesWritten > 0) {
      logInfo('$dateTimesWritten files got DateTime set in EXIF data', forcePrint: true);
    }

    // Final writer stats in seconds (no READ-EXIF lines here)
    ExifWriterService.dumpWriterStats(reset: true, logger: this);
    // GPS extractor stats (includes GPS extraction timings and bracketed label)
    ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  // ──────────────────────────────── Step 6: Find Albums ────────────────────────────────
  /// Find and merge album relationships in the collection
  ///
  /// This method detects media files that appear in multiple locations
  /// (year folders and album folders) and merges them into single entities
  /// with all file associations preserved.
  Future<void> findAlbums({
    final void Function(int processed, int total)? onProgress,
  }) async {
    final albumService = ServiceContainer.instance.albumRelationshipService;

    final mediaCopy = List<MediaEntity>.from(_media);
    final mergedMedia = await albumService.detectAndMergeAlbums(mediaCopy);

    _media
      ..clear()
      ..addAll(mergedMedia);

    onProgress?.call(_media.length, _media.length);
  }

  /// Get processing statistics for the collection
  ///
  /// Returns comprehensive statistics about the media collection including
  /// file counts, date information, and extraction method distribution.
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final mediaEntity in _media) {
      // Count media with dates
      if (mediaEntity.dateTaken != null) {
        mediaWithDates++;
      }

      // Count media with album associations
      if (mediaEntity.files.hasAlbumFiles) {
        mediaWithAlbums++;
      }

      // Count total files
      totalFiles += mediaEntity.files.files.length;

      // Track extraction method distribution
      final method =
          mediaEntity.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
      extractionMethodDistribution[method] =
          (extractionMethodDistribution[method] ?? 0) + 1;
    }

    return ProcessingStatistics(
      totalMedia: _media.length,
      mediaWithDates: mediaWithDates,
      mediaWithAlbums: mediaWithAlbums,
      totalFiles: totalFiles,
      extractionMethodDistribution: extractionMethodDistribution,
    );
  }

  /// Late JSON resolve helper used only in Step 5 when an entity has no date.
  /// Attempts to locate the sidecar JSON and parse photoTakenTime.timestamp.
  Future<DateTime?> _lateResolveDateFromJson(final File file) async {
    try {
      final File? jsonSidecar = await JsonMetadataMatcherService.findJsonForFile(
        file,
        tryhard: true,
      );
      if (jsonSidecar == null) return null;

      final String raw = await jsonSidecar.readAsString();
      final dynamic data = jsonDecode(raw);

      dynamic ts = (data is Map<String, dynamic>)
          ? (data['photoTakenTime']?['timestamp'] ?? data['creationTime']?['timestamp'])
          : null;
      if (ts == null) return null;

      final int seconds = int.tryParse(ts.toString()) ?? 0;
      if (seconds <= 0) return null;

      // JSON timestamps are UTC; convert to local for writing.
      final DateTime utc = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
      return utc.toLocal();
    } catch (e) {
      logWarning('Late JSON date parse failed for ${file.path}: $e');
      return null;
    }
  }
}

/// Statistics about processed media collection
class ProcessingStatistics {
  const ProcessingStatistics({
    required this.totalMedia,
    required this.mediaWithDates,
    required this.mediaWithAlbums,
    required this.totalFiles,
    required this.extractionMethodDistribution,
  });

  final int totalMedia;
  final int mediaWithDates;
  final int mediaWithAlbums;
  final int totalFiles;
  final Map<DateTimeExtractionMethod, int> extractionMethodDistribution;
}
