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

  /// Also expose raw iterable used by some file operation services
  Iterable<MediaEntity> get entities => _media;

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

    // Print READ-EXIF instrumentation summary (no extra blank lines)
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

  /// Parallel EXIF writing with batching for exiftool (fast)
  ///
  /// Optimizations:
  ///  - Reuse a single ExifWriterService + ExifCoordinateExtractor
  ///  - For JPEG: native fast-path (date/gps)
  ///  - For non-JPEG: aggregate tags and call exiftool in batches (reduces calls)
  ///  - Cache MIME/header per file once
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

    // Process files in parallel windows of `maxConcurrency`,
    // but *inside* each window we will build exiftool batches for non-JPEG.
    for (int i = 0; i < _media.length; i += maxConcurrency) {
      final window = _media.skip(i).take(maxConcurrency).toList();

      // Prepare structures to accumulate non-JPEG writes for batching
      final List<MapEntry<File, Map<String, dynamic>>> batch = [];
      int windowProcessed = 0;

      // Process each file in the window
      final futures = window.map((final mediaEntity) async {
        final file = mediaEntity.files.firstFile;

        // Cache MIME/header once
        final List<int> headerBytes = await file.openRead(0, 128).first;
        final String? mimeHeader =
            lookupMimeType(file.path, headerBytes: headerBytes);
        final String? mimeExt = lookupMimeType(file.path);

        bool gpsWritten = false;
        bool dateTimeWrittenLocal = false;

        // Build up tags for exiftool (only for non-JPEG)
        final Map<String, dynamic> tagsToWrite = {};

        // 1) GPS from JSON if EXIF lacks it
        try {
          final coordinates = await jsonCoordinatesExtractor(file);
          if (coordinates != null) {
            // Check if EXIF already has GPS (fast native read or exiftool when needed)
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
                if (ok) {
                  gpsWritten = true;
                }
              } else {
                // Defer to a single exiftool batch call later
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

        // 2) DateTime if available and not taken from EXIF originally
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
            if (ok) dateTimeWrittenLocal = true;
          } else {
            final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
            final String dt = exifFormat.format(mediaEntity.dateTaken!);
            tagsToWrite['DateTimeOriginal'] = '"$dt"';
            tagsToWrite['DateTimeDigitized'] = '"$dt"';
            tagsToWrite['DateTime'] = '"$dt"';
          }
        }

        // 3) If there are pending tags for non-JPEG → queue for batch
        if (tagsToWrite.isNotEmpty) {
          // Validate file type constraints for exiftool
          if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
            logError(
              "EXIF Writer - File has a wrong extension indicating '$mimeExt' but actually is '$mimeHeader'. "
              'ExifTool would fail due to extension/content mismatch. Consider running GPTH with --fix-extensions.\n ${file.path}',
            );
          } else if (mimeExt == 'video/x-msvideo' ||
              mimeHeader == 'video/x-msvideo') {
            logWarning(
              '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
            );
          } else {
            // Accept into batch
            batch.add(MapEntry(file, tagsToWrite));
          }
        }

        // Return what was written natively in this item — the batch write is done later
        return {'gps': gpsWritten, 'dateTime': dateTimeWrittenLocal};
      });

      // Wait for window native work to finish (and batch to be built)
      final nativeResults = await Future.wait(futures);

      // Apply counters for native writes
      for (final r in nativeResults) {
        if (r['gps'] == true) coordinatesWritten++;
        if (r['dateTime'] == true) dateTimesWritten++;
        windowProcessed++;
        completed++;
        onProgress?.call(completed, _media.length);
      }

      // Now perform a **single exiftool batch** for this window (if needed)
      if (batch.isNotEmpty) {
        final sw = Stopwatch()..start();
        try {
          await exifTool.writeExifDataBatch(batch);
        } catch (e) {
          logError('ExifTool batch write failed for window starting at $i: $e');
        }
        final ms = sw.elapsedMilliseconds;

        // Update ExifWriterService global counters/timers to keep a single place for stats
        ExifWriterService.exiftoolCalls++;
        ExifWriterService.exiftoolFiles += batch.length;

        // Split per-tag grouping to fill date/gps/combined buckets
        for (final entry in batch) {
          final tags = entry.value;
          final hasDate = ExifWriterService.hasDateKeys(tags);
          final hasGps = ExifWriterService.hasGpsKeys(tags);

          if (hasDate && hasGps) {
            ExifWriterService.toolCombinedFiles++;
          } else if (hasDate) {
            ExifWriterService.toolDateFiles++;
          } else if (hasGps) {
            ExifWriterService.toolGpsFiles++;
          }
        }

        // Time attribution
        bool allDateOnly = true;
        bool allGpsOnly = true;
        for (final entry in batch) {
          final tags = entry.value;
          final hasDate = ExifWriterService.hasDateKeys(tags);
          final hasGps = ExifWriterService.hasGpsKeys(tags);
          if (!(hasDate && !hasGps)) allDateOnly = false;
          if (!(!hasDate && hasGps)) allGpsOnly = false;
        }
        if (allDateOnly) {
          ExifWriterService.toolDateMs += ms;
        } else if (allGpsOnly) {
          ExifWriterService.toolGpsMs += ms;
        } else {
          ExifWriterService.toolCombinedMs += ms;
        }

        // Apply successful results to totals (assume batch succeeded when no exception)
        for (final entry in batch) {
          final tags = entry.value;
          if (ExifWriterService.hasDateKeys(tags)) dateTimesWritten++;
          if (ExifWriterService.hasGpsKeys(tags)) coordinatesWritten++;
        }
      }
    }

    // Log final statistics for what was actually written
    if (coordinatesWritten > 0) {
      logInfo(
        '$coordinatesWritten files got their coordinates set in EXIF data (from json)',
      );
    }
    if (dateTimesWritten > 0) {
      logInfo('$dateTimesWritten got their DateTime set in EXIF data');
    }

    // Dump instrumentation from writer + extractors (single summary)
    exifWriter.dumpWriterStats(reset: true);
    ExifDateExtractor.dumpStats(reset: true, loggerMixin: this);
    ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  /// Remove duplicate media entities from the collection
  ///
  /// Uses content-based duplicate detection to identify and remove duplicate files,
  /// keeping the best version of each duplicate group.
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService =
        ServiceContainer.instance.duplicateDetectionService;
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
          final aNameLength = a.files.firstFile.path.length;
          final bNameLength = b.files.firstFile.path.length;
          return aNameLength.compareTo(bNameLength);
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

    // Remove all duplicates in a single operation to prevent race conditions
    // ignore: prefer_foreach
    for (final entityToRemove in entitiesToRemove) {
      _media.remove(entityToRemove);
    }

    return removedCount;
  }

  /// Find and merge album relationships in the collection
  ///
  /// This method detects media files that appear in multiple locations
  /// (year folders and album folders) and merges them into single entities
  /// with all file associations preserved.
  Future<void> findAlbums({
    final void Function(int processed, int total)? onProgress,
  }) async {
    final albumService = ServiceContainer.instance.albumRelationshipService;

    // Create a copy of the media list to avoid concurrent modification
    final mediaCopy = List<MediaEntity>.from(_media);

    // Get the merged results
    final mergedMedia = await albumService.detectAndMergeAlbums(mediaCopy);

    // Replace the current media list with merged results
    _media.clear();
    _media.addAll(mergedMedia);

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
