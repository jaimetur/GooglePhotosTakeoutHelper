import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../infrastructure/exiftool_service.dart';
import '../core/global_config_service.dart';
import '../core/logging_service.dart';

/// Service that writes EXIF data (fast native JPEG path + exiftool batching).
/// Includes detailed instrumentation of counts and durations (seconds).
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool);

  final ExifToolService _exifTool;

  // ───────────────────── Instrumentation (per-process static) ─────────────────
  static int exiftoolCalls = 0;            // number of exiftool invocations
  static int exiftoolFiles = 0;            // files written via exiftool
  static int nativeDateWrites = 0;         // native JPEG DateTime writes
  static int nativeGpsWrites = 0;          // native JPEG GPS writes
  static int nativeCombinedWrites = 0;     // native JPEG combined Date+GPS writes
  static int exiftoolDateWrites = 0;       // exiftool DateTime-only writes
  static int exiftoolGpsWrites = 0;        // exiftool GPS-only writes
  static int exiftoolCombinedWrites = 0;   // exiftool combined Date+GPS writes

  static Duration nativeDateTimeDur = Duration.zero;
  static Duration nativeGpsDur = Duration.zero;
  static Duration nativeCombinedDur = Duration.zero;
  static Duration exiftoolDateTimeDur = Duration.zero;
  static Duration exiftoolGpsDur = Duration.zero;
  static Duration exiftoolCombinedDur = Duration.zero;

  static String _fmtSec(final Duration d) =>
      (d.inMilliseconds / 1000.0).toStringAsFixed(3) + 's';

  /// Print instrumentation lines; reset counters optionally.
  static void dumpWriterStats({bool reset = true, LoggerMixin? logger}) {
    final lines = <String>[
      '[WRITE-EXIF] calls=$exiftoolCalls, files=$exiftoolFiles',
      '[WRITE-EXIF] native: '
          'dateWrites=$nativeDateWrites, gpsWrites=$nativeGpsWrites, combined=$nativeCombinedWrites, '
          'dateTime=${_fmtSec(nativeDateTimeDur)}, gpsTime=${_fmtSec(nativeGpsDur)}, combinedTime=${_fmtSec(nativeCombinedDur)}',
      '[WRITE-EXIF] exiftool: '
          'dateWrites=$exiftoolDateWrites, gpsWrites=$exiftoolGpsWrites, combined=$exiftoolCombinedWrites, '
          'dateTime=${_fmtSec(exiftoolDateTimeDur)}, gpsTime=${_fmtSec(exiftoolGpsDur)}, combinedTime=${_fmtSec(exiftoolCombinedDur)}',
    ];
    for (final l in lines) {
      if (logger != null) {
        logger.logInfo(l, forcePrint: true);
      } else {
        // ignore: avoid_print
        print(l);
      }
    }
    if (reset) {
      exiftoolCalls = 0;
      exiftoolFiles = 0;
      nativeDateWrites = 0;
      nativeGpsWrites = 0;
      nativeCombinedWrites = 0;
      exiftoolDateWrites = 0;
      exiftoolGpsWrites = 0;
      exiftoolCombinedWrites = 0;
      nativeDateTimeDur = Duration.zero;
      nativeGpsDur = Duration.zero;
      nativeCombinedDur = Duration.zero;
      exiftoolDateTimeDur = Duration.zero;
      exiftoolGpsDur = Duration.zero;
      exiftoolCombinedDur = Duration.zero;
    }
  }

  // ─────────────────────────── Public helpers ────────────────────────────────

  /// Single-exec write for arbitrary tags (counts as one exiftool call).
  Future<bool> writeTagsWithExifTool(final File file, final Map<String, dynamic> tags,
      {bool countAsCombined = false, bool isDate = false, bool isGps = false}) async {
    if (tags.isEmpty) return false;

    final sw = Stopwatch()..start();
    try {
      await _exifTool.writeExifData(file, tags);
      exiftoolCalls++;
      exiftoolFiles++;

      if (countAsCombined) {
        exiftoolCombinedWrites++;
        exiftoolCombinedDur += sw.elapsed;
      } else {
        if (isDate) {
          exiftoolDateWrites++;
          exiftoolDateTimeDur += sw.elapsed;
        }
        if (isGps) {
          exiftoolGpsWrites++;
          exiftoolGpsDur += sw.elapsed;
        }
      }

      logDebug('Wrote ${tags.keys.toList()} via exiftool: ${file.path}');
      return true;
    } catch (e) {
      logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    }
  }

  /// Batch write: list of (file -> tags). Counts one exiftool call.
  Future<void> writeBatchWithExifTool(
      final List<MapEntry<File, Map<String, dynamic>>> batch) async {
    if (batch.isEmpty) return;
    final sw = Stopwatch()..start();
    try {
      await _exifTool.writeExifDataBatch(batch);
      exiftoolCalls++;
      exiftoolFiles += batch.length;

      // Decide classification per entry
      for (final entry in batch) {
        final keys = entry.value.keys;
        final hasDate = keys.any((k) =>
            k == 'DateTimeOriginal' || k == 'DateTimeDigitized' || k == 'DateTime');
        final hasGps = keys.any((k) =>
            k == 'GPSLatitude' || k == 'GPSLongitude' || k == 'GPSLatitudeRef' || k == 'GPSLongitudeRef');

        if (hasDate && hasGps) {
          exiftoolCombinedWrites++;
          exiftoolCombinedDur += sw.elapsed; // coarse: attribute whole batch time
        } else if (hasDate) {
          exiftoolDateWrites++;
          exiftoolDateTimeDur += sw.elapsed;
        } else if (hasGps) {
          exiftoolGpsWrites++;
          exiftoolGpsDur += sw.elapsed;
        }
      }
    } catch (e) {
      logError('Batch exiftool write failed: $e');
      rethrow;
    }
  }

  // ─────────────────────── Native JPEG implementations ───────────────────────

  /// Native JPEG DateTime write.
  Future<bool> writeDateTimeNativeJpeg(
      final File file, final DateTime dateTime) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) return false;

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      exif.imageIfd['DateTime'] = dt;
      exif.exifIfd['DateTimeOriginal'] = dt;
      exif.exifIfd['DateTimeDigitized'] = dt;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) return false;

      await file.writeAsBytes(out);
      nativeDateWrites++;
      nativeDateTimeDur += sw.elapsed;
      return true;
    } catch (e) {
      logError('Native JPEG DateTime write failed for ${file.path}: $e');
      return false;
    }
  }

  /// Native JPEG GPS write.
  Future<bool> writeGpsNativeJpeg(final File file, final DMSCoordinates coords) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) return false;

      exif.gpsIfd.gpsLatitude = coords.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coords.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coords.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coords.longDirection.abbreviation;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) return false;

      await file.writeAsBytes(out);
      nativeGpsWrites++;
      nativeGpsDur += sw.elapsed;
      return true;
    } catch (e) {
      logError('Native JPEG GPS write failed for ${file.path}: $e');
      return false;
    }
  }

  /// Native JPEG combined write (Date+GPS) to minimize double encoding.
  Future<bool> writeCombinedNativeJpeg(
      final File file, final DateTime dateTime, final DMSCoordinates coords) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) return false;

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      exif.imageIfd['DateTime'] = dt;
      exif.exifIfd['DateTimeOriginal'] = dt;
      exif.exifIfd['DateTimeDigitized'] = dt;

      exif.gpsIfd.gpsLatitude = coords.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coords.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coords.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coords.longDirection.abbreviation;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) return false;

      await file.writeAsBytes(out);
      nativeCombinedWrites++;
      nativeCombinedDur += sw.elapsed;
      return true;
    } catch (e) {
      logError('Native JPEG combined write failed for ${file.path}: $e');
      return false;
    }
  }
}
