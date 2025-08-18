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
import 'package:mime/mime.dart';

/// Modern domain model representing a collection of media entities.
///
/// Step 4 (READ EXIF / Date Extraction):
///   - Uses extractor pipeline (JSON, EXIF, guess, etc.)
///   - At the end, prints ExifDateExtractor instrumentation summary
///
/// Step 5 (EXIF Writer):
///   - Native fast path for JPEG
///   - Batched ExifTool writes for non-JPEG
///   - At the end, prints writer instrumentation summary
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

  /// Step 4: Extract dates using configured extractors.
  /// Prints a compact summary of EXIF read instrumentation at the end.
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

      final futures = batch.asMap().entries.map((entry) async {
        final idx = entry.key;
        final mediaFile = entry.value;
        final actualIndex = batchStartIndex + idx;

        DateTimeExtractionMethod? extractionMethod;

        // If already has date, keep method or mark none
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
              'Date extracted for ${mediaFile.primaryFile.path}: '
              '$extractedDate (method: ${extractionMethod.name})',
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
        onProgress?.call(++completed, _media.length);
      }
    }

    // Print EXIF read instrumentation summary (always prints; not gated by verbose).
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);

    return extractionStats;
  }

  /// Step 5: Write EXIF data (optimized). See writer service for instrumentation.
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

    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );

    logDebug('Starting $maxConcurrency threads (exif write concurrency)');

    final exifWriter = ExifWriterService(exifTool);
    final coordExtractor = ExifCoordinateExtractor(exifTool);
    final globalConfig = ServiceContainer.instance.globalConfig;

    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();

      final perFileNonJpegTags = <File, Map<String, dynamic>>{};

      final futures = batch.map((mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        final header = await file.openRead(0, 128).first;
        final mimeHeader = lookupMimeType(file.path, headerBytes: header);
        final mimeExt = lookupMimeType(file.path);

        final needDate = mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.none;

        final coords = await jsonCoordinatesExtractor(file);
        bool needGps = coords != null;

        final exiftoolWritable =
            !(mimeExt != mimeHeader && mimeHeader != 'image/tiff') &&
            !(mimeExt == 'video/x-msvideo' || mimeHeader == 'video/x-msvideo');

        if (needGps) {
          try {
            final existing = await coordExtractor.extractGPSCoordinates(
              file,
              globalConfig: globalConfig,
            );
            final hasCoords = existing != null &&
                existing['GPSLatitude'] != null &&
                existing['GPSLongitude'] != null;
            if (hasCoords) {
              needGps = false;
            }
          } catch (_) {
            // Best-effort; proceed to write if needed
          }
        }

        bool dtWritten = false;
        bool gpsWritten = false;

        if (mimeHeader == 'image/jpeg') {
          if (needDate && needGps && coords != null) {
            final ok = await exifWriter.writeDateTimeAndGpsNativeJpeg(
              file,
              mediaEntity.dateTaken!,
              coords,
            );
            if (ok) {
              dtWritten = true;
              gpsWritten = true;
            }
          } else if (needDate) {
            final ok = await exifWriter.writeDateTimeNativeJpeg(
              file,
              mediaEntity.dateTaken!,
            );
            if (ok) dtWritten = true;
          } else if (needGps && coords != null) {
            final ok = await exifWriter.writeGpsNativeJpeg(
              file,
              coords,
            );
            if (ok) gpsWritten = true;
          }

          return {
            'file': file,
            'dtWritten': dtWritten,
            'gpsWritten': gpsWritten,
            'nonJpegTags': <String, dynamic>{},
          };
        }

        final tags = <String, dynamic>{};
        if (needDate) {
          tags.addAll(ExifWriterService.buildDateTags(mediaEntity.dateTaken!));
        }
        if (needGps && coords != null) {
          tags.addAll(ExifWriterService.buildGpsTags(coords));
        }

        if (tags.isNotEmpty && exiftoolWritable) {
          return {
            'file': file,
            'dtWritten': false,
            'gpsWritten': false,
            'nonJpegTags': tags,
          };
        }

        return {
          'file': file,
          'dtWritten': false,
          'gpsWritten': false,
          'nonJpegTags': <String, dynamic>{},
        };
      });

      final results = await Future.wait(futures);

      for (final r in results) {
        final file = r['file'] as File;
        final tags = (r['nonJpegTags'] as Map<String, dynamic>);
        if (tags.isNotEmpty) {
          perFileNonJpegTags[file] = tags;
        }
        if (r['dtWritten'] == true) dateTimesWritten++;
        if (r['gpsWritten'] == true) coordinatesWritten++;
        completed++;
      }

      if (perFileNonJpegTags.isNotEmpty) {
        try {
          await exifWriter.writeExiftoolBatches(perFileNonJpegTags, chunkSize: 48);

          perFileNonJpegTags.forEach((_, tags) {
            final hasDate = ExifWriterService._hasDateKeys(tags);
            final hasGps = ExifWriterService._hasGpsKeys(tags);
            if (hasDate) dateTimesWritten++;
            if (hasGps) coordinatesWritten++;
          });
        } catch (e) {
          logWarning('Batch EXIF write encountered issues: $e');
        }
      }

      onProgress?.call(completed, _media.length);
    }

    // Writer instrumentation: print at end of Step 5
    ExifWriterService(null as ExifToolService) // not used; just to call the static printer
        .dumpWriterStatsDetailed(reset: false);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  Iterable<MediaEntity> get entities => _media;
  MediaEntity operator [](final int index) => _media[index];
  void operator []=(final int index, final MediaEntity mediaEntity) {
    _media[index] = mediaEntity;
  }
}
