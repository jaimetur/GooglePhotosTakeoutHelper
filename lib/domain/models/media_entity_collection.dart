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
class MediaEntityCollection with LoggerMixin {
  MediaEntityCollection([final List<MediaEntity>? initialMedia])
      : _media = initialMedia ?? [];

  final List<MediaEntity> _media;

  List<MediaEntity> get media => List.unmodifiable(_media);
  int get length => _media.length;
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;

  void add(final MediaEntity mediaEntity) => _media.add(mediaEntity);
  void addAll(final Iterable<MediaEntity> mediaEntities) =>
      _media.addAll(mediaEntities);
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);
  void clear() => _media.clear();

  /// Step 4: Extract dates using provided extractors (in priority order).
  /// At the end, prints ExifDateExtractor stats in **seconds**.
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

    final maxConcurrency =
        ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif);

    logDebug(
      'Starting $maxConcurrency threads (exif date extraction concurrency)',
    );

    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();
      final batchStartIndex = i;

      final futures = batch.asMap().entries.map((final entry) async {
        final batchIndex = entry.key;
        final mediaFile = entry.value;
        final actualIndex = batchStartIndex + batchIndex;

        DateTimeExtractionMethod? extractionMethod;

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

        for (int extractorIndex = 0;
            extractorIndex < extractors.length;
            extractorIndex++) {
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

    // Print READ‑EXIF stats in seconds (native / exiftool lines separated)
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);

    return extractionStats;
  }

  /// Step 5: Write EXIF data (parallel; combines non-JPEG tags into single calls).
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

  Future<Map<String, int>> _writeExifDataParallel(
    final void Function(int current, int total)? onProgress,
    final ExifToolService exifTool,
  ) async {
    var coordinatesWritten = 0;
    var dateTimesWritten = 0;
    var completed = 0;

    final maxConcurrency =
        ConcurrencyManager().concurrencyFor(ConcurrencyOperation.exif);
    logDebug('Starting $maxConcurrency threads (exif write concurrency)');

    final exifWriter = ExifWriterService(exifTool);
    final coordExtractor = ExifCoordinateExtractor(exifTool);
    final globalConfig = ServiceContainer.instance.globalConfig;

    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();

      final futures = batch.map((final mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        final List<int> headerBytes = await file.openRead(0, 128).first;
        final String? mimeHeader =
            lookupMimeType(file.path, headerBytes: headerBytes);
        final String? mimeExt = lookupMimeType(file.path);

        var gpsWritten = false;
        var dateTimeWritten = false;

        final Map<String, dynamic> tagsToWrite = {};

        // GPS from JSON if EXIF lacks it
        try {
          final coordinates = await jsonCoordinatesExtractor(file);
          if (coordinates != null) {
            final existing = await coordExtractor.extractGPSCoordinates(
              file,
              globalConfig: globalConfig,
            );
            final hasCoords = existing != null &&
                existing['GPSLatitude'] != null &&
                existing['GPSLongitude'] != null;

            if (!hasCoords) {
              if (mimeHeader == 'image/jpeg') {
                final ok = await exifWriter.writeGpsToExif(
                  coordinates,
                  file,
                  globalConfig,
                );
                if (ok) gpsWritten = true;
              } else {
                tagsToWrite['GPSLatitude'] =
                    coordinates.toDD().latitude.toString();
                tagsToWrite['GPSLongitude'] =
                    coordinates.toDD().longitude.toString();
                tagsToWrite['GPSLatitudeRef'] =
                    coordinates.latDirection.abbreviation.toString();
                tagsToWrite['GPSLongitudeRef'] =
                    coordinates.longDirection.abbreviation.toString();
              }
            }
          }
        } catch (e) {
          logWarning(
            'Failed to extract/write GPS coordinates for ${file.path}: $e',
          );
        }

        // DateTime if available and not originally from EXIF
        if (mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod !=
                DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod !=
                DateTimeExtractionMethod.none) {
          if (mimeHeader == 'image/jpeg') {
            final ok = await exifWriter.writeDateTimeToExif(
              mediaEntity.dateTaken!,
              file,
              globalConfig,
            );
            if (ok) dateTimeWritten = true;
          } else {
            final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
            final String dt = exifFormat.format(mediaEntity.dateTaken!);
            tagsToWrite['DateTimeOriginal'] = '"$dt"';
            tagsToWrite['DateTimeDigitized'] = '"$dt"';
            tagsToWrite['DateTime'] = '"$dt"';
          }
        }

        // If there are pending tags for non-JPEG → one single exiftool call
        if (tagsToWrite.isNotEmpty) {
          if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
            logError(
              "EXIF Writer - File has a wrong extension indicating '$mimeExt' but actually is '$mimeHeader'.\n"
              'ExifTool would fail on this file due to extension/content mismatch. Consider running GPTH with --fix-extensions.\n ${file.path}',
            );
          } else if (mimeExt == 'video/x-msvideo' ||
              mimeHeader == 'video/x-msvideo') {
            logWarning(
              '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
            );
          } else {
            final ok = await exifWriter.writeTagsWithExifTool(
              file,
              tagsToWrite,
            );
            if (ok) {
              if (tagsToWrite.keys.any((k) => k.startsWith('GPS'))) {
                gpsWritten = true;
              }
              if (tagsToWrite.containsKey('DateTimeOriginal') ||
                  tagsToWrite.containsKey('DateTime')) {
                dateTimeWritten = true;
              }
              // NOTE: do NOT increment any combinedTagWrites here; the writer already counts per-branch.
            }
          }
        }

        return {'gps': gpsWritten, 'dateTime': dateTimeWritten};
      });

      final results = await Future.wait(futures);

      for (final result in results) {
        if (result['gps'] == true) coordinatesWritten++;
        if (result['dateTime'] == true) dateTimesWritten++;
        completed++;
      }

      onProgress?.call(completed, _media.length);
    }

    if (coordinatesWritten > 0) {
      logInfo(
        '$coordinatesWritten files got their coordinates set in EXIF data (from json)',
      );
    }
    if (dateTimesWritten > 0) {
      logInfo('$dateTimesWritten got their DateTime set in EXIF data');
    }

    // Dump writer + extractor stats in seconds
    exifWriter.dumpWriterStats(reset: true);
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);
    ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  /// Remove duplicates within the collection (content‑based).
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService =
        ServiceContainer.instance.duplicateDetectionService;
    int removedCount = 0;

    final albumGroups = <String?, List<MediaEntity>>{};
    for (final media in _media) {
      final albumKey = media.files.getAlbumKey();
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

        group.sort((final MediaEntity a, final MediaEntity b) {
          final aAccuracy = a.dateAccuracy?.value ?? 999;
          final bAccuracy = b.dateAccuracy?.value ?? 999;
          if (aAccuracy != bAccuracy) {
            return aAccuracy.compareTo(bAccuracy);
          }
          final aNameLength = a.files.firstFile.path.length;
          final bNameLength = b.files.firstFile.path.length;
          return aNameLength.compareTo(bNameLength);
        });

        final duplicatesToRemove = group.sublist(1);

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

    for (final entityToRemove in entitiesToRemove) {
      _media.remove(entityToRemove);
    }

    return removedCount;
  }

  /// Detect and merge album relationships.
  Future<void> findAlbums({
    final void Function(int processed, int total)? onProgress,
  }) async {
    final albumService = ServiceContainer.instance.albumRelationshipService;

    final mediaCopy = List<MediaEntity>.from(_media);
    final mergedMedia = await albumService.detectAndMergeAlbums(mediaCopy);

    _media.clear();
    _media.addAll(mergedMedia);

    onProgress?.call(_media.length, _media.length);
  }

  /// Statistics summary.
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final mediaEntity in _media) {
      if (mediaEntity.dateTaken != null) {
        mediaWithDates++;
      }
      if (mediaEntity.files.hasAlbumFiles) {
        mediaWithAlbums++;
      }
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

  Iterable<MediaEntity> get entities => _media;
  MediaEntity operator [](final int index) => _media[index];
  void operator []=(final int index, final MediaEntity mediaEntity) {
    _media[index] = mediaEntity;
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
