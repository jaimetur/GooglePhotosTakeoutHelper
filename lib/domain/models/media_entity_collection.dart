// FILE: lib/domain/models/media_entity_collection.dart
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

/// Modern domain model representing a collection of media entities
class MediaEntityCollection with LoggerMixin {
  MediaEntityCollection([final List<MediaEntity>? initialMedia])
      : _media = initialMedia ?? [];

  final List<MediaEntity> _media;

  // Accessors
  List<MediaEntity> get media => List.unmodifiable(_media);
  int get length => _media.length;
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;
  Iterable<MediaEntity> get entities => _media;

  void add(final MediaEntity mediaEntity) => _media.add(mediaEntity);
  void addAll(final Iterable<MediaEntity> mediaEntities) =>
      _media.addAll(mediaEntities);
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);
  void clear() => _media.clear();

  /// Step 4: Extract dates using provided extractors (parallelized).
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

    // Process batches in parallel windows
    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();
      final batchStartIndex = i;

      final futures = batch.asMap().entries.map((entry) async {
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
        MediaEntity updated = mediaFile;

        for (int extractorIndex = 0;
            extractorIndex < extractors.length;
            extractorIndex++) {
          final extractor = extractors[extractorIndex];
          final extractedDate = await extractor(mediaFile);

          if (extractedDate != null) {
            extractionMethod = extractorIndex < extractorMethods.length
                ? extractorMethods[extractorIndex]
                : DateTimeExtractionMethod.guess;

            updated = mediaFile.withDate(
              dateTaken: extractedDate,
              dateTimeExtractionMethod: extractionMethod,
            );
            dateFound = true;
            break;
          }
        }

        if (!dateFound) {
          extractionMethod = DateTimeExtractionMethod.none;
          updated = mediaFile.withDate(
            dateTimeExtractionMethod: DateTimeExtractionMethod.none,
          );
        }

        return {
          'index': actualIndex,
          'mediaFile': updated,
          'extractionMethod': extractionMethod,
        };
      });

      final results = await Future.wait(futures);
      for (final result in results) {
        final index = result['index'] as int;
        final updated = result['mediaFile'] as MediaEntity;
        final method = result['extractionMethod'] as DateTimeExtractionMethod;

        _media[index] = updated;
        extractionStats[method] = (extractionStats[method] ?? 0) + 1;
        completed++;
      }
      onProgress?.call(completed, _media.length);
    }

    // Dump Step 4 instrumentation (no blank lines)
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);

    return extractionStats;
  }

  /// Step 5: Write EXIF data (batching + native fast path for JPEG)
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

    // Accumulate non-JPEG tag writes and flush in batches
    final batch = <MapEntry<File, Map<String, dynamic>>>[];
    const int BATCH_SIZE = 180;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final ok = await exifWriter.writeTagsBatchWithExifTool(
        List<MapEntry<File, Map<String, dynamic>>>.from(batch),
        useArgFile: true,
      );
      if (ok) {
        for (final e in batch) {
          final tags = e.value;
          if (ExifWriterService.hasDateKeys(tags)) dateTimesWritten++;
          if (ExifWriterService.hasGpsKeys(tags)) coordinatesWritten++;
        }
      }
      batch.clear();
    }

    // Process files in parallel windows for read/decision; do writes (native/batch) inside
    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final window = _media.skip(i).take(maxConcurrency).toList();

      final tasks = window.map((mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        // MIME sniff once
        final headerBytes = await file.openRead(0, 128).first;
        final mimeHeader = lookupMimeType(file.path, headerBytes: headerBytes);
        final mimeExt = lookupMimeType(file.path);

        // Collect tags for non-JPEG in a single map
        final tagsToWrite = <String, dynamic>{};

        // GPS from JSON if EXIF lacks it
        try {
          final coords = await jsonCoordinatesExtractor(file);
          if (coords != null) {
            final existing = await coordExtractor.extractGPSCoordinates(
              file,
              globalConfig: globalConfig,
            );
            final hasCoords = existing != null &&
                existing['GPSLatitude'] != null &&
                existing['GPSLongitude'] != null;

            if (!hasCoords) {
              if (mimeHeader == 'image/jpeg') {
                final sw = Stopwatch()..start();
                final ok = await exifWriter.writeGpsNativeJpeg(file, coords);
                ExifWriterService.nativeGpsMs += sw.elapsedMilliseconds;
                if (ok) {
                  ExifWriterService.nativeJpegGpsWrites++;
                  coordinatesWritten++;
                }
              } else {
                tagsToWrite['GPSLatitude'] =
                    coords.toDD().latitude.toString();
                tagsToWrite['GPSLongitude'] =
                    coords.toDD().longitude.toString();
                tagsToWrite['GPSLatitudeRef'] =
                    coords.latDirection.abbreviation.toString();
                tagsToWrite['GPSLongitudeRef'] =
                    coords.longDirection.abbreviation.toString();
              }
            }
          }
        } catch (e) {
          logWarning('Failed to extract/write GPS for ${file.path}: $e');
        }

        // DateTime if present and not from EXIF originally
        if (mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod !=
                DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod !=
                DateTimeExtractionMethod.none) {
          if (mimeHeader == 'image/jpeg') {
            final sw = Stopwatch()..start();
            final ok = await exifWriter.writeDateTimeNativeJpeg(
              file,
              mediaEntity.dateTaken!,
            );
            ExifWriterService.nativeDateMs += sw.elapsedMilliseconds;
            if (ok) {
              ExifWriterService.nativeJpegDateWrites++;
              dateTimesWritten++;
            }
          } else {
            final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
            final s = fmt.format(mediaEntity.dateTaken!);
            tagsToWrite['DateTimeOriginal'] = '"$s"';
            tagsToWrite['DateTimeDigitized'] = '"$s"';
            tagsToWrite['DateTime'] = '"$s"';
          }
        }

        // If non-JPEG pending tags → validate and push to batch
        if (tagsToWrite.isNotEmpty) {
          if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
            logError(
              "EXIF Writer - Wrong extension '$mimeExt' vs actual '$mimeHeader'. "
              'ExifTool would fail. Consider --fix-extensions. ${file.path}',
            );
          } else if (mimeExt == 'video/x-msvideo' ||
              mimeHeader == 'video/x-msvideo') {
            logWarning(
              'Skipping AVI (RIFF) write: ${file.path}',
            );
          } else {
            batch.add(MapEntry(file, tagsToWrite));
            if (batch.length >= BATCH_SIZE) {
              await flush();
            }
          }
        }
      });

      await Future.wait(tasks);
      completed += window.length;
      onProgress?.call(completed, _media.length);
    }

    // Flush remaining
    await flush();

    // Step 5 summaries (no blank lines)
    exifWriter.dumpWriterStats(reset: true);
    ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  /// Duplicate removal (kept from previous versions)
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService =
        ServiceContainer.instance.duplicateDetectionService;
    int removedCount = 0;

    final albumGroups = <String?, List<MediaEntity>>{};
    for (final m in _media) {
      final albumKey = m.files.getAlbumKey();
      albumGroups.putIfAbsent(albumKey, () => []).add(m);
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

        group.sort((a, b) {
          final aAcc = a.dateAccuracy?.value ?? 999;
          final bAcc = b.dateAccuracy?.value ?? 999;
          if (aAcc != bAcc) return aAcc.compareTo(bAcc);
          final aNameLen = a.files.firstFile.path.length;
          final bNameLen = b.files.firstFile.path.length;
          return aNameLen.compareTo(bNameLen);
        });

        final toRemove = group.sublist(1);
        entitiesToRemove.addAll(toRemove);
        removedCount += toRemove.length;
      }

      processed++;
      onProgress?.call(processed, totalGroups);
    }

    for (final e in entitiesToRemove) {
      _media.remove(e);
    }

    return removedCount;
  }

  /// Album relationship detection/merge
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

  // Read-only stats summary for callers
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final m in _media) {
      if (m.dateTaken != null) mediaWithDates++;
      if (m.files.hasAlbumFiles) mediaWithAlbums++;
      totalFiles += m.files.files.length;

      final method = m.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
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
