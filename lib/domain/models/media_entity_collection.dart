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
  void addAll(final Iterable<MediaEntity> mediaEntities) => _media.addAll(mediaEntities);
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);
  void clear() => _media.clear();

  /// Step 4: Extract dates using configured extractors (parallelized).
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

    return extractionStats;
  }

  /// Step 5: Write EXIF data (parallel + exiftool batching).
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

  /// Parallel + batch strategy:
  /// - For JPEG: prefer native writes; combine Date+GPS when possible.
  /// - For non-JPEG: gather tags and batch via exiftool in groups to reduce process invocations.
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

    // We'll accumulate exiftool writes for non-JPEG into batches of fixed size.
    const int BATCH_SIZE = 100;
    final List<MapEntry<File, Map<String, dynamic>>> pendingBatch = [];

    Future<void> _flushBatch() async {
      if (pendingBatch.isEmpty) return;
      try {
        await exifWriter.writeBatchWithExifTool(pendingBatch);
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

        // Accumulate tags for non-JPEG single exiftool call
        final Map<String, dynamic> tagsToWrite = {};

        // Extract GPS from JSON and check if EXIF already has it
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
              if (mimeHeader == 'image/jpeg' && mediaEntity.dateTaken != null) {
                // If we also need DateTime and it's JPEG, try native combined
                if (mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
                    mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.none) {
                  final ok = await exifWriter.writeCombinedNativeJpeg(
                      file, mediaEntity.dateTaken!, coordinates);
                  if (ok) {
                    gpsWritten = true;
                    dateTimeWrittenLocal = true;
                    return {'gps': gpsWritten, 'dateTime': dateTimeWrittenLocal};
                  }
                }
              }

              if (mimeHeader == 'image/jpeg') {
                final ok = await exifWriter.writeGpsNativeJpeg(file, coordinates);
                if (ok) gpsWritten = true;
              } else {
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

        // DateTime if available and not originally from EXIF
        if (mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.none) {
          if (mimeHeader == 'image/jpeg') {
            if (!gpsWritten) {
              final ok = await exifWriter.writeDateTimeNativeJpeg(file, mediaEntity.dateTaken!);
              if (ok) dateTimeWrittenLocal = true;
            }
          } else {
            final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
            final dt = exifFormat.format(mediaEntity.dateTaken!);
            tagsToWrite['DateTimeOriginal'] = '"$dt"';
            tagsToWrite['DateTimeDigitized'] = '"$dt"';
            tagsToWrite['DateTime'] = '"$dt"';
          }
        }

        // Push a non-JPEG task to the batch if needed
        if (tagsToWrite.isNotEmpty) {
          if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
            logError(
              "EXIF Writer - File has a wrong extension indicating '$mimeExt' but actually is '$mimeHeader'. "
              'ExifTool would fail. Consider running --fix-extensions.\n ${file.path}',
            );
          } else if (mimeExt == 'video/x-msvideo' || mimeHeader == 'video/x-msvideo') {
            logWarning(
              'Skipping AVI file - ExifTool cannot write RIFF AVI: ${file.path}',
            );
          } else {
            pendingBatch.add(MapEntry(file, tagsToWrite));
            if (pendingBatch.length >= BATCH_SIZE) {
              await _flushBatch();
            }
            // Mark as written for counts; actual write occurs at flush
            final hasDate = tagsToWrite.containsKey('DateTimeOriginal') ||
                tagsToWrite.containsKey('DateTime');
            final hasGps = tagsToWrite.keys.any((k) => k.startsWith('GPS'));
            if (hasDate) dateTimeWrittenLocal = true;
            if (hasGps) gpsWritten = true;
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

    // Flush any remaining pending exiftool batch
    await _flushBatch();

    if (coordinatesWritten > 0) {
      logInfo('$coordinatesWritten files got GPS set in EXIF data');
    }
    if (dateTimesWritten > 0) {
      logInfo('$dateTimesWritten files got DateTime set in EXIF data');
    }

    // Final writer stats in seconds (no READ-EXIF lines here)
    ExifWriterService.dumpWriterStats(reset: true, logger: this);
    // Coordinate extractor stats (includes GPS extraction timings)
    ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  // (Other collection utilities like removeDuplicates/findAlbums stay as-is in your tree)
}
