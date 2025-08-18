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
///
/// Step 4 (READ EXIF / Date Extraction):
///  - Uses extractor pipeline (JSON, EXIF, guess, ...).
///  - Prints ExifDateExtractor instrumentation at the end.
///
/// Step 5 (EXIF Writer):
///  - Native fast-path for JPEG.
///  - Batched exiftool writes for non-JPEG (per-file tags via -@).
///  - Prints ExifWriterService instrumentation at the end.
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
      DateTimeExtractionMethod.json,       // 0
      DateTimeExtractionMethod.exif,       // 1
      DateTimeExtractionMethod.guess,      // 2
      DateTimeExtractionMethod.jsonTryHard,// 3
      DateTimeExtractionMethod.folderYear, // 4
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
        onProgress?.call(++completed, _media.length);
      }
    }

    // Print READ-EXIF (Step 4) stats
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);

    return extractionStats;
  }

  /// Step 5: Write EXIF (optimized).
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

  /// Parallel EXIF writing with:
  ///  - Native JPEG write for speed.
  ///  - Batched exiftool writes per chunk (-@) so each file can carry unique tags.
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

      // We will collect non-JPEG tags to write via a single -@ batch per chunk.
      final perFileNonJpegTags = <File, Map<String, dynamic>>{};

      final futures = batch.map((mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        // Cache MIME information
        final headerBytes = await file.openRead(0, 128).first;
        final mimeHeader = lookupMimeType(file.path, headerBytes: headerBytes);
        final mimeExt = lookupMimeType(file.path);

        // Decide what we need to write
        final needDate = mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod != DateTimeExtractionMethod.none;

        final coords = await jsonCoordinatesExtractor(file);
        bool needGps = coords != null;

        // If EXIF already has GPS, skip GPS write
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
            // Best effort
          }
        }

        // Native fast paths for JPEG
        if (mimeHeader == 'image/jpeg') {
          bool dtW = false;
          bool gpsW = false;

          if (needDate && needGps && coords != null) {
            dtW = await exifWriter.writeDateTimeAndGpsNativeJpeg(
              file,
              mediaEntity.dateTaken!,
              coords,
            );
            gpsW = dtW;
          } else if (needDate) {
            dtW = await exifWriter.writeDateTimeNativeJpeg(
              file,
              mediaEntity.dateTaken!,
            );
          } else if (needGps && coords != null) {
            gpsW = await exifWriter.writeGpsNativeJpeg(file, coords);
          }

          return {
            'file': file,
            'dtWritten': dtW,
            'gpsWritten': gpsW,
            'nonJpegTags': <String, dynamic>{},
          };
        }

        // For non-JPEG, prepare per-file tag map to be written in a single batched call.
        final exiftoolWritable =
            !(mimeExt != mimeHeader && mimeHeader != 'image/tiff') &&
            !(mimeExt == 'video/x-msvideo' || mimeHeader == 'video/x-msvideo');

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

      // aggregate natives and collect non-Jpeg tags
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

      // single exiftool -@ batch for this chunk
      if (perFileNonJpegTags.isNotEmpty) {
        try {
          await exifWriter.writeExiftoolBatches(perFileNonJpegTags, chunkSize: 48);

          // After a successful batch, we count how many had date or gps (for totals only).
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

    // Print WRITE-EXIF (Step 5) stats
    ExifWriterService.dumpWriterStatsDetailed(reset: false, logger: this);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  // ───────────────────────── Other collection operations ─────────────────────

  /// Remove duplicates based on the duplicate detection service.
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService = ServiceContainer.instance.duplicateDetectionService;
    int removedCount = 0;

    // Group media by album association to preserve cross-album duplicates.
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

        // Prefer best date extraction quality, then shorter file names
        group.sort((a, b) {
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
        if (duplicatesToRemove.isNotEmpty) {
          final keptFile = group.first.primaryFile.path;
          logDebug('Found ${group.length} identical files, keeping: $keptFile');
          for (final dup in duplicatesToRemove) {
            logDebug('  Removing duplicate: ${dup.primaryFile.path}');
          }
        }

        entitiesToRemove.addAll(duplicatesToRemove);
        removedCount += duplicatesToRemove.length;
      }

      processed++;
      onProgress?.call(processed, totalGroups);
    }

    for (final entity in entitiesToRemove) {
      _media.remove(entity);
    }

    return removedCount;
  }

  /// Find and merge album relationships in the collection.
  Future<void> findAlbums({
    final void Function(int processed, int total)? onProgress,
  }) async {
    final albumService = ServiceContainer.instance.albumRelationshipService;

    final mediaCopy = List<MediaEntity>.from(_media);
    final merged = await albumService.detectAndMergeAlbums(mediaCopy);

    _media
      ..clear()
      ..addAll(merged);

    onProgress?.call(_media.length, _media.length);
  }

  /// Optional statistics snapshot for UI/logging.
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final distribution = <DateTimeExtractionMethod, int>{};

    for (final m in _media) {
      if (m.dateTaken != null) mediaWithDates++;
      if (m.files.hasAlbumFiles) mediaWithAlbums++;
      totalFiles += m.files.files.length;

      final method = m.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
      distribution[method] = (distribution[method] ?? 0) + 1;
    }

    return ProcessingStatistics(
      totalMedia: _media.length,
      mediaWithDates: mediaWithDates,
      mediaWithAlbums: mediaWithAlbums,
      totalFiles: totalFiles,
      extractionMethodDistribution: distribution,
    );
  }

  // Basic accessors
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
