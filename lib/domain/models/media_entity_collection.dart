import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../infrastructure/exiftool_service.dart';
import '../../shared/concurrency_manager.dart';
import '../entities/media_entity.dart';
import '../services/core/logging_service.dart';
import '../services/core/service_container.dart';
import '../services/metadata/coordinate_extraction/exif_coordinate_extractor.dart';
import '../services/metadata/date_extraction/exif_date_extractor.dart';
import '../services/metadata/date_extraction/json_date_extractor.dart';
import '../services/metadata/exif_writer_service.dart';
import '../services/metadata/json_metadata_matcher_service.dart';
import '../value_objects/date_time_extraction_method.dart';

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
  void addAll(final Iterable<MediaEntity> mediaEntities) =>
      _media.addAll(mediaEntities);
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);
  void clear() => _media.clear();

  MediaEntity operator [](final int index) => _media[index];
  void operator []=(final int index, final MediaEntity mediaEntity) =>
      _media[index] = mediaEntity;

  // ─────────────────────────── Step 3: Remove duplicates ────────────────────────────
  /// Uses content-based duplicate detection to identify and remove duplicate entities
  /// across the whole collection (cross-album included), keeping the best entity of each
  /// duplicate group and **merging all file associations** (album/year files) into it.
  ///
  /// This ensures Step 7 can place the kept media into every album it belonged to.
  Future<int> removeDuplicates({
    final void Function(int current, int total)? onProgress,
  }) async {
    if (_media.isEmpty) return 0;

    final duplicateService =
        ServiceContainer.instance.duplicateDetectionService;
    int removedCount = 0;

    // Global duplicate grouping (no album partition → cross-album dedupe)
    // OPTIMIZATION LAYER 1: pre-bucket by primary file size to reduce candidate set per call.
    final Map<int, List<MediaEntity>> sizeBuckets = {};
    for (final e in _media) {
      int size;
      try {
        size = e.primaryFile.lengthSync();
      } catch (_) {
        size = -1; // unknown size bucket
      }
      (sizeBuckets[size] ??= []).add(e);
    }
    final List<int> bucketKeys = sizeBuckets.keys.toList();

    // We will report progress per processed size-bucket.
    final totalGroups = bucketKeys.length;
    int processedGroups = 0;

    // Collect entities to remove and do a single removeWhere at the end (avoid O(n^2) removes).
    final Set<MediaEntity> entitiesToRemove = <MediaEntity>{};

    // Helper: merge all files from 'src' entity into 'dst' entity.
    // It unions physical file references (including album files), avoiding duplicates by path.
    void mergeEntityFiles(final MediaEntity dst, final MediaEntity src) {
      try {
        // Build a fast lookup of already present paths to get O(1) membership checks.
        final Set<String> existing = {
          for (final f in dst.files.files.values) f.path,
        };

        // Primary first to preserve deterministic order in dst
        final File srcPrimary = src.primaryFile;
        if (!existing.contains(srcPrimary.path)) {
          dst.files.files.putIfAbsent(srcPrimary.path, () => srcPrimary);
          existing.add(srcPrimary.path);
        }

        // Insert the rest of the files (album/year secondary files)
        for (final f in src.files.files.values) {
          final String p = f.path;
          if (!existing.contains(p)) {
            dst.files.files.putIfAbsent(p, () => f);
            existing.add(p);
          }
        }
      } catch (e) {
        logWarning('Failed to merge files from duplicate entity: $e');
      }
    }

    // Helper: get lowercase extension from a path (no external deps).
    String extOf(final String path) {
      final int slash = path.lastIndexOf(Platform.pathSeparator);
      final String base = (slash >= 0) ? path.substring(slash + 1) : path;
      final int dot = base.lastIndexOf('.');
      if (dot <= 0) return ''; // no ext or hidden file like ".gitignore"
      return base.substring(dot + 1).toLowerCase();
    }

    // Helper: quick signature using size + extension + FNV-1a32 of first up-to-64KB.
    Future<String> quickSignature(
      final File file,
      final int size,
      final String ext,
    ) async {
      // Read first up-to-64KB deterministically. If file shorter, read all.
      final int toRead = size > 0 ? (size < 65536 ? size : 65536) : 65536;
      List<int> head = const [];
      try {
        final raf = await file.open();
        try {
          head = await raf.read(toRead);
        } finally {
          await raf.close();
        }
      } catch (_) {
        head = const [];
      }

      // FNV-1a 32-bit
      int hash = 0x811C9DC5;
      for (final b in head) {
        hash ^= b & 0xFF;
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
      }
      // A string signature that keeps groups small but collision-safe thanks to later full check.
      return '$size|$ext|$hash';
    }

    // Process one size bucket: ext sub-buckets → quickSig sub-buckets → groupIdentical
    Future<void> processSizeBucket(final int key) async {
      final List<MediaEntity> candidates = sizeBuckets[key]!;
      if (candidates.length <= 1) return;

      // OPTIMIZATION LAYER 2: sub-bucket by extension to avoid mixing media types of same size.
      final Map<String, List<MediaEntity>> extBuckets = {};
      for (final e in candidates) {
        final String ext = extOf(e.primaryFile.path);
        (extBuckets[ext] ??= []).add(e);
      }

      for (final entry in extBuckets.entries) {
        final List<MediaEntity> extGroup = entry.value;
        if (extGroup.length <= 1) continue;

        // OPTIMIZATION LAYER 3: quick signature to split large groups cheaply.
        final Map<String, List<MediaEntity>> quickBuckets = {};
        for (final e in extGroup) {
          String sig;
          try {
            final int size = e.primaryFile.lengthSync();
            final String ext = extOf(e.primaryFile.path);
            sig = await quickSignature(e.primaryFile, size, ext);
          } catch (_) {
            sig = 'qsig-err';
          }
          (quickBuckets[sig] ??= []).add(e);
        }

        // Verify duplicates only inside the tiny quick-buckets.
        for (final q in quickBuckets.values) {
          if (q.length <= 1) continue;

          final hashGroups = await duplicateService.groupIdentical(q);

          for (final group in hashGroups.values) {
            if (group.length <= 1) continue;

            // Sort by best date extraction quality, then shortest file name (primary file path length)
            group.sort((final MediaEntity a, final MediaEntity b) {
              final aAccuracy = a.dateAccuracy?.value ?? 999;
              final bAccuracy = b.dateAccuracy?.value ?? 999;
              if (aAccuracy != bAccuracy) return aAccuracy.compareTo(bAccuracy);
              final aLen = a.primaryFile.path.length;
              final bLen = b.primaryFile.path.length;
              return aLen.compareTo(bLen);
            });

            final MediaEntity kept = group.first;
            final List<MediaEntity> toRemove = group.sublist(1);

            // Log which duplicates are being removed (keep noise low implicitly).
            logDebug(
              'Found ${group.length} identical entities. Keeping: ${kept.primaryFile.path}',
            );
            for (final d in toRemove) {
              logDebug(
                '  Merging & removing duplicate entity: ${d.primaryFile.path}',
              );
              mergeEntityFiles(kept, d);
            }

            // Mark for removal (do not remove from _media here).
            entitiesToRemove.addAll(toRemove);
            removedCount += toRemove.length;
          }
        }
      }
    }

    // Concurrency: process size buckets in parallel with a sensible cap.
    final int maxWorkers = ConcurrencyManager()
        .concurrencyFor(ConcurrencyOperation.exif)
        .clamp(1, 8);
    for (int i = 0; i < bucketKeys.length; i += maxWorkers) {
      final slice = bucketKeys.skip(i).take(maxWorkers).toList();
      await Future.wait(slice.map(processSizeBucket));
      processedGroups += slice.length;
      onProgress?.call(processedGroups, totalGroups);
    }

    // Apply removals in one pass (fast).
    if (entitiesToRemove.isNotEmpty) {
      _media.removeWhere(entitiesToRemove.contains);
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
      DateTimeExtractionMethod
          .jsonTryHard, // JSON tryhard extractor (last resort)
      DateTimeExtractionMethod.folderYear, // Folder year extractor (fallback)
    ];

    // Get optimal concurrency for EXIF operations using ConcurrencyManager
    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );
    print(
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

        for (
          int extractorIndex = 0;
          extractorIndex < extractors.length;
          extractorIndex++
        ) {
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
    ExifDateExtractor.dumpStats(
      reset: true,
      loggerMixin: this,
      exiftoolFallbackEnabled:
          ServiceContainer
              .instance
              .globalConfig
              .fallbackToExifToolOnNativeMiss ==
          true,
    );

    return extractionStats;
  }

  // ──────────────────────────────── Step 5: Write EXIF ────────────────────────────────
  /// Updates EXIF metadata for media entities that have date/time information
  /// and coordinate data, tracking success statistics.
  Future<Map<String, int>> writeExifData({
    final void Function(int current, int total)? onProgress,
    final bool exifToolBatching =
        true, // Change to false if you observe any date discrepancy on your output files
  }) async {
    // Check if ExifTool is available before proceeding
    final exifTool = ServiceContainer.instance.exifTool;

    if (exifTool == null) {
      logWarning(
        '[Step 5/8] ExifTool not available, writing EXIF data for native supported files only...',
      );
      print(
        '[Step 5/8] Starting EXIF data writing (native-only, no ExifTool) for ${_media.length} files',
      );
      // No exiftool: fall back to native-only and no batching
      return _writeExifDataParallel(
        onProgress,
        null,
        nativeOnly: true,
        enableExifToolBatch: false,
      );
    }

    // Always use parallel processing for optimal performance
    return _writeExifDataParallel(
      onProgress,
      exifTool,
      // ignore: avoid_redundant_argument_values
      nativeOnly: false,
      enableExifToolBatch: exifToolBatching,
    );
  }

  /// Parallel + adaptive batch strategy:
  /// - Native writer for JPEG is allowed regardless of batching (legacy behavior preserved).
  /// - ExifTool per-file or batched is used for non-JPEG and as fallback when native fails.
  /// - Multi-file entities are processed first; flushing is delayed until that phase ends
  ///   so all files from the same entity land in the same ExifTool batch.
  /// - Each future processes an entire entity to keep progress in terms of entities.
  Future<Map<String, int>> _writeExifDataParallel(
    final void Function(int current, int total)? onProgress,
    final ExifToolService? exifTool, {
    final bool nativeOnly = false,
    final bool enableExifToolBatch = true,
  }) async {
    var coordinatesWritten = 0;
    var dateTimesWritten = 0;
    var completed = 0;

    if (nativeOnly) {
      logInfo(
        'Exiftool disabled using argument nativeOnly=true',
        forcePrint: true,
      );
    } else {
      logInfo(
        'Exiftool enabled using argument nativeOnly=false',
        forcePrint: true,
      );
    }

    if (enableExifToolBatch) {
      logInfo(
        'Exiftool batch enabled using argument enableExifToolBatch=true. Exiftool will be called in batches with several files per batch',
        forcePrint: true,
      );
    } else {
      logInfo(
        'Exiftool batch processing disabled using argument enableExifToolBatch=false. Exiftool will be called 1 time per file',
        forcePrint: true,
      );
    }

    // Calculate optimal concurrency
    final maxConcurrency = ConcurrencyManager().concurrencyFor(
      ConcurrencyOperation.exif,
    );

    // Reuse writer and coordinate extractor across the batch
    final ExifWriterService? exifWriter = (exifTool != null)
        ? ExifWriterService(exifTool)
        : null;
    // final coordExtractor = exifTool != null ? ExifCoordinateExtractor(exifTool) : null;
    // final globalConfig = ServiceContainer.instance.globalConfig;

    // Adaptive batch sizing
    final bool isWindows = Platform.isWindows;
    final int baseBatchSize = isWindows ? 60 : 120;

    // Two separated queues: images and videos
    final List<MapEntry<File, Map<String, dynamic>>> pendingImagesBatch = [];
    final List<MapEntry<File, Map<String, dynamic>>> pendingVideosBatch = [];

    Future<void> flushBatchGeneric(
      final List<MapEntry<File, Map<String, dynamic>>> queue, {
      required final bool useArgFile,
      required final bool isVideoBatch,
    }) async {
      if (nativeOnly || !enableExifToolBatch) {
        return; // no batches in per-file mode
      }
      if (queue.isEmpty) return;
      if (exifWriter == null) {
        queue.clear();
        return;
      }

      // Pre-clean *_exiftool_tmp
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

      // Attempt 1: batch
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

        // Retry per-file so nothing is lost
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
    Future<void> flushImageBatch({required final bool useArgFile}) =>
        flushBatchGeneric(
          pendingImagesBatch,
          useArgFile: useArgFile,
          isVideoBatch: false,
        );

    Future<void> flushVideoBatch({required final bool useArgFile}) =>
        flushBatchGeneric(
          pendingVideosBatch,
          useArgFile: useArgFile,
          isVideoBatch: true,
        );

    // Build processing order: multi-file entities first (pre-batch), then single-file entities
    final List<MediaEntity> multiFileEntities = [];
    final List<MediaEntity> singleFileEntities = [];
    for (final e in _media) {
      final int fileCount = e.files.files.length;
      if (fileCount > 1) {
        multiFileEntities.add(e);
      } else {
        singleFileEntities.add(e);
      }
    }

    // Process one list of entities, optionally delaying batch flushing until the end.
    Future<void> processEntityList(
      final List<MediaEntity> list, {
      required final bool delayFlushUntilEnd,
    }) async {
      for (int i = 0; i < list.length; i += maxConcurrency) {
        final batchEntities = list.skip(i).take(maxConcurrency).toList();

        // Each future processes one entity (all its files)
        final futures = batchEntities.map((final mediaEntity) async {
          int localGps = 0;
          int localDate = 0;

          try {
            // Determine entity-wide effective date (JSON preferred)
            DateTime? entityEffectiveDate;
            try {
              final File primary = mediaEntity.primaryFile;
              final DateTime? jsonDate = await _lateResolveDateFromJson(
                primary,
              );
              if (jsonDate != null) {
                entityEffectiveDate = jsonDate;
                logDebug(
                  'JSON sidecar date (entity-level) will be used for ${primary.path}: $entityEffectiveDate',
                );
              } else {
                entityEffectiveDate = mediaEntity.dateTaken;
              }
            } catch (_) {
              entityEffectiveDate = mediaEntity.dateTaken;
            }

            // Build file list: primary first, then the rest (deterministic order)
            final List<File> filesInEntity = [];
            try {
              final File primary = mediaEntity.primaryFile;
              filesInEntity.add(primary);
              for (final f in mediaEntity.files.files.values) {
                if (f.path != primary.path) {
                  filesInEntity.add(f);
                }
              }
            } catch (_) {
              // Fallback to whatever is available
              if (mediaEntity.files.files.isNotEmpty) {
                filesInEntity.addAll(mediaEntity.files.files.values);
              }
            }

            // Process each file of the entity
            for (final file in filesInEntity) {
              // Protect each file to avoid aborting entity processing
              try {
                // MIME sniff
                List<int> headerBytes = const [];
                String? mimeHeader;
                String? mimeExt;
                try {
                  headerBytes = await file.openRead(0, 128).first;
                  mimeHeader = lookupMimeType(
                    file.path,
                    headerBytes: headerBytes,
                  );
                  mimeExt = lookupMimeType(file.path);
                } catch (e) {
                  logWarning(
                    'Failed to read header for ${file.path}: $e (falling back to extension)',
                  );
                  mimeHeader = lookupMimeType(file.path);
                  mimeExt = mimeHeader;
                }

                bool gpsWritten = false;
                bool dateTimeWrittenLocal = false;

                // Tags to be written via ExifTool (batched or per-file)
                final Map<String, dynamic> tagsToWrite = {};

                // 1) GPS from JSON if EXIF lacks it
                try {
                  final coordinates = await jsonCoordinatesExtractor(file);
                  if (coordinates != null) {
                    Map<String, dynamic>? existing;
                    final coordExtractor = ExifCoordinateExtractor(
                      ServiceContainer.instance.exifTool!,
                    );
                    existing = await coordExtractor.extractGPSCoordinates(
                      file,
                      globalConfig: ServiceContainer.instance.globalConfig,
                    );
                    final hasCoords =
                        existing != null &&
                        existing['GPSLatitude'] != null &&
                        existing['GPSLongitude'] != null;

                    if (!hasCoords) {
                      if (mimeHeader == 'image/jpeg') {
                        if (entityEffectiveDate != null && !nativeOnly) {
                          // Try native combined first
                          final exifWriter = ExifWriterService(
                            ServiceContainer.instance.exifTool!,
                          );
                          final ok = await exifWriter.writeCombinedNativeJpeg(
                            file,
                            entityEffectiveDate,
                            coordinates,
                          );
                          if (ok) {
                            gpsWritten = true;
                            dateTimeWrittenLocal = true;
                          } else {
                            // Fallback to ExifTool tags
                            final exifFormat = DateFormat(
                              'yyyy:MM:dd HH:mm:ss',
                            );
                            final dt = exifFormat.format(entityEffectiveDate);
                            tagsToWrite['DateTimeOriginal'] = '"$dt"';
                            tagsToWrite['DateTimeDigitized'] = '"$dt"';
                            tagsToWrite['DateTime'] = '"$dt"';
                            tagsToWrite['GPSLatitude'] = coordinates
                                .toDD()
                                .latitude
                                .toString();
                            tagsToWrite['GPSLongitude'] = coordinates
                                .toDD()
                                .longitude
                                .toString();
                            tagsToWrite['GPSLatitudeRef'] = coordinates
                                .latDirection
                                .abbreviation
                                .toString();
                            tagsToWrite['GPSLongitudeRef'] = coordinates
                                .longDirection
                                .abbreviation
                                .toString();
                            gpsWritten = true;
                            dateTimeWrittenLocal = true;
                          }
                        } else if (entityEffectiveDate == null && !nativeOnly) {
                          // No date, write only GPS natively if possible
                          final exifWriter = ExifWriterService(
                            ServiceContainer.instance.exifTool!,
                          );
                          final ok = await exifWriter.writeGpsNativeJpeg(
                            file,
                            coordinates,
                          );
                          if (ok) {
                            gpsWritten = true;
                          } else {
                            tagsToWrite['GPSLatitude'] = coordinates
                                .toDD()
                                .latitude
                                .toString();
                            tagsToWrite['GPSLongitude'] = coordinates
                                .toDD()
                                .longitude
                                .toString();
                            tagsToWrite['GPSLatitudeRef'] = coordinates
                                .latDirection
                                .abbreviation
                                .toString();
                            tagsToWrite['GPSLongitudeRef'] = coordinates
                                .longDirection
                                .abbreviation
                                .toString();
                            gpsWritten = true;
                          }
                        }
                      } else {
                        // Non-JPEG: use ExifTool (unless nativeOnly)
                        if (!nativeOnly) {
                          tagsToWrite['GPSLatitude'] = coordinates
                              .toDD()
                              .latitude
                              .toString();
                          tagsToWrite['GPSLongitude'] = coordinates
                              .toDD()
                              .longitude
                              .toString();
                          tagsToWrite['GPSLatitudeRef'] = coordinates
                              .latDirection
                              .abbreviation
                              .toString();
                          tagsToWrite['GPSLongitudeRef'] = coordinates
                              .longDirection
                              .abbreviation
                              .toString();
                        }
                      }
                    }
                  }
                } catch (e) {
                  logWarning(
                    'Failed to extract/write GPS for ${file.path}: $e',
                  );
                }

                // 2) DateTime writer (native preferred for JPEG, otherwise ExifTool)
                try {
                  if (entityEffectiveDate != null) {
                    if (mimeHeader == 'image/jpeg') {
                      if (!dateTimeWrittenLocal && !nativeOnly) {
                        final exifWriter = ExifWriterService(
                          ServiceContainer.instance.exifTool!,
                        );
                        final ok = await exifWriter.writeDateTimeNativeJpeg(
                          file,
                          entityEffectiveDate,
                        );
                        if (ok) {
                          dateTimeWrittenLocal = true;
                        } else {
                          final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                          final dt = exifFormat.format(entityEffectiveDate);
                          if (!nativeOnly) {
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
                        final dt = exifFormat.format(entityEffectiveDate);
                        tagsToWrite['DateTimeOriginal'] = '"$dt"';
                        tagsToWrite['DateTimeDigitized'] = '"$dt"';
                        tagsToWrite['DateTime'] = '"$dt"';
                      }
                    }
                  }
                } catch (e) {
                  logWarning('Failed to write DateTime for ${file.path}: $e');
                }

                // 3) Enqueue or write per-file with ExifTool according to configuration
                try {
                  if (!nativeOnly && tagsToWrite.isNotEmpty) {
                    // Avoid extension/content mismatch that would make exiftool fail
                    if (mimeExt != mimeHeader && mimeHeader != 'image/tiff') {
                      logWarning(
                        "EXIF Writer - Extension indicates '$mimeExt' but header is '$mimeHeader'. Enqueuing for ExifTool batch.\n ${file.path}",
                      );
                    }
                    if (mimeExt == 'video/x-msvideo' ||
                        mimeHeader == 'video/x-msvideo') {
                      logWarning(
                        'Skipping AVI file - ExifTool cannot write RIFF AVI: ${file.path}',
                      );
                    } else {
                      final isVideo =
                          mimeHeader != null && mimeHeader.startsWith('video/');
                      final exifWriter = ExifWriterService(
                        ServiceContainer.instance.exifTool!,
                      );
                      if (!enableExifToolBatch) {
                        // Per-file (no batches)
                        try {
                          await exifWriter.writeTagsWithExifTool(
                            file,
                            tagsToWrite,
                          );
                        } catch (e) {
                          logWarning(
                            isVideo
                                ? 'Per-file video write failed: ${file.path} -> $e'
                                : 'Per-file write failed: ${file.path} -> $e',
                          );
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
                  logWarning(
                    'Failed to enqueue EXIF tags for ${file.path}: $e',
                  );
                }

                if (gpsWritten) localGps++;
                if (dateTimeWrittenLocal) localDate++;
              } catch (e) {
                final pathSafe = () {
                  try {
                    return file.path;
                  } catch (_) {
                    return '<unknown-file>';
                  }
                }();
                logError(
                  'EXIF write failed for $pathSafe: $e',
                  forcePrint: true,
                );
              }
            }
          } catch (e) {
            final pathSafe = () {
              try {
                return mediaEntity.primaryFile.path;
              } catch (_) {
                return '<unknown-entity>';
              }
            }();
            logError(
              'Entity processing failed for $pathSafe: $e',
              forcePrint: true,
            );
          }

          return {'gps': localGps, 'date': localDate};
        });

        final results = await Future.wait(futures);

        for (final r in results) {
          coordinatesWritten += r['gps'] ?? 0;
          dateTimesWritten += r['date'] ?? 0;
          completed++; // completed entities, not files
          onProgress?.call(completed, _media.length);
        }

        // During pre-batch (delayFlushUntilEnd == true) we do not flush here.
        if (!nativeOnly && enableExifToolBatch && !delayFlushUntilEnd) {
          final int targetImageBatch = baseBatchSize;
          const int targetVideoBatch = 12; // small video batches
          if (pendingImagesBatch.length >= targetImageBatch) {
            await flushImageBatch(useArgFile: true);
          }
          if (pendingVideosBatch.length >= targetVideoBatch) {
            await flushVideoBatch(useArgFile: true);
          }
        }
      }

      // If delaying flush for this list, flush now to keep groups together
      if (!nativeOnly && enableExifToolBatch && delayFlushUntilEnd) {
        final bool flushImagesWithArg =
            pendingImagesBatch.length > (Platform.isWindows ? 30 : 60);
        final bool flushVideosWithArg = pendingVideosBatch.length > 6;
        await flushImageBatch(useArgFile: flushImagesWithArg);
        await flushVideoBatch(useArgFile: flushVideosWithArg);
      }
    }

    // Wrap the whole processing to guarantee final flush in any case.
    try {
      // 1) Pre-batch phase: process multi-file entities and delay flush
      if (multiFileEntities.isNotEmpty) {
        print(
          'Pre-batch phase: processing ${multiFileEntities.length} multi-file entities (delayed flush to keep groups together).',
        );
        await processEntityList(multiFileEntities, delayFlushUntilEnd: true);
      }

      // 2) Normal phase: process single-file entities with regular threshold-based flushing
      if (singleFileEntities.isNotEmpty) {
        print(
          'Normal phase: processing ${singleFileEntities.length} single-file entities (regular flushing).',
        );
        await processEntityList(singleFileEntities, delayFlushUntilEnd: false);
      }
    } finally {
      // Final flush safety (only if batching is enabled)
      if (!nativeOnly && enableExifToolBatch) {
        final bool flushImagesWithArg =
            pendingImagesBatch.length > (Platform.isWindows ? 30 : 60);
        final bool flushVideosWithArg = pendingVideosBatch.length > 6;
        await flushImageBatch(useArgFile: flushImagesWithArg);
        await flushVideoBatch(useArgFile: flushVideosWithArg);
      } else {
        pendingImagesBatch.clear();
        pendingVideosBatch.clear();
      }
    }

    if (coordinatesWritten > 0) {
      print('$coordinatesWritten files got GPS set in EXIF data');
    }
    if (dateTimesWritten > 0) {
      print('$dateTimesWritten files got DateTime set in EXIF data');
    }

    // Final writer stats in seconds (no READ-EXIF lines here)
    // ignore: avoid_redundant_argument_values
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
      final File? jsonSidecar =
          await JsonMetadataMatcherService.findJsonForFile(file, tryhard: true);
      if (jsonSidecar == null) return null;

      final String raw = await jsonSidecar.readAsString();
      final dynamic data = jsonDecode(raw);

      final dynamic ts = (data is Map<String, dynamic>)
          ? (data['photoTakenTime']?['timestamp'] ??
                data['creationTime']?['timestamp'])
          : null;
      if (ts == null) return null;

      final int seconds = int.tryParse(ts.toString()) ?? 0;
      if (seconds <= 0) return null;

      // JSON timestamps are UTC; convert to local for writing.
      final DateTime utc = DateTime.fromMillisecondsSinceEpoch(
        seconds * 1000,
        isUtc: true,
      );
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
