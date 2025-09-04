import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';

/// Service that writes EXIF data (fast native JPEG path + adaptive exiftool batching).
/// Includes detailed instrumentation of counts and durations (seconds).
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool);

  final ExifToolService _exifTool;

  // ───────────────────── Instrumentation (per-process static) ─────────────────
  // Calls
  static int exiftoolCalls = 0; // number of exiftool invocations

  // Unique file tracking (authoritative for Step 5 final “files got …”)
  static final Set<String> _touchedFiles = <String>{};
  static final Set<String> _dateTouchedFiles = <String>{};
  static final Set<String> _gpsTouchedFiles = <String>{};

  // NEW: split by primary/secondary so Step 5 can show the breakdown in parentheses.
  static final Set<String> _dateTouchedPrimary = <String>{};
  static final Set<String> _dateTouchedSecondary = <String>{};
  static final Set<String> _gpsTouchedPrimary = <String>{};
  static final Set<String> _gpsTouchedSecondary = <String>{};

  // NEW: hint registry (filled by Step 7) to know if a file is primary or secondary when ExifTool succeeds.
  static final Map<String, bool> _primaryHint = <String, bool>{};
  static void setPrimaryHint(final File file, final bool isPrimary) {
    _primaryHint[file.path] = isPrimary;
  }
  static bool? _consumePrimaryHint(final File file) => _primaryHint.remove(file.path);

  static void _markTouched(
    final File file, {
    required final bool date,
    required final bool gps,
  }) {
    final p = file.path;
    _touchedFiles.add(p);
    if (date) _dateTouchedFiles.add(p);
    if (gps) _gpsTouchedFiles.add(p);
  }

  /// NEW: public helpers so Step 5 (who knows primary vs secondary) can annotate the unique sets accordingly.
  static void markDateTouchedFromStep5(
    final File file, {
    required final bool isPrimary,
  }) {
    final p = file.path;
    _touchedFiles.add(p);
    _dateTouchedFiles.add(p);
    if (isPrimary) {
      _dateTouchedPrimary.add(p);
      // If it was already in secondary set (shouldn't happen), keep unique semantics anyway.
      _dateTouchedSecondary.remove(p);
    } else {
      // Only add to secondary if not already marked as primary.
      if (!_dateTouchedPrimary.contains(p)) _dateTouchedSecondary.add(p);
    }
  }

  static void markGpsTouchedFromStep5(
    final File file, {
    required final bool isPrimary,
  }) {
    final p = file.path;
    _touchedFiles.add(p);
    _gpsTouchedFiles.add(p);
    if (isPrimary) {
      _gpsTouchedPrimary.add(p);
      _gpsTouchedSecondary.remove(p);
    } else {
      if (!_gpsTouchedPrimary.contains(p)) _gpsTouchedSecondary.add(p);
    }
  }

  static int get uniqueFilesTouchedCount => _touchedFiles.length;
  static int get uniqueDateFilesCount => _dateTouchedFiles.length;
  static int get uniqueGpsFilesCount => _gpsTouchedFiles.length;

  // NEW: getters for the split
  static int get uniqueDatePrimaryCount => _dateTouchedPrimary.length;
  static int get uniqueDateSecondaryCount => _dateTouchedSecondary.length;
  static int get uniqueGpsPrimaryCount => _gpsTouchedPrimary.length;
  static int get uniqueGpsSecondaryCount => _gpsTouchedSecondary.length;

  static void _resetTouched() {
    _touchedFiles.clear();
    _dateTouchedFiles.clear();
    _gpsTouchedFiles.clear();
    _dateTouchedPrimary.clear();
    _dateTouchedSecondary.clear();
    _gpsTouchedPrimary.clear();
    _gpsTouchedSecondary.clear();
    _primaryHint.clear(); // clear hints as well
  }

  // Native path (success/fail split by type)
  static int nativeWrittenDate = 0;
  static int nativeWrittenGps = 0;
  static int nativeWrittenCombined = 0;
  static int nativeFailsDate = 0;
  static int nativeFailsGps = 0;
  static int nativeFailsCombined = 0;

  // ExifTool path (success/fail split by type)
  // IMPORTANT: “Processed” means success + fail (for symmetry with Native).
  static int exiftoolProcessedFiles = 0; // success + fail (single or batch)
  static int exiftoolSuccessFiles = 0; // success only
  static int exiftoolFailFiles = 0; // fail only

  // Routing breakdown for ExifTool
  static int exiftoolDirectFilesTried =
      0; // sent directly (non-JPEG or decided to go exiftool)
  static int exiftoolFallbackFilesTried =
      0; // routed to exiftool after a native JPEG attempt failed

  // Explicit counters to be bumped at enqueue-time after native failure (called from Step 7).
  static int exiftoolFallbackDateTried = 0;
  static int exiftoolFallbackCombinedTried = 0;

  // ExifTool success by category
  static int exiftoolDateWritten = 0;
  static int exiftoolWrittenGps = 0;
  static int exiftoolWrittenCombined = 0;

  // ExifTool fails by category
  static int exiftoolFailsDate = 0;
  static int exiftoolFailsGps = 0;
  static int exiftoolFailsCombined = 0;

  // Durations
  static Duration nativeDurDate = Duration.zero;
  static Duration nativeDurGps = Duration.zero;
  static Duration nativeDurCombined = Duration.zero;
  static Duration exiftoolDurDate = Duration.zero;
  static Duration exiftoolDurGps = Duration.zero;
  static Duration exiftooDurlCombined = Duration.zero;

  // NEW: Mirrors for GPS write stats so no dependency on any extractor.
  static int _gpsWrittenNative = 0;
  static int _gpsMissNative = 0;
  static int _gpsWrittenExiftool = 0;
  static int _gpsMissExiftool = 0;

  static String _fmtSec(final Duration d) =>
      '${(d.inMilliseconds / 1000.0).toStringAsFixed(3)}s';

  /// Print instrumentation lines; reset counters optionally.
  static void dumpWriterStats({
    final bool reset = true,
    final LoggerMixin? logger,
  }) {
    // Native totals: processed = successes + fails
    final int nativeProcessed =
        nativeWrittenDate +
        nativeWrittenGps +
        nativeWrittenCombined +
        nativeFailsDate +
        nativeFailsGps +
        nativeFailsCombined;

    final lines = <String>[
      '[Step 7/8] Telemetry Summary:',
      '\t[WRITE-EXIF] Native  : totalFiles=$nativeProcessed, writtenDate=$nativeWrittenDate, writtenGPS=$nativeWrittenGps, writtenCombined=$nativeWrittenCombined, failsDate=$nativeFailsDate, failsGPS=$nativeFailsGps, failsCombined=$nativeFailsCombined, timeDate=${_fmtSec(nativeDurDate)}, timeGPS=${_fmtSec(nativeDurGps)}, timeCombined=${_fmtSec(nativeDurCombined)}',
      '\t[WRITE-EXIF] Exiftool: totalFiles=$exiftoolProcessedFiles, writtenDate=$exiftoolDateWritten, writtenGPS=$exiftoolWrittenGps, writtenCombined=$exiftoolWrittenCombined, failsDate=$exiftoolFailsDate, failsGPS=$exiftoolFailsGps, failsCombined=$exiftoolFailsCombined, timeDate=${_fmtSec(exiftoolDurDate)}, timeGPS=${_fmtSec(exiftoolDurGps)}, timeCombined=${_fmtSec(exiftooDurlCombined)}',
      '\t                       (directTried=$exiftoolDirectFilesTried, fallbackDatesTried=$exiftoolFallbackFilesTried, fallbackCombinedTried=$exiftoolFallbackCombinedTried, exiftoolCalls=$exiftoolCalls), (success=$exiftoolSuccessFiles, fail=$exiftoolFailFiles)',
      '\t[WRITE-EXIF-GPS] Native  : writtenNative=$_gpsWrittenNative, missNative=$_gpsMissNative, nativeTime=${_fmtSec(nativeDurGps + nativeDurCombined)}',
      '\t[WRITE-EXIF-GPS] Exiftool: writtenExifTool=$_gpsWrittenExiftool, missExifTool=$_gpsMissExiftool, exiftoolTime=${_fmtSec(exiftoolDurGps + exiftooDurlCombined)} (fallbackTried=${exiftoolFallbackDateTried + exiftoolFallbackCombinedTried})',
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

      _resetTouched();

      nativeWrittenDate = 0;
      nativeWrittenGps = 0;
      nativeWrittenCombined = 0;
      nativeFailsDate = 0;
      nativeFailsGps = 0;
      nativeFailsCombined = 0;

      exiftoolProcessedFiles = 0;
      exiftoolSuccessFiles = 0;
      exiftoolFailFiles = 0;

      exiftoolDirectFilesTried = 0;
      exiftoolFallbackFilesTried = 0;

      // reset explicit "fallback tried" counters
      exiftoolFallbackDateTried = 0;
      exiftoolFallbackCombinedTried = 0;

      exiftoolDateWritten = 0;
      exiftoolWrittenGps = 0;
      exiftoolWrittenCombined = 0;
      exiftoolFailsDate = 0;
      exiftoolFailsGps = 0;
      exiftoolFailsCombined = 0;

      nativeDurDate = Duration.zero;
      nativeDurGps = Duration.zero;
      nativeDurCombined = Duration.zero;
      exiftoolDurDate = Duration.zero;
      exiftoolDurGps = Duration.zero;
      exiftooDurlCombined = Duration.zero;

      // reset WRITE-EXIF-GPS mirrors
      _gpsWrittenNative = 0;
      _gpsMissNative = 0;
      _gpsWrittenExiftool = 0;
      _gpsMissExiftool = 0;
    }
  }

  // ─────────────────────────── Internal helpers ──────────────────────────────

  /// Heuristic: determine if this exiftool write looks like a fallback after a native JPEG attempt.
  /// In current Step 5 implementation, tags for JPEG are only enqueued when native fails.
  static bool _looksLikeFallbackToExiftool(
    final File file,
    final Map<String, dynamic> tags,
  ) {
    final p = file.path.toLowerCase();
    if (!(p.endsWith('.jpg') || p.endsWith('.jpeg'))) return false;
    final keys = tags.keys;
    final hasDate = keys.any(
      (final k) =>
          k == 'DateTimeOriginal' ||
          k == 'DateTimeDigitized' ||
          k == 'DateTime',
    );
    final hasGps = keys.any(
      (final k) =>
          k == 'GPSLatitude' ||
          k == 'GPSLongitude' ||
          k == 'GPSLatitudeRef' ||
          k == 'GPSLongitudeRef',
    );
    return hasDate || hasGps;
  }

  /// Classify tag map into (date/gps/combined) for counters.
  static ({bool isDate, bool isGps, bool isCombined}) _classifyTags(
    final Map<String, dynamic> tags,
  ) {
    final keys = tags.keys;
    final hasDate = keys.any(
      (final k) =>
          k == 'DateTimeOriginal' ||
          k == 'DateTimeDigitized' ||
          k == 'DateTime',
    );
    final hasGps = keys.any(
      (final k) =>
          k == 'GPSLatitude' ||
          k == 'GPSLongitude' ||
          k == 'GPSLatitudeRef' ||
          k == 'GPSLongitudeRef',
    );
    return (
      isDate: hasDate && !hasGps,
      isGps: !hasDate && hasGps,
      isCombined: hasDate && hasGps,
    );
  }

  static void _countExiftoolSuccess(
    final bool isDate,
    final bool isGps,
    final bool isCombined,
    final Duration elapsed,
    final File file,
  ) {
    exiftoolSuccessFiles++;

    // Consume primary/secondary hint if present (set in Step 7 when enqueuing/calling ExifTool).
    final bool? hintIsPrimary = _consumePrimaryHint(file);

    if (isCombined) {
      exiftoolWrittenCombined++;
      exiftooDurlCombined += elapsed;
      if (hintIsPrimary != null) {
        // Use Step 7’s knowledge to split primary/secondary correctly.
        markDateTouchedFromStep5(file, isPrimary: hintIsPrimary);
        markGpsTouchedFromStep5(file, isPrimary: hintIsPrimary);
      } else {
        _markTouched(file, date: true, gps: true);
      }
      // Reflect GPS write stats for WRITE-EXIF-GPS
      _gpsWrittenExiftool++;
    } else {
      if (isDate) {
        exiftoolDateWritten++;
        exiftoolDurDate += elapsed;
        if (hintIsPrimary != null) {
          markDateTouchedFromStep5(file, isPrimary: hintIsPrimary);
        } else {
          _markTouched(file, date: true, gps: false);
        }
      }
      if (isGps) {
        exiftoolWrittenGps++;
        exiftoolDurGps += elapsed;
        if (hintIsPrimary != null) {
          markGpsTouchedFromStep5(file, isPrimary: hintIsPrimary);
        } else {
          _markTouched(file, date: false, gps: true);
        }
        // Reflect GPS write stats for WRITE-EXIF-GPS
        _gpsWrittenExiftool++;
      }
    }
  }

  static void _countExiftoolFail(
    final bool isDate,
    final bool isGps,
    final bool isCombined,
  ) {
    exiftoolFailFiles++;
    if (isCombined) {
      exiftoolFailsCombined++;
      // Combined also implies a GPS write attempt
      _gpsMissExiftool++;
    } else {
      if (isDate) exiftoolFailsDate++;
      if (isGps) {
        exiftoolFailsGps++;
        _gpsMissExiftool++;
      }
    }
  }

  // Public markers to be called when enqueueing ExifTool after a native failure.
  static void markFallbackDateTried(final File file) {
    exiftoolFallbackDateTried++;
  }

  static void markFallbackCombinedTried(final File file) {
    exiftoolFallbackCombinedTried++;
  }

  // ─────────────────────────── Public helpers ────────────────────────────────

  /// Single-exec write for arbitrary tags (counts as one exiftool call).
  Future<bool> writeTagsWithExifTool(
    final File file,
    final Map<String, dynamic> tags, {
    final bool countAsCombined = false, // kept for backward compat, but classification below is preferred
    final bool isDate = false, // kept for backward compat
    final bool isGps = false, // kept for backward compat
  }) async {
    if (tags.isEmpty) return false;

    final sw = Stopwatch()..start();
    final looksFallback = _looksLikeFallbackToExiftool(file, tags);
    final cls = _classifyTags(tags);
    final bool asCombined = countAsCombined || cls.isCombined;
    final bool asDate = isDate || cls.isDate;
    final bool asGps = isGps || cls.isGps;

    // Count as “processed” no matter success or failure (symmetry with Native).
    exiftoolProcessedFiles++;
    if (looksFallback) {
      exiftoolFallbackFilesTried++;
    } else {
      exiftoolDirectFilesTried++;
    }

    try {
      await _exifTool.writeExifData(file, tags);
      exiftoolCalls++;
      _countExiftoolSuccess(asDate, asGps, asCombined, sw.elapsed, file);
      return true;
    } catch (e) {
      _countExiftoolFail(asDate, asGps, asCombined);
      logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    }
  }

  /// Batch write: list of (file -> tags). Counts one exiftool call.
  /// Time attribution is **proportional** across categories to avoid overcount.
  /// Also splits "direct vs fallback" using the same heuristic per entry.
  Future<void> writeBatchWithExifTool(
    final List<MapEntry<File, Map<String, dynamic>>> batch, {
    required final bool useArgFileWhenLarge,
  }) async {
    if (batch.isEmpty) return;

    // Before running the batch, classify every entry so we can record processed and routing consistently.
    final entriesMeta =
        <(
          {
            File file,
            bool isDate,
            bool isGps,
            bool isCombined,
            bool isFallback,
          }
        )>[];
    int countDate = 0, countGps = 0, countCombined = 0;
    int direct = 0, fallback = 0;

    for (final entry in batch) {
      final cls = _classifyTags(entry.value);
      final isFallback = _looksLikeFallbackToExiftool(entry.key, entry.value);
      entriesMeta.add((
        file: entry.key,
        isDate: cls.isDate,
        isGps: cls.isGps,
        isCombined: cls.isCombined,
        isFallback: isFallback,
      ));
      if (cls.isCombined) {
        countCombined++;
      } else if (cls.isDate) {
        countDate++;
      }
      else if (cls.isGps) {
        countGps++;
      }
      if (isFallback) {
        fallback++;
      } else {
        direct++;
      }
    }

    final totalTagged = (countDate + countGps + countCombined).clamp(1, 1 << 30); // avoid div/0
    final sw = Stopwatch()..start();
    try {
      // Increment exiftoolCalls per call, even if it fail.
      exiftoolCalls++;
      if (useArgFileWhenLarge) {
        await _exifTool.writeExifDataBatchViaArgFile(batch);
      } else {
        await _exifTool.writeExifDataBatch(batch);
      }

      // Mark all entries as “processed” and attribute routing now (batch is one attempt).
      exiftoolProcessedFiles += batch.length;
      exiftoolDirectFilesTried += direct;
      exiftoolFallbackFilesTried += fallback;

      final elapsed = sw.elapsed;
      // Proportional time attribution for success totals
      if (countCombined > 0) {
        exiftoolWrittenCombined += countCombined;
        exiftooDurlCombined += elapsed * (countCombined / totalTagged);
      }
      if (countDate > 0) {
        exiftoolDateWritten += countDate;
        exiftoolDurDate += elapsed * (countDate / totalTagged);
      }
      if (countGps > 0) {
        exiftoolWrittenGps += countGps;
        exiftoolDurGps += elapsed * (countGps / totalTagged);
        logDebug('[WRITE-EXIF] GPS written via exiftool (batch): $countGps files');
      }

      // All entries succeeded → count successes and mark unique files by type.
      exiftoolSuccessFiles += batch.length;
      for (final m in entriesMeta) {
        // Consume hint (if present) per file to split primary/secondary correctly.
        final bool? hintIsPrimary = _consumePrimaryHint(m.file);

        if (m.isCombined) {
          if (hintIsPrimary != null) {
            markDateTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
            markGpsTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
          } else {
            _markTouched(m.file, date: true, gps: true);
          }
          _gpsWrittenExiftool++;
        } else if (m.isDate) {
          if (hintIsPrimary != null) {
            markDateTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
          } else {
            _markTouched(m.file, date: true, gps: false);
          }
        } else if (m.isGps) {
          if (hintIsPrimary != null) {
            markGpsTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
          } else {
            _markTouched(m.file, date: false, gps: true);
          }
          _gpsWrittenExiftool++;
        }
      }
    } catch (e) {
      // Batch failed as a whole; Step 5 will split and retry per-file.
      logError('Batch exiftool write failed: $e');
      rethrow;
    }
  }

  // ─────────────────────── Native JPEG implementations ───────────────────────

  /// Native JPEG DateTime write (returns true if wrote; false if failed).
  Future<bool> writeDateTimeNativeJpeg(
    final File file,
    final DateTime dateTime,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) {
        nativeFailsDate++;
        return false;
      }

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      exif.imageIfd['DateTime'] = dt;
      exif.exifIfd['DateTimeOriginal'] = dt;
      exif.exifIfd['DateTimeDigitized'] = dt;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) {
        nativeFailsDate++;
        return false;
      }

      await file.writeAsBytes(out);
      nativeWrittenDate++;
      nativeDurDate += sw.elapsed;
      _markTouched(file, date: true, gps: false);
      return true;
    } catch (e) {
      nativeFailsDate++;
      logError('Native JPEG DateTime write failed for ${file.path}: $e');
      return false;
    }
  }

  /// Native JPEG GPS write (returns true if wrote; false if failed).
  Future<bool> writeGpsNativeJpeg(
    final File file,
    final DMSCoordinates coords,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) {
        nativeFailsGps++;
        _gpsMissNative++;
        return false;
      }

      exif.gpsIfd.gpsLatitude = coords.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coords.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coords.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coords.longDirection.abbreviation;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) {
        nativeFailsGps++;
        _gpsMissNative++;
        return false;
      }

      await file.writeAsBytes(out);
      nativeWrittenGps++;
      nativeDurGps += sw.elapsed;
      _markTouched(file, date: false, gps: true);
      logInfo('[WRITE-EXIF] GPS written natively (JPEG): ${file.path}');
      // Mirror GPS write stats for WRITE-EXIF-GPS
      _gpsWrittenNative++;
      return true;
    } catch (e) {
      nativeFailsGps++;
      _gpsMissNative++;
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
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = await file.readAsBytes();
      final exif = decodeJpgExif(orig);
      if (exif == null || exif.isEmpty) {
        nativeFailsCombined++;
        _gpsMissNative++; // combined includes GPS attempt
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
        nativeFailsCombined++;
        _gpsMissNative++; // combined includes GPS attempt
        return false;
      }

      await file.writeAsBytes(out);
      nativeWrittenCombined++;
      nativeDurCombined += sw.elapsed;
      _markTouched(file, date: true, gps: true);
      logInfo('[WRITE-EXIF] Date+GPS written natively (JPEG): ${file.path}');
      // Mirror GPS write stats for WRITE-EXIF-GPS
      _gpsWrittenNative++;
      return true;
    } catch (e) {
      nativeFailsCombined++;
      _gpsMissNative++; // combined includes GPS attempt
      logError('Native JPEG combined write failed for ${file.path}: $e');
      return false;
    }
  }
}
