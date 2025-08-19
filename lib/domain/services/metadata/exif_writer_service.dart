// FILE: lib/domain/services/metadata/exif_writer_service.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../infrastructure/exiftool_service.dart';
import '../core/logging_service.dart';

/// Service for writing EXIF data to media files (with batching + instrumentation).
///
/// Public helpers:
///  - writeDateTimeToExif(...) → high-level DateTime writer (native JPEG first, else exiftool)
///  - writeGpsToExif(...)      → high-level GPS writer (native JPEG first, else exiftool)
///  - writeTagsWithExifTool(file, tags, isDate:..., isGps:...) → one-shot wrapper w/ counters
///  - writeTagsBatchWithExifTool(batch, useArgFile:true) → grouped by type (date/gps/combined), up to 3 calls
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool);

  final ExifToolService _exifTool;

  // ── Writer instrumentation (exposed) ────────────────────────────────────────
  static int exiftoolCalls = 0; // number of exiftool invocations
  static int exiftoolFiles = 0; // total files passed to exiftool (sum of batch sizes)

  // Native counters (JPEG)
  static int nativeJpegDateWrites = 0;
  static int nativeJpegGpsWrites = 0;
  static int nativeJpegCombinedWrites = 0;

  // Exiftool counters (by tag category)
  static int exiftoolDateWrites = 0;
  static int exiftoolGpsWrites = 0;
  static int exiftoolCombinedWrites = 0;

  // Timers (ms)
  static int nativeDateMs = 0;
  static int nativeGpsMs = 0;
  static int nativeCombinedMs = 0;

  static int exiftoolDateMs = 0;
  static int exiftoolGpsMs = 0;
  static int exiftoolCombinedMs = 0;

  static void resetWriterStats() {
    exiftoolCalls = 0;
    exiftoolFiles = 0;
    nativeJpegDateWrites = 0;
    nativeJpegGpsWrites = 0;
    nativeJpegCombinedWrites = 0;
    exiftoolDateWrites = 0;
    exiftoolGpsWrites = 0;
    exiftoolCombinedWrites = 0;
    nativeDateMs = 0;
    nativeGpsMs = 0;
    nativeCombinedMs = 0;
    exiftoolDateMs = 0;
    exiftoolGpsMs = 0;
    exiftoolCombinedMs = 0;
  }

  /// Print summary (seconds) without extra blank lines.
  void dumpWriterStats({bool reset = true}) {
    logInfo('[INFO] [WRITE-EXIF] calls=$exiftoolCalls, files=$exiftoolFiles');
    logInfo(
      '[INFO] [WRITE-EXIF] native: dateWrites=$nativeJpegDateWrites, gpsWrites=$nativeJpegGpsWrites, combined=$nativeJpegCombinedWrites, dateTime=${(nativeDateMs / 1000.0).toStringAsFixed(3)}s, gpsTime=${(nativeGpsMs / 1000.0).toStringAsFixed(3)}s, combinedTime=${(nativeCombinedMs / 1000.0).toStringAsFixed(3)}s',
    );
    logInfo(
      '[INFO] [WRITE-EXIF] exiftool: dateWrites=$exiftoolDateWrites, gpsWrites=$exiftoolGpsWrites, combined=$exiftoolCombinedWrites, dateTime=${(exiftoolDateMs / 1000.0).toStringAsFixed(3)}s, gpsTime=${(exiftoolGpsMs / 1000.0).toStringAsFixed(3)}s, combinedTime=${(exiftoolCombinedMs / 1000.0).toStringAsFixed(3)}s',
    );
    if (reset) resetWriterStats();
  }

  // ── Public static helpers used outside (classification of tags) ────────────
  static bool hasDateKeys(Map<String, dynamic> tags) =>
      tags.containsKey('DateTimeOriginal') ||
      tags.containsKey('DateTimeDigitized') ||
      tags.containsKey('DateTime') ||
      tags.containsKey('CreateDate');

  static bool hasGpsKeys(Map<String, dynamic> tags) =>
      tags.containsKey('GPSLatitude') ||
      tags.containsKey('GPSLongitude') ||
      tags.containsKey('GPSLatitudeRef') ||
      tags.containsKey('GPSLongitudeRef');

  // ── High-level APIs ────────────────────────────────────────────────────────

  /// Write DateTime, preferring native for JPEG; else exiftool.
  Future<bool> writeDateTimeToExif(
    final DateTime dateTime,
    final File file,
    final dynamic globalConfigLike, // only to check exiftool availability if needed
  ) async {
    // Try native for JPEG
    final header = await file.openRead(0, 128).first;
    final mimeHeader = lookupMimeType(file.path, headerBytes: header);

    if (mimeHeader == 'image/jpeg') {
      final sw = Stopwatch()..start();
      final ok = await writeDateTimeNativeJpeg(file, dateTime);
      nativeDateMs += sw.elapsedMilliseconds;
      if (ok) {
        nativeJpegDateWrites++;
        return true;
      }
    }

    // Fallback to exiftool
    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
    final String dt = exifFormat.format(dateTime);
    final tags = {
      'DateTimeOriginal': '"$dt"',
      'DateTimeDigitized': '"$dt"',
      'DateTime': '"$dt"',
    };
    return await writeTagsWithExifTool(file, tags, isDate: true);
  }

  /// Write GPS, preferring native for JPEG; else exiftool.
  Future<bool> writeGpsToExif(
    final DMSCoordinates coordinates,
    final File file,
    final dynamic globalConfigLike,
  ) async {
    final header = await file.openRead(0, 128).first;
    final mimeHeader = lookupMimeType(file.path, headerBytes: header);

    if (mimeHeader == 'image/jpeg') {
      final sw = Stopwatch()..start();
      final ok = await writeGpsNativeJpeg(file, coordinates);
      nativeGpsMs += sw.elapsedMilliseconds;
      if (ok) {
        nativeJpegGpsWrites++;
        return true;
      }
    }

    final tags = {
      'GPSLatitude': coordinates.toDD().latitude.toString(),
      'GPSLongitude': coordinates.toDD().longitude.toString(),
      'GPSLatitudeRef': coordinates.latDirection.abbreviation.toString(),
      'GPSLongitudeRef': coordinates.longDirection.abbreviation.toString(),
    };
    return await writeTagsWithExifTool(file, tags, isGps: true);
  }

  // ── One-shot exiftool wrapper ──────────────────────────────────────────────
  Future<bool> writeTagsWithExifTool(
    final File file,
    final Map<String, dynamic> tags, {
    bool isDate = false,
    bool isGps = false,
  }) async {
    if (tags.isEmpty) return false;
    try {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifData(file, tags);
      final ms = sw.elapsedMilliseconds;

      exiftoolCalls++;
      exiftoolFiles += 1;

      final hasDate = isDate || hasDateKeys(tags);
      final hasGps = isGps || hasGpsKeys(tags);

      if (hasDate && hasGps) {
        exiftoolCombinedWrites++;
        exiftoolCombinedMs += ms;
      } else if (hasDate) {
        exiftoolDateWrites++;
        exiftoolDateMs += ms;
      } else if (hasGps) {
        exiftoolGpsWrites++;
        exiftoolGpsMs += ms;
      }

      logInfo('[Step 5/8] Wrote tags ${tags.keys.toList()} via exiftool: ${file.path}');
      return true;
    } catch (e) {
      logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    }
  }

  /// Batched exiftool write. We split the input batch into up to three sub-batches
  /// (date-only, gps-only, combined) to produce accurate per-category timings.
  Future<bool> writeTagsBatchWithExifTool(
    final List<MapEntry<File, Map<String, dynamic>>> batch, {
    bool useArgFile = true,
  }) async {
    if (batch.isEmpty) return false;

    final dateOnly = <MapEntry<File, Map<String, dynamic>>>[];
    final gpsOnly = <MapEntry<File, Map<String, dynamic>>>[];
    final combined = <MapEntry<File, Map<String, dynamic>>>[];

    for (final e in batch) {
      final tags = e.value;
      final hd = hasDateKeys(tags);
      final hg = hasGpsKeys(tags);
      if (hd && hg) {
        combined.add(e);
      } else if (hd) {
        dateOnly.add(e);
      } else if (hg) {
        gpsOnly.add(e);
      } else {
        // If neither, still write as generic
        dateOnly.add(e);
      }
    }

    Future<void> _run(
      List<MapEntry<File, Map<String, dynamic>>> items, {
      required String cat,
    }) async {
      if (items.isEmpty) return;
      final sw = Stopwatch()..start();
      try {
        if (useArgFile) {
          await _exifTool.writeExifDataBatchViaArgFile(items);
        } else {
          await _exifTool.writeExifDataBatch(items);
        }
      } finally {
        final ms = sw.elapsedMilliseconds;
        exiftoolCalls++;
        exiftoolFiles += items.length;
        if (cat == 'date') {
          exiftoolDateWrites += items.length;
          exiftoolDateMs += ms;
        } else if (cat == 'gps') {
          exiftoolGpsWrites += items.length;
          exiftoolGpsMs += ms;
        } else {
          exiftoolCombinedWrites += items.length;
          exiftoolCombinedMs += ms;
        }
      }
    }

    await _run(dateOnly, cat: 'date');
    await _run(gpsOnly, cat: 'gps');
    await _run(combined, cat: 'combined');
    return true;
  }

  // ── Native JPEG writers (image package) ────────────────────────────────────
  Future<bool> writeDateTimeNativeJpeg(final File file, final DateTime dt) async {
    try {
      final Uint8List orig = file.readAsBytesSync();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) return false;

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final s = fmt.format(dt);
      exif.imageIfd['DateTime'] = s;
      exif.exifIfd['DateTimeOriginal'] = s;
      exif.exifIfd['DateTimeDigitized'] = s;

      final Uint8List? newbytes = injectJpgExif(orig, exif);
      if (newbytes == null) return false;
      file.writeAsBytesSync(newbytes);
      logInfo('[Step 5/8] New DateTime $s written to EXIF (native): ${file.path}');
      return true;
    } catch (e) {
      logError('Native JPEG DateTime write failed for ${file.path}: $e');
      return false;
    }
  }

  Future<bool> writeGpsNativeJpeg(final File file, final DMSCoordinates coords) async {
    try {
      final Uint8List orig = file.readAsBytesSync();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) return false;

      exif.gpsIfd.gpsLatitude = coords.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coords.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coords.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coords.longDirection.abbreviation;

      final Uint8List? newbytes = injectJpgExif(orig, exif);
      if (newbytes == null) return false;
      file.writeAsBytesSync(newbytes);
      logInfo('[Step 5/8] New GPS written to EXIF (native): ${file.path}');
      return true;
    } catch (e) {
      logError('Native JPEG GPS write failed for ${file.path}: $e');
      return false;
    }
  }
}
