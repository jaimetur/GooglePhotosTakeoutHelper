import 'dart:io';
import 'dart:typed_data';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:gpth/gpth-lib.dart';

/// Service that writes EXIF data (fast native JPEG path + adaptive exiftool batching).
/// Includes detailed instrumentation of counts and durations (seconds).
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool);

  final ExifToolService _exifTool;

  // ───────────────────── Instrumentation (per-process static) ─────────────────
  // NOTE: Renamed and extended to provide symmetric counters for Native and ExifTool.
  // Native counters
  static int nativeTotalFiles = 0;           // files attempted via native JPEG writer
  static int nativeDateWritten = 0;          // native JPEG DateTime successful writes
  static int nativeGpsWritten = 0;           // native JPEG GPS successful writes
  static int nativeCombinedWritten = 0;      // native JPEG combined Date+GPS successful writes
  static int nativeDateFails = 0;            // native JPEG DateTime write fails
  static int nativeGpsFails = 0;             // native JPEG GPS write fails
  static int nativeCombinedFails = 0;        // native JPEG combined write fails

  // ExifTool counters
  static int exiftoolCalls = 0;              // number of exiftool invocations (attempted)
  static int exifTotalFiles = 0;             // files attempted via exiftool (per-file or in batch)
  static int exifDateWritten = 0;            // exiftool DateTime-only successful writes
  static int exifGpsWritten = 0;             // exiftool GPS-only successful writes
  static int exifCombinedWritten = 0;        // exiftool combined Date+GPS successful writes
  static int exifDateFails = 0;              // exiftool DateTime-only fails
  static int exifGpsFails = 0;               // exiftool GPS-only fails
  static int exifCombinedFails = 0;          // exiftool combined Date+GPS fails

  // Durations
  static Duration nativeDateTimeDur = Duration.zero;
  static Duration nativeGpsDur = Duration.zero;
  static Duration nativeCombinedDur = Duration.zero;
  static Duration exiftoolDateTimeDur = Duration.zero;
  static Duration exiftoolGpsDur = Duration.zero;
  static Duration exiftoolCombinedDur = Duration.zero;

  static String _fmtSec(final Duration d) => '${(d.inMilliseconds / 1000.0).toStringAsFixed(3)}s';

  /// Print instrumentation lines; reset counters optionally.
  /// Labels changed to: totalFiles, dateWritten, gpsWritten, combinedWritten, dateFails, gpsFails, combinedFails
  static void dumpWriterStats({final bool reset = true, final LoggerMixin? logger}) {
    final lines = <String>[
      '[WRITE-EXIF] Native  : totalFiles=$nativeTotalFiles, dateWritten=$nativeDateWritten, gpsWritten=$nativeGpsWritten, combinedWritten=$nativeCombinedWritten, dateFails=$nativeDateFails, gpsFails=$nativeGpsFails, combinedFails=$nativeCombinedFails, dateTime=${_fmtSec(nativeDateTimeDur)}, gpsTime=${_fmtSec(nativeGpsDur)}, combinedTime=${_fmtSec(nativeCombinedDur)}',
      '[WRITE-EXIF] Exiftool: totalFiles=$exifTotalFiles, dateWritten=$exifDateWritten, gpsWritten=$exifGpsWritten, combinedWritten=$exifCombinedWritten, dateFails=$exifDateFails, gpsFails=$exifGpsFails, combinedFails=$exifCombinedFails, dateTime=${_fmtSec(exiftoolDateTimeDur)}, gpsTime=${_fmtSec(exiftoolGpsDur)}, combinedTime=${_fmtSec(exiftoolCombinedDur)}, exiftoolCalls=$exiftoolCalls',
    ];
    print('');
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
      nativeTotalFiles = 0;
      nativeDateWritten = 0;
      nativeGpsWritten = 0;
      nativeCombinedWritten = 0;
      nativeDateFails = 0;
      nativeGpsFails = 0;
      nativeCombinedFails = 0;

      exifTotalFiles = 0;
      exifDateWritten = 0;
      exifGpsWritten = 0;
      exifCombinedWritten = 0;
      exifDateFails = 0;
      exifGpsFails = 0;
      exifCombinedFails = 0;

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
  Future<bool> writeTagsWithExifTool(
    final File file,
    final Map<String, dynamic> tags, {
    final bool countAsCombined = false, // kept for backward compatibility
    final bool isDate = false,          // kept for backward compatibility
    final bool isGps = false,           // kept for backward compatibility
  }) async {
    if (tags.isEmpty) return false;

    // Count attempts up-front
    exiftoolCalls++;
    exifTotalFiles++;

    final sw = Stopwatch()..start();
    try {
      await _exifTool.writeExifData(file, tags);

      // Prefer automatic detection by tags; fallback to legacy flags when ambiguous.
      final _Category cat = _categorizeTags(tags, countAsCombined: countAsCombined, isDate: isDate, isGps: isGps);

      if (cat == _Category.combined) {
        exifCombinedWritten++;
        exiftoolCombinedDur += sw.elapsed;
      } else if (cat == _Category.date) {
        exifDateWritten++;
        exiftoolDateTimeDur += sw.elapsed;
      } else if (cat == _Category.gps) {
        exifGpsWritten++;
        exiftoolGpsDur += sw.elapsed;
      } else {
        // Unknown payload → bucket into Date to avoid losing accounting
        exifDateWritten++;
        exiftoolDateTimeDur += sw.elapsed;
      }

      return true;
    } catch (e) {
      // Silence known benign errors
      if (!_shouldSilenceExiftoolError(e)) logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      // Attribute failure
      final _Category cat = _categorizeTags(tags, countAsCombined: countAsCombined, isDate: isDate, isGps: isGps);
      if (cat == _Category.combined) exifCombinedFails++;
      else if (cat == _Category.date) exifDateFails++;
      else if (cat == _Category.gps) exifGpsFails++;
      else exifDateFails++;
      return false;
    }
  }

  /// Batch write: list of (file -> tags). Counts one exiftool call.
  /// Time attribution is **proportional** across categories to avoid overcount.
  Future<void> writeBatchWithExifTool(
    final List<MapEntry<File, Map<String, dynamic>>> batch, {
    required final bool useArgFileWhenLarge,
  }) async {
    if (batch.isEmpty) return;

    // Count attempts up-front
    exiftoolCalls++;
    exifTotalFiles += batch.length;

    // Categorize entries before executing to attribute time fairly
    int countDate = 0, countGps = 0, countCombined = 0;
    for (final entry in batch) {
      final _Category cat = _categorizeTags(entry.value);
      if (cat == _Category.combined) countCombined++;
      else if (cat == _Category.date) countDate++;
      else if (cat == _Category.gps) countGps++;
    }
    final int totalTagged = (countDate + countGps + countCombined).clamp(1, 1 << 30); // avoid div/0

    final sw = Stopwatch()..start();
    try {
      if (useArgFileWhenLarge) {
        await _exifTool.writeExifDataBatchViaArgFile(batch);
      } else {
        await _exifTool.writeExifDataBatch(batch);
      }

      final elapsed = sw.elapsed;

      // Proportional attribution of durations + increment written counters
      if (countCombined > 0) {
        exifCombinedWritten += countCombined;
        exiftoolCombinedDur += elapsed * (countCombined / totalTagged);
      }
      if (countDate > 0) {
        exifDateWritten += countDate;
        exiftoolDateTimeDur += elapsed * (countDate / totalTagged);
      }
      if (countGps > 0) {
        exifGpsWritten += countGps;
        exiftoolGpsDur += elapsed * (countGps / totalTagged);
      }
    } catch (e) {
      // Keep the failure visible to the caller (Step 5 will split batches),
      // but do not spam with known benign errors.
      if (!_shouldSilenceExiftoolError(e)) logError('Batch exiftool write failed: $e');
      rethrow;
    }
  }

  // ─────────────────────── Native JPEG implementations ───────────────────────

  /// Native JPEG DateTime write (returns true if wrote; false if failed).
  Future<bool> writeDateTimeNativeJpeg(
    final File file,
    final DateTime dateTime,
  ) async {
    nativeTotalFiles++; // count attempt
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) {
        nativeDateFails++;
        return false;
      }

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      exif.imageIfd['DateTime'] = dt;
      exif.exifIfd['DateTimeOriginal'] = dt;
      exif.exifIfd['DateTimeDigitized'] = dt;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) {
        nativeDateFails++;
        return false;
      }

      await file.writeAsBytes(out);
      nativeDateWritten++;
      nativeDateTimeDur += sw.elapsed;
      return true;
    } catch (e) {
      nativeDateFails++;
      logError('Native JPEG DateTime write failed for ${file.path}: $e');
      return false;
    }
  }

  /// Native JPEG GPS write (returns true if wrote; false if failed).
  Future<bool> writeGpsNativeJpeg(
    final File file,
    final DMSCoordinates coords,
  ) async {
    nativeTotalFiles++; // count attempt
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) {
        nativeGpsFails++;
        return false;
      }

      exif.gpsIfd.gpsLatitude = coords.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coords.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coords.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coords.longDirection.abbreviation;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) {
        nativeGpsFails++;
        return false;
      }

      await file.writeAsBytes(out);
      nativeGpsWritten++;
      nativeGpsDur += sw.elapsed;
      logInfo('[WRITE-EXIF] GPS written natively (JPEG): ${file.path}');
      return true;
    } catch (e) {
      nativeGpsFails++;
      logError('Native JPEG GPS write failed for ${file.path}: $e');
      return false;
    }
  }

  /// Native JPEG combined write (Date+GPS). Returns true if wrote; false if failed.
  Future<bool> writeCombinedNativeJpeg(
    final File file,
    final DateTime dateTime,
    final DMSCoordinates coords,
  ) async {
    nativeTotalFiles++; // count attempt
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) {
        nativeCombinedFails++;
        return false;
      }

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
      if (out == null) {
        nativeCombinedFails++;
        return false;
      }

      await file.writeAsBytes(out);
      nativeCombinedWritten++;
      nativeCombinedDur += sw.elapsed;
      logInfo('[WRITE-EXIF] Date+GPS written natively (JPEG): ${file.path}');
      return true;
    } catch (e) {
      nativeCombinedFails++;
      logError('Native JPEG combined write failed for ${file.path}: $e');
      return false;
    }
  }

  // ─────────────────────────── Internal helpers ──────────────────────────────

  /// Categorize the tag set into date/gps/combined. Falls back to legacy flags.
  _Category _categorizeTags(
    final Map<String, dynamic> tags, {
    final bool countAsCombined = false,
    final bool isDate = false,
    final bool isGps = false,
  }) {
    // Legacy flags take precedence when explicitly set
    if (countAsCombined) return _Category.combined;
    if (isDate && isGps) return _Category.combined;
    if (isDate) return _Category.date;
    if (isGps) return _Category.gps;

    // Auto-detect by tag keys
    final hasDate = _hasDateTags(tags);
    final hasGps = _hasGpsTags(tags);
    if (hasDate && hasGps) return _Category.combined;
    if (hasDate) return _Category.date;
    if (hasGps) return _Category.gps;
    return _Category.unknown;
  }

  bool _hasDateTags(final Map<String, dynamic> tags) {
    if (tags.isEmpty) return false;
    for (final k in tags.keys) {
      final kk = k.toLowerCase();
      if (kk == 'datetimeoriginal' || kk == 'datetimedigitized' || kk == 'datetime') return true;
    }
    return false;
  }

  bool _hasGpsTags(final Map<String, dynamic> tags) {
    if (tags.isEmpty) return false;
    for (final k in tags.keys) {
      final kk = k.toLowerCase();
      if (kk == 'gpslatitude' || kk == 'gpslongitude' || kk == 'gpslatituderef' || kk == 'gpslongituderef') return true;
    }
    return false;
  }

  /// Silences known noisy/benign ExifTool errors on logs.
  bool _shouldSilenceExiftoolError(Object e) {
    final s = e.toString();
    if (s.contains('Truncated InteropIFD directory')) return true;
    return false;
  }
}

enum _Category { date, gps, combined, unknown }
