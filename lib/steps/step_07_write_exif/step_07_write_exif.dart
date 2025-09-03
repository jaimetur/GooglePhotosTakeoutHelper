import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

/// Step 7: Write EXIF data to output files (physical files only)
///
/// Single rule (no per-strategy branching here):
///   • Process every FileEntity whose `targetPath` is not null AND `isShortcut == false`.
///   • GPS sidecar JSON is resolved using the *primary* entity's `sourcePath`.
///   • The entity's `dateTaken`/`dateAccuracy` are the authoritative timestamp/quality.
///
/// Why this shape:
///   • Step 6 (Move Files) already performed all physical moves/copies/shortcuts and
///     annotated each FileEntity with `targetPath` and `isShortcut`.
///   • We trust those flags to decide what to embed. Shortcuts are never written.
///   • This keeps Step 7 independent from album strategies.
class WriteExifStep extends ProcessingStep with LoggerMixin {
  WriteExifStep() : super('Write EXIF Data');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final sw = Stopwatch()..start();

    try {
      final collection = context.mediaCollection;

      print(
        '\n[Step 7/8] Writing EXIF data on physical files in output (this may take a while)...',
      );
      if (!context.config.writeExif) {
        sw.stop();
        return StepResult.success(
          stepName: name,
          duration: sw.elapsed,
          data: {
            'coordinatesWritten': 0,
            'dateTimesWritten': 0,
            'skipped': true,
          },
          message: 'EXIF writing skipped per configuration',
        );
      }

      // Tooling
      final exifTool = ServiceContainer.instance.exifTool; // may be null
      final bool nativeOnly = exifTool == null;
      if (nativeOnly) {
        logWarning(
          '[Step 7/8] ExifTool not available, native-only support.',
          forcePrint: true,
        );
      } else {
        print('[Step 7/8] ExifTool enabled');
      }

      // Batching config
      final bool enableExifToolBatch = _resolveBatchingPreference(exifTool);
      final progressBar = FillingBar(
        desc: '[Step 7/8] Writing EXIF data',
        total: collection.length,
        width: 50,
      );
      final _UnsupportedPolicy unsupportedPolicy = _resolveUnsupportedPolicy();
      final int maxConc = ConcurrencyManager().concurrencyFor(
        ConcurrencyOperation.exif,
      );
      final ExifWriterService? exifWriter = (exifTool != null)
          ? ExifWriterService(exifTool)
          : null;

      // Batch queues (images/videos)
      final bool isWindows = Platform.isWindows;
      final int baseBatchSize = isWindows ? 60 : 120;
      final int maxImageBatch = _resolveInt(
        'maxExifImageBatchSize',
        defaultValue: 500,
      );
      final int maxVideoBatch = _resolveInt(
        'maxExifVideoBatchSize',
        defaultValue: 24,
      );

      final pendingImagesBatch = <MapEntry<File, Map<String, dynamic>>>[];
      final pendingVideosBatch = <MapEntry<File, Map<String, dynamic>>>[];

      // Safe batched write (splits on failure to isolate bad files)
      Future<void> writeBatchSafe(
        final List<MapEntry<File, Map<String, dynamic>>> queue, {
        required final bool useArgFile,
        required final bool isVideoBatch,
      }) async {
        if (queue.isEmpty || exifWriter == null) return;

        Future<void> splitAndWrite(
          final List<MapEntry<File, Map<String, dynamic>>> chunk,
        ) async {
          if (chunk.isEmpty) return;
          if (chunk.length == 1) {
            final entry = chunk.first;
            try {
              await exifWriter.writeTagsWithExifTool(entry.key, entry.value);
            } catch (e) {
              if (!_shouldSilenceExiftoolError(e)) {
                logWarning(
                  isVideoBatch
                      ? 'Per-file video write failed: ${entry.key.path} -> $e'
                      : 'Per-file write failed: ${entry.key.path} -> $e',
                );
              }
              await _tryDeleteTmp(entry.key);
            }
            return;
          }

          final mid = chunk.length >> 1;
          final left = chunk.sublist(0, mid);
          final right = chunk.sublist(mid);

          try {
            await exifWriter.writeBatchWithExifTool(
              chunk,
              useArgFileWhenLarge: useArgFile,
            );
          } catch (e) {
            await _tryDeleteTmpForChunk(chunk);
            if (!_shouldSilenceExiftoolError(e)) {
              logWarning(
                isVideoBatch
                    ? 'Video batch flush failed (${chunk.length} files) - splitting: $e'
                    : 'Batch flush failed (${chunk.length} files) - splitting: $e',
              );
            }
            await splitAndWrite(left);
            await splitAndWrite(right);
          }
        }

        await splitAndWrite(queue);
      }

      // Flush helpers
      Future<void> flushBatch(
        final List<MapEntry<File, Map<String, dynamic>>> queue, {
        required final bool useArgFile,
        required final bool isVideoBatch,
      }) async {
        if (nativeOnly || !enableExifToolBatch) return;
        if (queue.isEmpty) return;
        if (exifWriter == null) {
          queue.clear();
          return;
        }

        // Enforce safe caps
        while (queue.length > (isVideoBatch ? maxVideoBatch : maxImageBatch)) {
          final sub = queue.sublist(
            0,
            isVideoBatch ? maxVideoBatch : maxImageBatch,
          );
          await writeBatchSafe(
            sub,
            useArgFile: true,
            isVideoBatch: isVideoBatch,
          );
          queue.removeRange(0, sub.length);
        }

        await writeBatchSafe(
          queue,
          useArgFile: useArgFile,
          isVideoBatch: isVideoBatch,
        );
        queue.clear();
      }

      Future<void> flushImageBatch({required final bool useArgFile}) =>
          flushBatch(
            pendingImagesBatch,
            useArgFile: useArgFile,
            isVideoBatch: false,
          );
      Future<void> flushVideoBatch({required final bool useArgFile}) =>
          flushBatch(
            pendingVideosBatch,
            useArgFile: useArgFile,
            isVideoBatch: true,
          );

      Future<void> maybeFlushThresholds() async {
        if (nativeOnly || !enableExifToolBatch) return;
        final int targetImageBatch = baseBatchSize.clamp(1, maxImageBatch);
        final int targetVideoBatch = 12.clamp(1, maxVideoBatch);
        if (pendingImagesBatch.length >= targetImageBatch) {
          await flushImageBatch(useArgFile: true);
        }
        if (pendingVideosBatch.length >= targetVideoBatch) {
          await flushVideoBatch(useArgFile: true);
        }
      }

      // Per-file EXIF write (file already in output). Uses entity's dateTaken and
      // GPS coords previously extracted from the primary sidecar JSON.
      Future<Map<String, bool>> writeForFile({
        required final File file,
        required final bool markAsPrimary,
        required final DateTime? effectiveDate,
        required final coordsFromPrimary,
      }) async {
        bool gpsWrittenThis = false;
        bool dtWrittenThis = false;

        try {
          final lower = file.path.toLowerCase();

          // MIME guess — extension first, header as fallback (cheap and robust)
          String? mimeHeader;
          String? mimeExt;
          if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
            mimeHeader = 'image/jpeg';
            mimeExt = 'image/jpeg';
          } else if (lower.endsWith('.heic')) {
            mimeHeader = 'image/heic';
            mimeExt = 'image/heic';
          } else if (lower.endsWith('.png')) {
            mimeHeader = 'image/png';
            mimeExt = 'image/png';
          } else if (lower.endsWith('.mp4')) {
            mimeHeader = 'video/mp4';
            mimeExt = 'video/mp4';
          } else if (lower.endsWith('.mov')) {
            mimeHeader = 'video/quicktime';
            mimeExt = 'video/quicktime';
          } else {
            try {
              final header = await file.openRead(0, 128).first;
              mimeHeader = lookupMimeType(file.path, headerBytes: header);
              mimeExt = lookupMimeType(file.path);
            } catch (_) {
              mimeHeader = lookupMimeType(file.path);
              mimeExt = mimeHeader;
            }
          }

          final tagsToWrite = <String, dynamic>{};

          // GPS (if primary coords available)
          try {
            final coords = coordsFromPrimary;
            if (coords != null) {
              if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                if (!nativeOnly && exifWriter != null) {
                  if (effectiveDate != null) {
                    final ok = await exifWriter.writeCombinedNativeJpeg(
                      file,
                      effectiveDate,
                      coords,
                    );
                    if (ok) {
                      gpsWrittenThis = true;
                      dtWrittenThis = true;
                    } else {
                      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                      final dt = exifFormat.format(effectiveDate);
                      tagsToWrite['DateTimeOriginal'] = '"$dt"';
                      tagsToWrite['DateTimeDigitized'] = '"$dt"';
                      tagsToWrite['DateTime'] = '"$dt"';
                      tagsToWrite['GPSLatitude'] = coords
                          .toDD()
                          .latitude
                          .toString();
                      tagsToWrite['GPSLongitude'] = coords
                          .toDD()
                          .longitude
                          .toString();
                      tagsToWrite['GPSLatitudeRef'] = coords
                          .latDirection
                          .abbreviation
                          .toString();
                      tagsToWrite['GPSLongitudeRef'] = coords
                          .longDirection
                          .abbreviation
                          .toString();
                      gpsWrittenThis = true;
                      dtWrittenThis = true;
                    }
                  } else {
                    final ok = await exifWriter.writeGpsNativeJpeg(
                      file,
                      coords,
                    );
                    if (ok) {
                      gpsWrittenThis = true;
                    } else {
                      tagsToWrite['GPSLatitude'] = coords
                          .toDD()
                          .latitude
                          .toString();
                      tagsToWrite['GPSLongitude'] = coords
                          .toDD()
                          .longitude
                          .toString();
                      tagsToWrite['GPSLatitudeRef'] = coords
                          .latDirection
                          .abbreviation
                          .toString();
                      tagsToWrite['GPSLongitudeRef'] = coords
                          .longDirection
                          .abbreviation
                          .toString();
                      gpsWrittenThis = true;
                    }
                  }
                } else {
                  // Native-only: enqueue GPS via ExifTool tags map (if ExifTool later available)
                  tagsToWrite['GPSLatitude'] = coords
                      .toDD()
                      .latitude
                      .toString();
                  tagsToWrite['GPSLongitude'] = coords
                      .toDD()
                      .longitude
                      .toString();
                  tagsToWrite['GPSLatitudeRef'] = coords
                      .latDirection
                      .abbreviation
                      .toString();
                  tagsToWrite['GPSLongitudeRef'] = coords
                      .longDirection
                      .abbreviation
                      .toString();
                  gpsWrittenThis = true;
                }
              } else {
                // Non-JPEG: rely on ExifTool only
                if (!nativeOnly) {
                  tagsToWrite['GPSLatitude'] = coords
                      .toDD()
                      .latitude
                      .toString();
                  tagsToWrite['GPSLongitude'] = coords
                      .toDD()
                      .longitude
                      .toString();
                  tagsToWrite['GPSLatitudeRef'] = coords
                      .latDirection
                      .abbreviation
                      .toString();
                  tagsToWrite['GPSLongitudeRef'] = coords
                      .longDirection
                      .abbreviation
                      .toString();
                  gpsWrittenThis = true;
                }
              }
            }
          } catch (e) {
            logWarning(
              'Failed to prepare GPS tags for ${file.path}: $e',
              forcePrint: true,
            );
          }

          // Date/time from entity
          try {
            if (effectiveDate != null) {
              if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
                if (!dtWrittenThis && !nativeOnly && exifWriter != null) {
                  final ok = await exifWriter.writeDateTimeNativeJpeg(
                    file,
                    effectiveDate,
                  );
                  if (ok) {
                    dtWrittenThis = true;
                  } else {
                    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                    final dt = exifFormat.format(effectiveDate);
                    tagsToWrite['DateTimeOriginal'] = '"$dt"';
                    tagsToWrite['DateTimeDigitized'] = '"$dt"';
                    tagsToWrite['DateTime'] = '"$dt"';
                    dtWrittenThis = true;
                  }
                }
              } else {
                if (!nativeOnly) {
                  final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
                  final dt = exifFormat.format(effectiveDate);
                  tagsToWrite['DateTimeOriginal'] = '"$dt"';
                  tagsToWrite['DateTimeDigitized'] = '"$dt"';
                  tagsToWrite['DateTime'] = '"$dt"';
                  dtWrittenThis = true;
                }
              }
            }
          } catch (e) {
            logWarning(
              'Failed to prepare DateTime tags for ${file.path}: $e',
              forcePrint: true,
            );
          }

          // Write (per-file or batch)
          try {
            if (!nativeOnly && tagsToWrite.isNotEmpty) {
              final bool isVideo = (mimeHeader ?? '').startsWith('video/');
              final bool isUnsupported = _isDefinitelyUnsupportedForWrite(
                mimeHeader: mimeHeader,
                mimeExt: mimeExt,
                pathLower: lower,
              );

              if (isUnsupported &&
                  !unsupportedPolicy.forceProcessUnsupportedFormats) {
                if (!unsupportedPolicy.silenceUnsupportedWarnings) {
                  final detectedFmt = _describeUnsupported(
                    mimeHeader: mimeHeader,
                    mimeExt: mimeExt,
                    pathLower: lower,
                  );
                  logWarning(
                    'Skipping $detectedFmt file - ExifTool cannot write $detectedFmt: ${file.path}',
                    forcePrint: true,
                  );
                }
              } else {
                if (!enableExifToolBatch) {
                  try {
                    await exifWriter!.writeTagsWithExifTool(file, tagsToWrite);
                  } catch (e) {
                    if (!_shouldSilenceExiftoolError(e)) {
                      logWarning(
                        isVideo
                            ? 'Per-file video write failed: ${file.path} -> $e'
                            : 'Per-file write failed: ${file.path} -> $e',
                      );
                    }
                    await _tryDeleteTmp(file);
                  }
                } else {
                  if (isVideo) {
                    pendingVideosBatch.add(MapEntry(file, tagsToWrite));
                  } else {
                    pendingImagesBatch.add(MapEntry(file, tagsToWrite));
                  }
                }
              }
            }
          } catch (e) {
            if (!_shouldSilenceExiftoolError(e)) {
              logWarning(
                'Failed to enqueue EXIF tags for ${file.path}: $e',
              );
            }
          }

          // Unique-file instrumentation counts (primary vs secondary)
          if (gpsWrittenThis) {
            ExifWriterService.markGpsTouchedFromStep5(
              file,
              isPrimary: markAsPrimary,
            );
          }
          if (dtWrittenThis) {
            ExifWriterService.markDateTouchedFromStep5(
              file,
              isPrimary: markAsPrimary,
            );
          }
        } catch (e) {
          logError('EXIF write failed for ${file.path}: $e', forcePrint: true);
        }

        return {'gps': gpsWrittenThis, 'date': dtWrittenThis};
      }

      int completedEntities = 0;
      int gpsWrittenTotal = 0;
      int dateWrittenTotal = 0;

      // Process entities with bounded concurrency
      for (int i = 0; i < collection.length; i += maxConc) {
        final slice = collection
            .asList()
            .skip(i)
            .take(maxConc)
            .toList(growable: false);

        final results = await Future.wait(
          slice.map((final entity) async {
            int localGps = 0;
            int localDate = 0;

            // Read GPS from primary sidecar JSON (input side) once per entity
            dynamic coordsFromPrimary;
            try {
              final primarySourceFile = File(entity.primaryFile.sourcePath);
              coordsFromPrimary = await jsonCoordinatesExtractor(
                primarySourceFile,
              );
            } catch (_) {
              coordsFromPrimary = null;
            }

            // Iterate over all FileEntity elements and process output physical files only
            final List<FileEntity> allFiles = <FileEntity>[
              entity.primaryFile,
              ...entity.secondaryFiles,
            ];

            for (final fe in allFiles) {
              final String? outPath = fe.targetPath;
              if (outPath == null || fe.isShortcut) continue;

              final outFile = File(outPath);
              if (!await outFile.exists()) continue;

              final r = await writeForFile(
                file: outFile,
                markAsPrimary: identical(fe, entity.primaryFile),
                effectiveDate: entity.dateTaken,
                coordsFromPrimary: coordsFromPrimary,
              );
              if (r['gps'] == true) localGps++;
              if (r['date'] == true) localDate++;
            }

            return {'gps': localGps, 'date': localDate};
          }),
        );

        for (final r in results) {
          gpsWrittenTotal += r['gps'] ?? 0;
          dateWrittenTotal += r['date'] ?? 0;
          completedEntities++;
          progressBar.update(completedEntities);
        }

        if (!nativeOnly && enableExifToolBatch) await maybeFlushThresholds();
      }

      print('');

      // Final batch flush (if batching was used)
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

      // Unique-file metrics
      final gpsTotal = ExifWriterService.uniqueGpsFilesCount;
      final gpsPrim = ExifWriterService.uniqueGpsPrimaryCount;
      final gpsSec = ExifWriterService.uniqueGpsSecondaryCount;
      final dtTotal = ExifWriterService.uniqueDateFilesCount;
      final dtPrim = ExifWriterService.uniqueDatePrimaryCount;
      final dtSec = ExifWriterService.uniqueDateSecondaryCount;

      if (gpsTotal > 0) {
        print(
          '[Step 7/8] $gpsTotal files got GPS set in EXIF data (primary=$gpsPrim, secondary=$gpsSec)',
        );
      }
      if (dtTotal > 0) {
        print(
          '[Step 7/8] $dtTotal files got DateTime set in EXIF data (primary=$dtPrim, secondary=$dtSec)',
        );
      }
      print(
        '[Step 7/8] Processed ${collection.entities.length} entities; touched ${ExifWriterService.uniqueFilesTouchedCount} files',
      );

      final int touchedFilesBeforeReset =
          ExifWriterService.uniqueFilesTouchedCount;
      final int touchedGpsBeforeReset = ExifWriterService.uniqueGpsFilesCount;
      final int touchedDateBeforeReset = ExifWriterService.uniqueDateFilesCount;

      // Dump internal writer stats (resets counters)
      ExifWriterService.dumpWriterStats(logger: this);
      ExifCoordinateExtractor.dumpStats(reset: true, loggerMixin: this);

      sw.stop();
      return StepResult.success(
        stepName: name,
        duration: sw.elapsed,
        data: {
          'coordinatesWritten': touchedGpsBeforeReset,
          'dateTimesWritten': touchedDateBeforeReset,
          'rawGpsWrites': gpsWrittenTotal,
          'rawDateWrites': dateWrittenTotal,
          'skipped': false,
        },
        message: 'Wrote EXIF data to $touchedFilesBeforeReset files',
      );
    } catch (e) {
      sw.stop();
      if (!_shouldSilenceExiftoolError(e)) {
        logError('Failed to write EXIF data: $e', forcePrint: true);
      }
      return StepResult.failure(
        stepName: name,
        duration: sw.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to write EXIF data',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;

  // ------------------------------- Utilities --------------------------------

  bool _resolveBatchingPreference(final Object? exifTool) {
    if (exifTool == null) return false;
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.enableExifToolBatch;
      if (v is bool) return v;
    } catch (_) {}
    return true;
  }

  _UnsupportedPolicy _resolveUnsupportedPolicy() {
    bool force = false;
    bool silence = false;
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      if (dyn.forceProcessUnsupportedFormats is bool) {
        force = dyn.forceProcessUnsupportedFormats as bool;
      }
      if (dyn.silenceUnsupportedWarnings is bool) {
        silence = dyn.silenceUnsupportedWarnings as bool;
      }
    } catch (_) {}
    return _UnsupportedPolicy(
      forceProcessUnsupportedFormats: force,
      silenceUnsupportedWarnings: silence,
    );
  }

  bool _isDefinitelyUnsupportedForWrite({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    if (pathLower.endsWith('.avi') ||
        pathLower.endsWith('.mpg') ||
        pathLower.endsWith('.mpeg') ||
        pathLower.endsWith('.bmp')) {
      return true;
    }
    if (mimeHeader == 'video/x-msvideo' || mimeExt == 'video/x-msvideo') {
      return true; // AVI
    }
    if ((mimeHeader ?? '').contains('mpeg') || (mimeExt ?? '').contains('mpeg')) {
      return true; // MPG/MPEG
    }
    if ((mimeHeader ?? '') == 'image/bmp' || (mimeExt ?? '') == 'image/bmp') {
      return true; // BMP
    }
    return false;
  }

  String _describeUnsupported({
    final String? mimeHeader,
    final String? mimeExt,
    required final String pathLower,
  }) {
    if (pathLower.endsWith('.avi') ||
        mimeHeader == 'video/x-msvideo' ||
        mimeExt == 'video/x-msvideo') {
      return 'AVI';
    }
    if (pathLower.endsWith('.mpg') ||
        pathLower.endsWith('.mpeg') ||
        (mimeHeader ?? '').contains('mpeg') ||
        (mimeExt ?? '').contains('mpeg')) {
      return 'MPEG';
    }
    if (pathLower.endsWith('.bmp') ||
        mimeHeader == 'image/bmp' ||
        mimeExt == 'image/bmp') {
      return 'BMP';
    }
    return 'unsupported';
  }

  bool _shouldSilenceExiftoolError(final Object e) {
    final s = e.toString();
    if (s.contains('Truncated InteropIFD directory')) return true;
    return false;
  }

  Future<void> _tryDeleteTmp(final File f) async {
    try {
      final tmp = File('${f.path}_exiftool_tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  Future<void> _tryDeleteTmpForChunk(
    final List<MapEntry<File, Map<String, dynamic>>> chunk,
  ) async {
    for (final e in chunk) {
      await _tryDeleteTmp(e.key);
    }
  }

  int _resolveInt(final String name, {required final int defaultValue}) {
    try {
      final cfg = ServiceContainer.instance.globalConfig;
      final dyn = cfg as dynamic;
      final v = dyn.toJson != null ? (dyn.toJson()[name]) : (dyn[name]);
      if (v is int) return v;
      if (v is String) return int.tryParse(v) ?? defaultValue;
    } catch (_) {}
    return defaultValue;
  }
}

class _UnsupportedPolicy {
  const _UnsupportedPolicy({
    required this.forceProcessUnsupportedFormats,
    required this.silenceUnsupportedWarnings,
  });
  final bool forceProcessUnsupportedFormats;
  final bool silenceUnsupportedWarnings;
}
