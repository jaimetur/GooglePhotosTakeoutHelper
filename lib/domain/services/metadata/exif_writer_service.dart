import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../infrastructure/exiftool_service.dart';
import '../core/global_config_service.dart';
import '../core/logging_service.dart';

/// Service for writing EXIF data to media files (optimized Step 5).
/// - Uses native JPEG path when possible (fast).
/// - Batches non-JPEG writes through ExifTool (fast in bulk).
/// - Provides rich instrumentation (time + counters) per branch.
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool);

  final ExifToolService _exifTool;

  // ── Instrumentation (per run) ──────────────────────────────────────────────
  static int nativeDateCount = 0;
  static int nativeGpsCount = 0;
  static int nativeCombinedCount = 0;

  static int exiftoolDateCount = 0;
  static int exiftoolGpsCount = 0;
  static int exiftoolCombinedCount = 0;

  static int nativeDateMs = 0;
  static int nativeGpsMs = 0;
  static int nativeCombinedMs = 0;

  static int exiftoolDateMs = 0;
  static int exiftoolGpsMs = 0;
  static int exiftoolCombinedMs = 0;

  /// Print a compact summary of Step 5 time/counters per branch.
  void dumpWriterStatsDetailed({bool reset = true}) {
    logInfo(
      '[WRITER] Native DateTime: files=$nativeDateCount, time=${nativeDateMs}ms | '
      'Native GPS: files=$nativeGpsCount, time=${nativeGpsMs}ms | '
      'Native Combined: files=$nativeCombinedCount, time=${nativeCombinedMs}ms',
      forcePrint: true,
    );
    logInfo(
      '[WRITER] ExifTool DateTime: files=$exiftoolDateCount, time=${exiftoolDateMs}ms | '
      'ExifTool GPS: files=$exiftoolGpsCount, time=${exiftoolGpsMs}ms | '
      'ExifTool Combined: files=$exiftoolCombinedCount, time=${exiftoolCombinedMs}ms',
      forcePrint: true,
    );
    if (reset) {
      nativeDateCount = 0;
      nativeGpsCount = 0;
      nativeCombinedCount = 0;
      exiftoolDateCount = 0;
      exiftoolGpsCount = 0;
      exiftoolCombinedCount = 0;
      nativeDateMs = 0;
      nativeGpsMs = 0;
      nativeCombinedMs = 0;
      exiftoolDateMs = 0;
      exiftoolGpsMs = 0;
      exiftoolCombinedMs = 0;
    }
  }

  // ── Native JPEG writers ────────────────────────────────────────────────────

  /// Write DateTime via native JPEG EXIF (single pass). Returns true if changed.
  Future<bool> writeDateTimeNativeJpeg(
    File file,
    DateTime dateTime,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await file.readAsBytes();
      final exif = decodeJpgExif(bytes);
      if (exif == null || exif.isEmpty) return false;

      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
      final value = exifFormat.format(dateTime);
      exif.imageIfd['DateTime'] = value;
      exif.exifIfd['DateTimeOriginal'] = value;
      exif.exifIfd['DateTimeDigitized'] = value;

      final newBytes = injectJpgExif(bytes, exif);
      if (newBytes == null) return false;

      await file.writeAsBytes(newBytes);
      return true;
    } finally {
      sw.stop();
      nativeDateCount++;
      nativeDateMs += sw.elapsedMilliseconds;
    }
  }

  /// Write GPS via native JPEG EXIF (single pass). Returns true if changed.
  Future<bool> writeGpsNativeJpeg(
    File file,
    DMSCoordinates coordinates,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await file.readAsBytes();
      final exif = decodeJpgExif(bytes);
      if (exif == null || exif.isEmpty) return false;

      exif.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coordinates.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coordinates.longDirection.abbreviation;

      final newBytes = injectJpgExif(bytes, exif);
      if (newBytes == null) return false;

      await file.writeAsBytes(newBytes);
      return true;
    } finally {
      sw.stop();
      nativeGpsCount++;
      nativeGpsMs += sw.elapsedMilliseconds;
    }
  }

  /// Write DateTime + GPS in a single native JPEG pass (fast combined path).
  Future<bool> writeDateTimeAndGpsNativeJpeg(
    File file,
    DateTime dateTime,
    DMSCoordinates coordinates,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final bytes = await file.readAsBytes();
      final exif = decodeJpgExif(bytes);
      if (exif == null || exif.isEmpty) return false;

      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
      final value = exifFormat.format(dateTime);
      exif.imageIfd['DateTime'] = value;
      exif.exifIfd['DateTimeOriginal'] = value;
      exif.exifIfd['DateTimeDigitized'] = value;

      exif.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coordinates.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coordinates.longDirection.abbreviation;

      final newBytes = injectJpgExif(bytes, exif);
      if (newBytes == null) return false;

      await file.writeAsBytes(newBytes);
      return true;
    } finally {
      sw.stop();
      nativeCombinedCount++;
      nativeCombinedMs += sw.elapsedMilliseconds;
    }
  }

  // ── ExifTool batch helpers (non-JPEG) ──────────────────────────────────────

  static const _dateKeys = {
    'DateTimeOriginal',
    'DateTimeDigitized',
    'DateTime',
  };

  static bool _hasDateKeys(Map<String, dynamic> tags) =>
      tags.keys.any(_dateKeys.contains);

  static bool _hasGpsKeys(Map<String, dynamic> tags) =>
      tags.keys.any((k) => k.startsWith('GPS'));

  /// Group per-file tags into Date-only, GPS-only, Combined and write each
  /// category in its own batch. This provides precise timing counters per branch.
  Future<void> writeExiftoolBatches(
    Map<File, Map<String, dynamic>> perFileTags, {
    int chunkSize = 48,
  }) async {
    if (perFileTags.isEmpty) return;

    final dateOnly = <File, Map<String, dynamic>>{};
    final gpsOnly = <File, Map<String, dynamic>>{};
    final combined = <File, Map<String, dynamic>>{};

    perFileTags.forEach((file, tags) {
      final hasDate = _hasDateKeys(tags);
      final hasGps = _hasGpsKeys(tags);
      if (hasDate && hasGps) {
        combined[file] = tags;
      } else if (hasDate) {
        dateOnly[file] = tags;
      } else if (hasGps) {
        gpsOnly[file] = tags;
      }
    });

    if (dateOnly.isNotEmpty) {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifDataBatchPerFile(dateOnly, chunkSize: chunkSize);
      sw.stop();
      exiftoolDateCount += dateOnly.length;
      exiftoolDateMs += sw.elapsedMilliseconds;
    }

    if (gpsOnly.isNotEmpty) {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifDataBatchPerFile(gpsOnly, chunkSize: chunkSize);
      sw.stop();
      exiftoolGpsCount += gpsOnly.length;
      exiftoolGpsMs += sw.elapsedMilliseconds;
    }

    if (combined.isNotEmpty) {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifDataBatchPerFile(combined, chunkSize: chunkSize);
      sw.stop();
      exiftoolCombinedCount += combined.length;
      exiftoolCombinedMs += sw.elapsedMilliseconds;
    }
  }

  // ── Convenience helpers used by callers ────────────────────────────────────

  /// Build EXIF date tags in ExifTool syntax for non-JPEG files.
  static Map<String, dynamic> buildDateTags(DateTime dt) {
    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
    final s = exifFormat.format(dt);
    // Quotes are kept for ExifTool compatibility with spaces/colons.
    return {
      'DateTimeOriginal': '"$s"',
      'DateTimeDigitized': '"$s"',
      'DateTime': '"$s"',
    };
  }

  /// Build EXIF GPS tags in ExifTool syntax for non-JPEG files.
  static Map<String, dynamic> buildGpsTags(DMSCoordinates c) {
    return {
      'GPSLatitude': c.toDD().latitude.toString(),
      'GPSLongitude': c.toDD().longitude.toString(),
      'GPSLatitudeRef': c.latDirection.abbreviation.toString(),
      'GPSLongitudeRef': c.longDirection.abbreviation.toString(),
    };
  }

  /// Return true if this file is JPEG by header signature.
  static Future<bool> isJpeg(File file) async {
    final header = await file.openRead(0, 128).first;
    final mime = lookupMimeType(file.path, headerBytes: header);
    return mime == 'image/jpeg';
  }
}
