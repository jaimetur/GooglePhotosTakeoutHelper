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
  // exiftoolCalls removed from public telemetry aggregation to avoid confusion in the new format.

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

  // Fallback marks to correctly classify ExifTool runs as “fallback” (after native failure)
  static final Set<String> _fallbackMarkedDate = <String>{};
  static final Set<String> _fallbackMarkedGps = <String>{};
  static final Set<String> _fallbackMarkedCombined = <String>{};

  static void _resetTouched() {
    _touchedFiles.clear();
    _dateTouchedFiles.clear();
    _gpsTouchedFiles.clear();
    _dateTouchedPrimary.clear();
    _dateTouchedSecondary.clear();
    _gpsTouchedPrimary.clear();
    _gpsTouchedSecondary.clear();
    _primaryHint.clear(); // clear hints as well

    _fallbackMarkedDate.clear();
    _fallbackMarkedGps.clear();
    _fallbackMarkedCombined.clear();

    // Reset new counters
    nativeDateSuccess = 0;
    nativeDateFail = 0;
    nativeDateDur = Duration.zero;

    nativeGpsSuccess = 0;
    nativeGpsFail = 0;
    nativeGpsDur = Duration.zero;

    nativeCombinedSuccess = 0;
    nativeCombinedFail = 0;
    nativeCombinedDur = Duration.zero;

    xtDateDirectSuccess = 0;
    xtDateDirectFail = 0;
    xtDateDirectDur = Duration.zero;

    xtGpsDirectSuccess = 0;
    xtGpsDirectFail = 0;
    xtGpsDirectDur = Duration.zero;

    xtCombinedDirectSuccess = 0;
    xtCombinedDirectFail = 0;
    xtCombinedDirectDur = Duration.zero;

    xtDateFallbackRecovered = 0;
    xtDateFallbackFail = 0;
    xtDateFallbackDur = Duration.zero;

    xtGpsFallbackRecovered = 0;
    xtGpsFallbackFail = 0;
    xtGpsFallbackDur = Duration.zero;

    xtCombinedFallbackRecovered = 0;
    xtCombinedFallbackFail = 0;
    xtCombinedFallbackDur = Duration.zero;
  }

  // Native path (success/fail split by type)
  // Counts are now grouped by category (DATE, GPS, DATE+GPS) and by Native Direct.
  static int nativeDateSuccess = 0;
  static int nativeDateFail = 0;
  static Duration nativeDateDur = Duration.zero;

  static int nativeGpsSuccess = 0;
  static int nativeGpsFail = 0;
  static Duration nativeGpsDur = Duration.zero;

  static int nativeCombinedSuccess = 0;
  static int nativeCombinedFail = 0;
  static Duration nativeCombinedDur = Duration.zero;

  // ExifTool path (success/fail split by type)
  // IMPORTANT: Fallbacks are counted separately from Direct so the total line excludes fallbacks.
  static int xtDateDirectSuccess = 0;
  static int xtDateDirectFail = 0;
  static Duration xtDateDirectDur = Duration.zero;

  static int xtGpsDirectSuccess = 0;
  static int xtGpsDirectFail = 0;
  static Duration xtGpsDirectDur = Duration.zero;

  static int xtCombinedDirectSuccess = 0;
  static int xtCombinedDirectFail = 0;
  static Duration xtCombinedDirectDur = Duration.zero;

  // Routing breakdown for ExifTool
  // Fallback metrics (files that reached ExifTool because native failed first).
  static int xtDateFallbackRecovered = 0;
  static int xtDateFallbackFail = 0;
  static Duration xtDateFallbackDur = Duration.zero;

  static int xtGpsFallbackRecovered = 0;
  static int xtGpsFallbackFail = 0;
  static Duration xtGpsFallbackDur = Duration.zero;

  static int xtCombinedFallbackRecovered = 0;
  static int xtCombinedFallbackFail = 0;
  static Duration xtCombinedFallbackDur = Duration.zero;

  // Durations helpers
  static String _fmtSec(final Duration d) =>
      '${(d.inMilliseconds / 1000.0).toStringAsFixed(3)}s';

  // NEW: Mirrors for GPS write stats so no dependency on any extractor.
  // These per-tag mirrors are no longer used in the final summary; preserved behaviorally by the unique-file sets above.

  /// Print instrumentation lines; reset counters optionally.
  static void dumpWriterStats({
    final bool reset = true,
    final LoggerMixin? logger,
  }) {
    // Helper for output respecting the original LoggerMixin pattern
    void out(final String s) {
      if (logger != null) {
        logger.logInfo(s, forcePrint: true);
      } else {
        // ignore: avoid_print
        // LoggingService().printPlain(s);
        LoggingService().info(s);
      }
    }

    // Category printer conforming to new format
    void printCategory({
      required final String title,
      required final int nativeOk,
      required final int nativeFail,
      required final Duration nativeDur,
      required final int xtDirectOk,
      required final int xtDirectFail,
      required final Duration xtDirectDur,
      required final int xtFallbackRecovered,
      required final int xtFallbackFail,
      required final Duration xtFallbackDur,
    }) {
      final totalNative = nativeOk + nativeFail;
      final totalDirect = xtDirectOk + xtDirectFail;
      final totalFallback = xtFallbackRecovered + xtFallbackFail;

      out('[Step 7/8]    $title');
      out('[Step 7/8]         Native Direct    : Total: $totalNative (Success: $nativeOk, Fails: $nativeFail) - Time: ${_fmtSec(nativeDur)}');
      out('[Step 7/8]         Exiftool Direct  : Total: $totalDirect (Success: $xtDirectOk, Fails: $xtDirectFail) - Time: ${_fmtSec(xtDirectDur)}');
      out('[Step 7/8]         Exiftool Fallback: Total: $totalFallback (Recovered: $xtFallbackRecovered, Fails: $xtFallbackFail) - Time: ${_fmtSec(xtFallbackDur)}');

      // Total excludes fallbacks to avoid double counting the same files twice.
      final totalOk = nativeOk + xtDirectOk;
      final totalFail = nativeFail + xtDirectFail;
      final total = totalOk + totalFail;
      final totalTime = _fmtSec(nativeDur + xtDirectDur);
      out('[Step 7/8]         Total Files      : Total: $total (Success: $totalOk, Fails: $totalFail) - Time: $totalTime');
    }

    // Header
    out('[Step 7/8] === Telemetry Summary ===');

    // DATE+GPS
    printCategory(
      title: '[WRITE DATE+GPS]:',
      nativeOk: nativeCombinedSuccess,
      nativeFail: nativeCombinedFail,
      nativeDur: nativeCombinedDur,
      xtDirectOk: xtCombinedDirectSuccess,
      xtDirectFail: xtCombinedDirectFail,
      xtDirectDur: xtCombinedDirectDur,
      xtFallbackRecovered: xtCombinedFallbackRecovered,
      xtFallbackFail: xtCombinedFallbackFail,
      xtFallbackDur: xtCombinedFallbackDur,
    );

    // ONLY DATE
    printCategory(
      title: '[WRITE ONLY DATE]:',
      nativeOk: nativeDateSuccess,
      nativeFail: nativeDateFail,
      nativeDur: nativeDateDur,
      xtDirectOk: xtDateDirectSuccess,
      xtDirectFail: xtDateDirectFail,
      xtDirectDur: xtDateDirectDur,
      xtFallbackRecovered: xtDateFallbackRecovered,
      xtFallbackFail: xtDateFallbackFail,
      xtFallbackDur: xtDateFallbackDur,
    );

    // ONLY GPS
    printCategory(
      title: '[WRITE ONLY GPS]:',
      nativeOk: nativeGpsSuccess,
      nativeFail: nativeGpsFail,
      nativeDur: nativeGpsDur,
      xtDirectOk: xtGpsDirectSuccess,
      xtDirectFail: xtGpsDirectFail,
      xtDirectDur: xtGpsDirectDur,
      xtFallbackRecovered: xtGpsFallbackRecovered,
      xtFallbackFail: xtGpsFallbackFail,
      xtFallbackDur: xtGpsFallbackDur,
    );

    if (reset) {
      _resetTouched();
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

  static bool _consumeMarkedFallback(
    final File file, {
    required final bool asDate,
    required final bool asGps,
    required final bool asCombined,
  }) {
    final p = file.path;
    if (asCombined && _fallbackMarkedCombined.remove(p)) return true;
    if (asDate && _fallbackMarkedDate.remove(p)) return true;
    if (asGps && _fallbackMarkedGps.remove(p)) return true;
    return false;
  }

  static bool _peekMarkedFallback(
    final File file, {
    required final bool asDate,
    required final bool asGps,
    required final bool asCombined,
  }) {
    final p = file.path;
    if (asCombined && _fallbackMarkedCombined.contains(p)) return true;
    if (asDate && _fallbackMarkedDate.contains(p)) return true;
    if (asGps && _fallbackMarkedGps.contains(p)) return true;
    return false;
  }

  // Public markers to be called when enqueueing ExifTool after a native failure.
  static void markFallbackDateTried(final File file) {
    _fallbackMarkedDate.add(file.path);
  }

  static void markFallbackCombinedTried(final File file) {
    _fallbackMarkedCombined.add(file.path);
  }

  static void markFallbackGpsTried(final File file) {
    _fallbackMarkedGps.add(file.path);
  }

  // ─────────────────────────── Public helpers ────────────────────────────────

  /// Single-exec write for arbitrary tags (counts success/fail and duration).
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

    try {
      await _exifTool.writeExifData(file, tags);

      final elapsed = sw.elapsed;
      final wasMarkedFallback = _consumeMarkedFallback(
        file,
        asDate: asDate,
        asGps: asGps,
        asCombined: asCombined,
      );

      // Direct vs Fallback routing

      // =============================
      // ExifTool as Native's Fallback
      // =============================
      // 1) Combined: Date+GPS
      if (asCombined) {
        if (wasMarkedFallback || looksFallback) {
          xtCombinedFallbackRecovered++;
          xtCombinedFallbackDur += elapsed;
          logDebug('[Step 7/8] [WRITE-EXIF] Date+GPS written with ExifTool as Fallback of Native writter: ${file.path}');
        } else {
          xtCombinedDirectSuccess++;
          xtCombinedDirectDur += elapsed;
        }
      }
      // 2) Date Only
      else if (asDate) {
        if (wasMarkedFallback || looksFallback) {
          xtDateFallbackRecovered++;
          xtDateFallbackDur += elapsed;
          logDebug('[Step 7/8] [WRITE-EXIF] Date written with ExifTool as Fallback of Native writter: ${file.path}');
        } else {
          xtDateDirectSuccess++;
          xtDateDirectDur += elapsed;
        }
      }
      // 3) GPS Only
      else if (asGps) {
        if (wasMarkedFallback || looksFallback) {
          xtGpsFallbackRecovered++;
          xtGpsFallbackDur += elapsed;
          logDebug('[Step 7/8] [WRITE-EXIF] GPS written with ExifTool as Fallback of Native writter: ${file.path}');
        } else {
          xtGpsDirectSuccess++;
          xtGpsDirectDur += elapsed;
        }
      }

      // =============================
      // ExifTool Direct (no Fallback)
      // =============================
      // Consume primary/secondary hint if present (set in Step 7 when enqueuing/calling ExifTool).
      final bool? hintIsPrimary = _consumePrimaryHint(file);

      // 1) Combined: Date+GPS
      if (asCombined) {
        if (hintIsPrimary != null) {
          markDateTouchedFromStep5(file, isPrimary: hintIsPrimary);
          markGpsTouchedFromStep5(file, isPrimary: hintIsPrimary);
          logDebug('[Step 7/8] [WRITE-EXIF] Date+GPS written with ExifTool: ${file.path}');
        } else {
          _markTouched(file, date: true, gps: true);
        }
      }
      // 2) Date Only
      else if (asDate) {
        if (hintIsPrimary != null) {
          markDateTouchedFromStep5(file, isPrimary: hintIsPrimary);
          logDebug('[Step 7/8] [WRITE-EXIF] Date written with ExifTool: ${file.path}');
        } else {
          _markTouched(file, date: true, gps: false);
        }
      }
      // 3) GPS Only
      else if (asGps) {
        if (hintIsPrimary != null) {
          markGpsTouchedFromStep5(file, isPrimary: hintIsPrimary);
          logDebug('[Step 7/8] [WRITE-EXIF] GPS written with ExifTool: ${file.path}');
        } else {
          _markTouched(file, date: false, gps: true);
        }
      }

      return true;
    }
    // Fails
    catch (e) {
      final elapsed = sw.elapsed;
      final wasMarkedFallback = _consumeMarkedFallback(
        file,
        asDate: asDate,
        asGps: asGps,
        asCombined: asCombined,
      );

      if (asCombined) {
        if (wasMarkedFallback || looksFallback) {
          xtCombinedFallbackFail++;
          xtCombinedFallbackDur += elapsed;
        } else {
          xtCombinedDirectFail++;
          xtCombinedDirectDur += elapsed;
        }
      } else if (asDate) {
        if (wasMarkedFallback || looksFallback) {
          xtDateFallbackFail++;
          xtDateFallbackDur += elapsed;
        } else {
          xtDateDirectFail++;
          xtDateDirectDur += elapsed;
        }
      } else if (asGps) {
        if (wasMarkedFallback || looksFallback) {
          xtGpsFallbackFail++;
          xtGpsFallbackDur += elapsed;
        } else {
          xtGpsDirectFail++;
          xtGpsDirectDur += elapsed;
        }
      }

      logError('[Step 7/8] Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    }
  }

  /// Batch write: list of (file -> tags). Counts one exiftool call.
  /// Time attribution is **proportional** across categories to avoid overcount.
  /// Also splits "direct vs fallback" using the same heuristic per entry.
  Future<void> writeTagsWithExifToolUsingBatch(
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
            bool isFallbackMarked,
          }
        )>[];
    int countDateDirect = 0, countGpsDirect = 0, countCombinedDirect = 0;
    int countDateFallback = 0, countGpsFallback = 0, countCombinedFallback = 0;

    for (final entry in batch) {
      final cls = _classifyTags(entry.value);
      final isFallbackMarked = _peekMarkedFallback(
        entry.key,
        asDate: cls.isDate,
        asGps: cls.isGps,
        asCombined: cls.isCombined,
      );
      entriesMeta.add((
        file: entry.key,
        isDate: cls.isDate,
        isGps: cls.isGps,
        isCombined: cls.isCombined,
        isFallbackMarked: isFallbackMarked,
      ));

      if (cls.isCombined) {
        if (isFallbackMarked) {
          countCombinedFallback++;
        } else {
          countCombinedDirect++;
        }
      } else if (cls.isDate) {
        if (isFallbackMarked) {
          countDateFallback++;
        } else {
          countDateDirect++;
        }
      } else if (cls.isGps) {
        if (isFallbackMarked) {
          countGpsFallback++;
        } else {
          countGpsDirect++;
        }
      }
    }

    final totalTagged =
        (countDateDirect + countGpsDirect + countCombinedDirect +
                countDateFallback + countGpsFallback + countCombinedFallback)
            .clamp(1, 1 << 30);

    final sw = Stopwatch()..start();
    try {
      if (useArgFileWhenLarge) {
        await _exifTool.writeExifDataBatchViaArgFile(batch);
      } else {
        await _exifTool.writeExifDataBatch(batch);
      }

      final elapsed = sw.elapsed;

      // Attribute durations and successes proportionally
      if (countCombinedDirect > 0) {
        xtCombinedDirectSuccess += countCombinedDirect;
        xtCombinedDirectDur += elapsed * (countCombinedDirect / totalTagged);
      }
      if (countCombinedFallback > 0) {
        xtCombinedFallbackRecovered += countCombinedFallback;
        xtCombinedFallbackDur += elapsed * (countCombinedFallback / totalTagged);
      }
      if (countDateDirect > 0) {
        xtDateDirectSuccess += countDateDirect;
        xtDateDirectDur += elapsed * (countDateDirect / totalTagged);
      }
      if (countDateFallback > 0) {
        xtDateFallbackRecovered += countDateFallback;
        xtDateFallbackDur += elapsed * (countDateFallback / totalTagged);
      }
      if (countGpsDirect > 0) {
        xtGpsDirectSuccess += countGpsDirect;
        xtGpsDirectDur += elapsed * (countGpsDirect / totalTagged);
      }
      if (countGpsFallback > 0) {
        xtGpsFallbackRecovered += countGpsFallback;
        xtGpsFallbackDur += elapsed * (countGpsFallback / totalTagged);
      }

      // Mark all entries as touched and consume fallback marks
      for (final m in entriesMeta) {
        final bool? hintIsPrimary = _consumePrimaryHint(m.file);
        // 1) Combined First: Date+GPS
        if (m.isCombined) {
          if (hintIsPrimary != null) {
            markDateTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
            markGpsTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
            logDebug('[Step 7/8] [WRITE-EXIF] Date+GPS written with ExifTool using batches: ${m.file.path}');
          } else {
            _markTouched(m.file, date: true, gps: true);
          }
          _consumeMarkedFallback(m.file, asDate: false, asGps: false, asCombined: true);
        }
        // 2) Date Only
        else if (m.isDate) {
          if (hintIsPrimary != null) {
            markDateTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
            logDebug('[Step 7/8] [WRITE-EXIF] Date written with ExifTool using batches: ${m.file.path}');
          } else {
            _markTouched(m.file, date: true, gps: false);
          }
          _consumeMarkedFallback(m.file, asDate: true, asGps: false, asCombined: false);
        }
        // 3) GPS Only
        else if (m.isGps) {
          if (hintIsPrimary != null) {
            markGpsTouchedFromStep5(m.file, isPrimary: hintIsPrimary);
            logDebug('[Step 7/8] [WRITE-EXIF] GPS written with ExifTool using batches: ${m.file.path}');
          } else {
            _markTouched(m.file, date: false, gps: true);
          }
          _consumeMarkedFallback(m.file, asDate: false, asGps: true, asCombined: false);
        }
      }
    } catch (e) {
      // Batch failed as a whole; Step 7 will split and retry per-file.
      logWarning('[Step 7/8] [WRITE-EXIF] Batch exiftool write failed: $e');
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
        nativeDateFail++;
        nativeDateDur += sw.elapsed;
        return false;
      }

      final fmt = DateFormat('yyyy:MM:dd HH:mm:ss');
      final dt = fmt.format(dateTime);

      exif.imageIfd['DateTime'] = dt;
      exif.exifIfd['DateTimeOriginal'] = dt;
      exif.exifIfd['DateTimeDigitized'] = dt;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) {
        nativeDateFail++;
        nativeDateDur += sw.elapsed;
        return false;
      }

      await file.writeAsBytes(out);
      nativeDateSuccess++;
      nativeDateDur += sw.elapsed;
      _markTouched(file, date: true, gps: false);
      logDebug('[Step 7/8] [WRITE-EXIF] Date written natively (JPEG): ${file.path}');
      return true;
    } catch (e) {
      nativeDateFail++;
      nativeDateDur += sw.elapsed;
      logWarning('[Step 7/8] [WRITE-EXIF] Native JPEG DateTime write failed for ${file.path}: $e');
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
        nativeGpsFail++;
        nativeGpsDur += sw.elapsed;
        return false;
      }

      exif.gpsIfd.gpsLatitude = coords.toDD().latitude;
      exif.gpsIfd.gpsLongitude = coords.toDD().longitude;
      exif.gpsIfd.gpsLatitudeRef = coords.latDirection.abbreviation;
      exif.gpsIfd.gpsLongitudeRef = coords.longDirection.abbreviation;

      final Uint8List? out = injectJpgExif(orig, exif);
      if (out == null) {
        nativeGpsFail++;
        nativeGpsDur += sw.elapsed;
        return false;
      }

      await file.writeAsBytes(out);
      nativeGpsSuccess++;
      nativeGpsDur += sw.elapsed;
      _markTouched(file, date: false, gps: true);
      logDebug('[Step 7/8] [WRITE-EXIF] GPS written natively (JPEG): ${file.path}');
      return true;
    } catch (e) {
      nativeGpsFail++;
      nativeGpsDur += sw.elapsed;
      logWarning('[Step 7/8] [WRITE-EXIF] Native JPEG GPS write failed for ${file.path}: $e');
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
        nativeCombinedFail++;
        nativeCombinedDur += sw.elapsed;
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
        nativeCombinedFail++;
        nativeCombinedDur += sw.elapsed;
        return false;
      }

      await file.writeAsBytes(out);
      nativeCombinedSuccess++;
      nativeCombinedDur += sw.elapsed;
      _markTouched(file, date: true, gps: true);
      logDebug('[Step 7/8] [WRITE-EXIF] Date+GPS written natively (JPEG): ${file.path}');
      return true;
    } catch (e) {
      nativeCombinedFail++;
      nativeCombinedDur += sw.elapsed;
      logWarning('[Step 7/8] [WRITE-EXIF] Native JPEG combined write failed for ${file.path}: $e');
      return false;
    }
  }
}
