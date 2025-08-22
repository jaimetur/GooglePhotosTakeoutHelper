import 'dart:io';

import '../../infrastructure/exiftool_service.dart';
import '../../shared/concurrency_manager.dart';
import '../entities/media_entity.dart';
import '../services/core/logging_service.dart';
import '../services/core/service_container.dart';
import '../services/metadata/date_extraction/json_date_extractor.dart';
import '../services/metadata/exif_writer_service.dart';
import '../services/metadata/date_extraction/exif_date_extractor.dart';
import '../services/metadata/coordinate_extraction/exif_coordinate_extractor.dart';
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

  int get length => _media.length;
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;

  void add(final MediaEntity mediaEntity) => _media.add(mediaEntity);
  void addAll(final Iterable<MediaEntity> mediaEntities) => _media.addAll(mediaEntities);
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);
  void clear() => _media.clear();

  MediaEntity operator [](final int index) => _media[index];
  void operator []=(final int index, final MediaEntity mediaEntity) => _media[index] = mediaEntity;

  // ───────────────────────────────── Step 4: Extract dates ─────────────────────────────────
  Future<Map<DateTimeExtractionMethod, int>> extractDates(
    final List<Future<DateTime?> Function(MediaEntity)> extractors, {
    final void Function(int current, int total)? onProgress,
  }) async {
    final extractionStats = <DateTimeExtractionMethod, int>{};
    var completed = 0;

    final extractorMethods = [
      DateTimeExtractionMethod.json,
      DateTimeExtractionMethod.exif,
      DateTimeExtractionMethod.guess,
      DateTimeExtractionMethod.jsonTryHard,
      DateTimeExtractionMethod.folderYear,
    ];

    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );
    logDebug('Starting $maxConcurrency threads (exif date extraction concurrency)');

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
          extractionMethod =
              mediaFile.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
          return {
            'index': actualIndex,
            'mediaFile': mediaFile,
            'extractionMethod': extractionMethod,
          };
        }

        bool dateFound = false;
        MediaEntity updatedMediaFile = mediaFile;

        for (int extractorIndex = 0; extractorIndex < extractors.length; extractorIndex++) {
          final extractor = extractors[extractorIndex];
          final extractedDate = await extractor(mediaFile);

          if (extractedDate != null) {
            extractionMethod = extractorIndex < extractorMethods.length
                ? extractorMethods[extractorIndex]
                : DateTimeExtractionMethod.guess;

            updatedMediaFile = mediaFile.withDate(
              dateTaken: extractedDate,
              dateTimeExtractionMethod: extractionMethod,
            );

            logDebug(
              'Date extracted for ${mediaFile.primaryFile.path}: $extractedDate (method: ${extractionMethod.name})',
            );
            dateFound = true;
            break;
          }
        }

        if (!dateFound) {
          extractionMethod = DateTimeExtractionMethod.none;
          updatedMediaFile = mediaFile.withDate(
            dateTimeExtractionMethod: DateTimeExtractionMethod.none,
          );
          logDebug('No date found for ${mediaFile.primaryFile.path}');
        }

        return {
          'index': actualIndex,
          'mediaFile': updatedMediaFile,
          'extractionMethod': extractionMethod,
        };
      });

      final results = await Future.wait(futures);

      for (final result in results) {
        final index = result['index'] as int;
        final updatedMediaFile = result['mediaFile'] as MediaEntity;
        final method = result['extractionMethod'] as DateTimeExtractionMethod;

        _media[index] = updatedMediaFile;
        extractionStats[method] = (extractionStats[method] ?? 0) + 1;
        completed++;
      }

      onProgress?.call(completed, _media.length);
    }

    // >>> Print READ-EXIF stats summary (seconds) after step 4
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this, exiftoolFallbackEnabled: ServiceContainer.instance.globalConfig.fallbackToExifToolOnNativeMiss == true);

    return extractionStats;
  }

  // ──────────────────────────────── Step 5: Write EXIF ────────────────────────────────
  Future<Map<String, int>> writeExifData({
    final void Function(int current, int total)? onProgress,
  }) async {
    final exifTool = ServiceContainer.instance.exifTool;
    if (exifTool == null) {
      logWarning('ExifTool not available, skipping EXIF data writing');
      return {'coordinatesWritten': 0, 'dateTimesWritten': 0};
    }

    logInfo('[Step 5/8] Starting EXIF data writing for ${_media.length} files');
    return _writeExifDataParallel(onProgress, exifTool);
  }

  /// Parallel + adaptive batch strategy:
  /// - For JPEG: prefer native writes; combine Date+GPS when possible.
  /// - For non-JPEG: gather tags and batch via exiftool. Uses argfile for very large batches.
  /// - NEW: If native JPEG write fails → fall back to exiftool by enqueuing tags.
  Future<Map<String, int>> _writeExifDataParallel(
    final void Function(int current, int total)? onProgress,
    final ExifToolService exifTool,
  ) async {
    var coordinatesWritten = 0;
    var dateTimesWritten = 0;
    var completed = 0;

    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );
    logDebug('Starting $maxConcurrency threads (exif write concurrency)');

    final exifWriter = ExifWriterService(exifTool);
    final coordExtractor = ExifCoordinateExtractor(exifTool);
    final globalConfig = ServiceContainer.instance.globalConfig;

    // Adaptive batch sizing
    final bool isWindows = Platform.isWindows;
    final int baseBatchSize = isWindows ? 60 : 120;

    final List<MapEntry<File, Map<String, dynamic>>> pendingBatch = [];

    Future<void> _flushBatch({required final bool useArgFile}) async {
      if (pendingBatch.isEmpty) return;
      try {
        await exifWriter.writeBatchWithExifTool(
          pendingBatch,
          useArgFileWhenLarge: useArgFile,
        );
      } catch (e) {
        logError('Batch flush failed (${pendingBatch.length} files): $e');
      } finally {
        pendingBatch.clear();
      }
    }

    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();

      final futures = batch.map((final mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        // Cache MIME/header once
        final List<int> headerBytes = await file.openRead(0, 128).first;
        final String? mimeHeader =
            lookupMimeType(file.path, headerBytes: headerBytes);
        final String? mimeExt = lookupMimeType(file.path);

        bool gpsWritten = false;
        bool dateTimeWrittenLocal = false;

        // Accumulate tags for non-JPEG or for JPEG fallback to exiftool
        final Map<String, dynamic> tagsToWrite = {};

        // 1) GPS from JSON if EXIF lacks it
        try {
          final coordinates = await jsonCoordinatesExtractor(file);
          if (coordinates != null) {
            // Check if EXIF already has GPS
            final existing = await coordExtractor.extractGPSCoordinates(
              file,
              globalConfig: globalConfig,
            );
            final hasCoords = existing != null &&
                existing['GPSLatitude'] != null &&
                existing['GPSLongitude'] != null;

            if (!hasCoords) {
              if (mimeHeader == 'image/jpeg') {
                // If also need DateTime and it's JPEG, try native combined
                if (mediaEntity.dateTaken != null &&
                    mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
                    mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.none) {
                  final ok = await exifWriter.writeCombinedNativeJpeg(
                    file,
                    mediaEntity.dateTaken!,
                    coordinates,
                  );
                  if (ok) {
                    gpsWritten = true;
                    dateTimeWrittenLocal = true;
                  } else {
                    // Fallback to exiftool (enqueue combined tags)
                    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                    final dt = exifFormat.format(mediaEntity.dateTaken!);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    tagsToWrite['GPSLatitude'] = coordinates.toDD().latitude.toString();
                    tagsToWrite['GPSLongitude'] = coordinates.toDD().longitude.toString();
                    tagsToWrite['GPSLatitudeRef'] = coordinates.latDirection.abbreviation.toString();
                    tagsToWrite['GPSLongitudeRef'] = coordinates.longDirection.abbreviation.toString();
                    // Mark logical success; the actual write time/counters go in batch
                    gpsWritten = true;
                    dateTimeWrittenLocal = true;
                  }
                } else {
                  // Only GPS on JPEG: try native GPS write
                  final ok = await exifWriter.writeGpsNativeJpeg(file, coordinates);
                  if (ok) {
                    gpsWritten = true;
                  } else {
                    // Fallback to exiftool (enqueue GPS tags)
                    tagsToWrite['GPSLatitude'] = coordinates.toDD().latitude.toString();
                    tagsToWrite['GPSLongitude'] = coordinates.toDD().longitude.toString();
                    tagsToWrite['GPSLatitudeRef'] = coordinates.latDirection.abbreviation.toString();
                    tagsToWrite['GPSLongitudeRef'] = coordinates.longDirection.abbreviation.toString();
                    gpsWritten = true;
                  }
                }
              } else {
                // Non-JPEG → defer to exiftool
                tagsToWrite['GPSLatitude'] = coordinates.toDD().latitude.toString();
                tagsToWrite['GPSLongitude'] = coordinates.toDD().longitude.toString();
                tagsToWrite['GPSLatitudeRef'] = coordinates.latDirection.abbreviation.toString();
                tagsToWrite['GPSLongitudeRef'] = coordinates.longDirection.abbreviation.toString();
              }
            }
          }
        } catch (e) {
          logWarning('Failed to extract/write GPS for ${file.path}: $e');
        }

        // 2) DateTime if available and not originally from EXIF
        if (mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.none) {
          if (mimeHeader == 'image/jpeg') {
            if (!dateTimeWrittenLocal) {
              final ok = await exifWriter.writeDateTimeNativeJpeg(file, mediaEntity.dateTaken!);
              if (ok) {
                dateTimeWrittenLocal = true;
              } else {
                // Fallback to exiftool (enqueue DateTime tags)
                final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                final dt = exifFormat.format(mediaEntity.dateTaken!);
                tagsToWrite['DateTimeOriginal'] = '"$dt"';
                tagsToWrite['DateTimeDigitized'] = '"$dt"';
                tagsToWrite['DateTime'] = '"$dt"';
                dateTimeWrittenLocal = true;
              }
            }
          } else {
            final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
            final dt = exifFormat.format(mediaEntity.dateTaken!);
            tagsToWrite['DateTimeOriginal'] = '"$dt"';
            tagsToWrite['DateTimeDigitized'] = '"$dt"';
            tagsToWrite['DateTime'] = '"$dt"';
          }
        }

        // 3) If there are pending tags → enqueue in exiftool batch (JPEG fallback or non-JPEG)
        if (tagsToWrite.isNotEmpty) {
          // Avoid extension/content mismatch that would make exiftool fail
          if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
            logError(
              "EXIF Writer - File has a wrong extension indicating '$mimeExt' but actually is '$mimeHeader'. "
              'ExifTool would fail. Consider running --fix-extensions.\n ${file.path}',
            );
          } else if (mimeExt == 'video/x-msvideo' || mimeHeader == 'video/x-msvideo') {
            logWarning('Skipping AVI file - ExifTool cannot write RIFF AVI: ${file.path}');
          } else {
            pendingBatch.add(MapEntry(file, tagsToWrite));

            // Rough estimate of command “weight”: 1 per tag + file path
            final int weight = tagsToWrite.length + 1;
            final int targetBatch = weight > 6 ? (baseBatchSize ~/ 2) : baseBatchSize;

            // Flush with argfile if the batch is big/heavy
            if (pendingBatch.length >= targetBatch) {
              await _flushBatch(useArgFile: true);
            }
          }
        }

        return {'gps': gpsWritten, 'dateTime': dateTimeWrittenLocal};
      });

      final results = await Future.wait(futures);

      for (final result in results) {
        if (result['gps'] == true) coordinatesWritten++;
        if (result['dateTime'] == true) dateTimesWritten++;
        completed++;
      }

      onProgress?.call(completed, _media.length);
    }

    // Flush any remaining pending exiftool batch (argfile if large)
    final bool flushWithArgfile = pendingBatch.length > (Platform.isWindows ? 30 : 60);
    await _flushBatch(useArgFile: flushWithArgfile);

    if (coordinatesWritten > 0) {
      logInfo('$coordinatesWritten files got GPS set in EXIF data');
    }
    if (dateTimesWritten > 0) {
      logInfo('$dateTimesWritten files got DateTime set in EXIF data');
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

  // ─────────────────────────── Remove duplicates ────────────────────────────
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService = ServiceContainer.instance.duplicateDetectionService;
    int removedCount = 0;

    // Group media by album association first to preserve cross-album duplicates
    final albumGroups = <String?, List<MediaEntity>>{};
    for (final media in _media) {
      final albumKey = media.files.getAlbumKey(); // null for year folders
      albumGroups.putIfAbsent(albumKey, () => []).add(media);
    }

    final entitiesToRemove = <MediaEntity>[];
    int processed = 0;
    final totalGroups = albumGroups.length;

    for (final albumGroup in albumGroups.values) {
      if (albumGroup.length <= 1) {
        processed++;
        onProgress?.call(processed, totalGroups);
        continue;
      }

      final hashGroups = await duplicateService.groupIdentical(albumGroup);

      for (final group in hashGroups.values) {
        if (group.length <= 1) continue;

        // Sort by best date extraction quality, then file name length
        group.sort((final MediaEntity a, final MediaEntity b) {
          final aAccuracy = a.dateAccuracy?.value ?? 999;
          final bAccuracy = b.dateAccuracy?.value ?? 999;
          if (aAccuracy != bAccuracy) {
            return aAccuracy.compareTo(bAccuracy);
          }
          final aLen = a.files.firstFile.path.length;
          final bLen = b.files.firstFile.path.length;
          return aLen.compareTo(bLen);
        });

        final duplicatesToRemove = group.sublist(1);
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

  // ──────────────────────────────── Find albums ───────────────────────────────
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

  // ────────────────────────────── Collection stats ─────────────────────────────
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final mediaEntity in _media) {
      if (mediaEntity.dateTaken != null) mediaWithDates++;
      if (mediaEntity.files.hasAlbumFiles) mediaWithAlbums++;
      totalFiles += mediaEntity.files.files.length;

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
}

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
