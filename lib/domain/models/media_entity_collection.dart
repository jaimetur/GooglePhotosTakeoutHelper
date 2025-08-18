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
///
/// This replaces MediaCollection to use the new immutable MediaEntity
/// throughout the processing pipeline, providing better type safety and performance.
class MediaEntityCollection with LoggerMixin {
  MediaEntityCollection([final List<MediaEntity>? initialMedia])
      : _media = initialMedia ?? [];

  final List<MediaEntity> _media;

  /// Read-only access to the media list
  List<MediaEntity> get media => List.unmodifiable(_media);

  /// Number of media items in the collection
  int get length => _media.length;

  /// Whether the collection is empty
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;

  /// Add a single media entity to the collection
  void add(final MediaEntity mediaEntity) {
    _media.add(mediaEntity);
  }

  /// Add multiple media entities to the collection
  void addAll(final Iterable<MediaEntity> mediaEntities) {
    _media.addAll(mediaEntities);
  }

  /// Remove a media entity from the collection
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);

  /// Clear all media from the collection
  void clear() {
    _media.clear();
  }

  /// Extract dates from all media entities using configured date extractors
  ///
  /// This method applies date extraction algorithms to media entities that don't
  /// have dates, providing extraction method statistics.
  /// Uses parallel processing with ConcurrencyManager for optimal performance.
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

    logDebug(
      'Starting $maxConcurrency threads (exif date extraction concurrency)',
    );

    // Process files in parallel batches
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
              mediaFile.dateTimeExtractionMethod ??
                  DateTimeExtractionMethod.none;
          return {
            'index': actualIndex,
            'mediaFile': mediaFile,
            'extractionMethod': extractionMethod,
          };
        }

        // Try each extractor in sequence until one succeeds
        bool dateFound = false;
        MediaEntity updatedMediaFile = mediaFile;

        for (int extractorIndex = 0;
            extractorIndex < extractors.length;
            extractorIndex++) {
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

    // NEW (fast, tiny): print Step‑4 read stats (native vs exiftool, time & counts)
    // You can call this after each step (or once at the end of the whole run).
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);

    return extractionStats;
  }

  /// Write EXIF data to media files
  ///
  /// Updates EXIF metadata for media entities that have date/time information
  /// and coordinate data, tracking success statistics.
  Future<Map<String, int>> writeExifData({
    final void Function(int current, int total)? onProgress,
  }) async {
    // Check if ExifTool is available before proceeding
    final exifTool = ServiceContainer.instance.exifTool;
    if (exifTool == null) {
      logWarning('ExifTool not available, skipping EXIF data writing');
      return {'coordinatesWritten': 0, 'dateTimesWritten': 0};
    }

    logInfo('[Step 5/8] Starting EXIF data writing for ${_media.length} files');

    // Always use parallel processing for optimal performance
    return _writeExifDataParallel(onProgress, exifTool);
  }

  /// Parallel EXIF writing for improved performance
  ///
  /// Optimizations:
  ///  - Reuse a single ExifWriterService per batch.
  ///  - For non-JPEG files, combine DateTime + GPS in a single exiftool call.
  ///  - Cache headerBytes and mime types per file in the closure.
  Future<Map<String, int>> _writeExifDataParallel(
    final void Function(int current, int total)? onProgress,
    final ExifToolService exifTool,
  ) async {
    var coordinatesWritten = 0;
    var dateTimesWritten = 0;
    var completed = 0;

    // Calculate optimal concurrency
    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );

    logDebug('Starting $maxConcurrency threads (exif write concurrency)');

    // Reuse writer and coordinate extractor across the batch
    final exifWriter = ExifWriterService(exifTool);
    final coordExtractor = ExifCoordinateExtractor(exifTool);
    final globalConfig = ServiceContainer.instance.globalConfig;

    // Process files in parallel batches using the existing writer
    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final batch = _media.skip(i).take(maxConcurrency).toList();

      final futures = batch.map((final mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        // Cache MIME/header once
        final List<int> headerBytes = await file.openRead(0, 128).first;
        final String? mimeHeader =
            lookupMimeType(file.path, headerBytes: headerBytes);
        final String? mimeExt = lookupMimeType(file.path);

        var gpsWritten = false;
        var dateTimeWritten = false;

        // Collect tags to write in a single exiftool call (for non-JPEG)
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
                // Use native JPEG writer (fast path)
                final ok = await exifWriter.writeGpsToExif(
                  coordinates,
                  file,
                  globalConfig,
                );
                if (ok) gpsWritten = true;
              } else {
                // Defer to single exiftool call later
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

        // 2) DateTime if available and not originally from EXIF
        if (mediaEntity.dateTaken != null &&
            mediaEntity.dateTimeExtractionMethod !=
                DateTimeExtractionMethod.exif &&
            mediaEntity.dateTimeExtractionMethod !=
                DateTimeExtractionMethod.none) {
          if (mimeHeader == 'image/jpeg') {
            // Native JPEG writer (fast path)
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

        // 3) If there are pending tags for non-JPEG → one single exiftool call
        if (tagsToWrite.isNotEmpty) {
          // Avoid extension/content mismatch that would make exiftool fail
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
              if (tagsToWrite.length >= 4 /* 3 date fields + gps or similar */) {
                ExifWriterService.combinedTagWrites++;
              }
            }
          }
        }

        return {'gps': gpsWritten, 'dateTime': dateTimeWritten};
      });

      // Wait for all futures in this batch to complete
      final results = await Future.wait(futures);

      // Update counters
      for (final result in results) {
        if (result['gps'] == true) coordinatesWritten++;
        if (result['dateTime'] == true) dateTimesWritten++;
        completed++;
      }

      // Report progress
      onProgress?.call(completed, _media.length);
    }

    // Log final statistics
    if (coordinatesWritten > 0) {
      logInfo(
        '$coordinatesWritten files got their coordinates set in EXIF data (from json)',
      );
    }
    if (dateTimesWritten > 0) {
      logInfo('$dateTimesWritten got their DateTime set in EXIF data');
    }

    // The ExifWriterService already prints per-branch timings/counters when
    // dumpWriterStats() is called from inside the writer (keep that call wherever you added it).
    // If you want that here as well, just ensure ExifWriterService.dumpWriterStats(reset: true)
    // is invoked from your Step 5 driver code after this method returns.

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
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

  /// Get media entities as an iterable for processing
  Iterable<MediaEntity> get entities => _media;

  /// Access media entity by index
  MediaEntity operator [](final int index) => _media[index];

  /// Set media entity at index
  void operator []=(final int index, final MediaEntity mediaEntity) {
    _media[index] = mediaEntity;
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
