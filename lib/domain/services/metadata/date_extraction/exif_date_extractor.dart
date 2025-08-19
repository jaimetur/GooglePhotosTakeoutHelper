// ignore_for_file: non_constant_identifier_names

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:exif_reader/exif_reader.dart';
import 'package:mime/mime.dart';

import '../../../../infrastructure/exiftool_service.dart';
import '../../../../shared/constants.dart';
import '../../../../shared/constants/exif_constants.dart';
import '../../core/global_config_service.dart';
import '../../core/logging_service.dart';

/// Small result wrapper for smart reads.
class _SmartReadResult {
  _SmartReadResult(this.bytes, this.usedHeadOnly);
  final List<int> bytes;
  final bool usedHeadOnly;
}

/// Service for extracting dates from EXIF data (fast-path native + optional fallback).
class ExifDateExtractor with LoggerMixin {
  ExifDateExtractor(this.exiftool);

  /// ExifTool service may be null when not available on the system.
  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Instrumentation (per-process static counters + timers)
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0;                  // files attempted by this extractor
  static int _videoDirect = 0;            // direct exiftool route due to video/*
  static int _mimeNativeSupported = 0;    // files with a native-supported MIME
  static int _unsupportedDirect = 0;      // files routed to exiftool due to unsupported/unknown MIME

  static int _nativeHeadReads = 0;        // native fast head-only reads
  static int _nativeFullReads = 0;        // native full-file reads

  static int _nativeTried = 0;            // equals _mimeNativeSupported
  static int _nativeHit = 0;              // native returned a valid DateTime
  static int _nativeMiss = 0;             // native returned null

  static int _exiftoolDirectTried = 0;    // tried exiftool directly (videos/unsupported)
  static int _exiftoolDirectHit = 0;      // exiftool direct found a date
  static int _fallbackTried = 0;          // native miss re-tried via exiftool
  static int _fallbackHit = 0;            // fallback succeeded
  static int _exiftoolFail = 0;           // exiftool returned null or threw

  static int _nativeBytes = 0;            // total bytes read by native
  static int _nativeMs = 0;               // total ms spent in native parse
  static int _exiftoolMs = 0;             // total ms spent in exiftool parse

  /// Print counters. `fallbackEnabled` helps explain why fallback tried may be 0.
  static void dumpStats({
    bool reset = false,
    LoggerMixin? loggerMixin,
    bool fallbackEnabled = false,
  }) {
    String secs(int ms) => (ms / 1000).toStringAsFixed(3);

    final l1 =
        '[READ-EXIF] calls=$_total | videos=$_videoDirect | nativeSupported=$_mimeNativeSupported | unsupported=$_unsupportedDirect | fallbackEnabled=$fallbackEnabled';
    final l2 =
        '[READ-EXIF] native: tried=$_nativeTried, hit=$_nativeHit, miss=$_nativeMiss, headReads=$_nativeHeadReads, fullReads=$_nativeFullReads, time=${secs(_nativeMs)}s, bytes=$_nativeBytes';
    final l3 =
        '[READ-EXIF] exiftool: directTried=$_exiftoolDirectTried, directHit=$_exiftoolDirectHit, fallbackTried=$_fallbackTried, fallbackHit=$_fallbackHit, time=${secs(_exiftoolMs)}s, errors=$_exiftoolFail';

    if (loggerMixin != null) {
      loggerMixin.logInfo(l1);
      loggerMixin.logInfo(l2);
      loggerMixin.logInfo(l3);
    } else {
      // ignore: avoid_print
      print(l1);
      // ignore: avoid_print
      print(l2);
      // ignore: avoid_print
      print(l3);
    }

    if (reset) {
      _total = 0;
      _videoDirect = 0;
      _mimeNativeSupported = 0;
      _unsupportedDirect = 0;
      _nativeHeadReads = 0;
      _nativeFullReads = 0;
      _nativeTried = 0;
      _nativeHit = 0;
      _nativeMiss = 0;
      _exiftoolDirectTried = 0;
      _exiftoolDirectHit = 0;
      _fallbackTried = 0;
      _fallbackHit = 0;
      _exiftoolFail = 0;
      _nativeBytes = 0;
      _nativeMs = 0;
      _exiftoolMs = 0;
    }
  }

  /// Extract DateTime from EXIF for [file] using native fast-path and optional fallback.
  Future<DateTime?> exifDateTimeExtractor(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
    _total++;

    // Guard against large files if configured
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        'The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    // MIME detection uses only a tiny header
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    DateTime? result;

    // For videos, go straight to ExifTool. Native reader doesn't support them.
    if (mimeType?.startsWith('video/') == true) {
      _videoDirect++;
      final sw = Stopwatch()..start();
      if (globalConfig.exifToolInstalled && exiftool != null) {
        result = await _exifToolExtractor(file);
        _exiftoolMs += sw.elapsedMilliseconds;
        if (result != null) {
          _exiftoolDirectHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      } else {
        _exiftoolMs += sw.elapsedMilliseconds;
      }
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. Reading from this kind of file is only supported with exiftool.',
      );
      return null;
    }

    // If MIME is supported by native reader, try native → optional fallback
    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      _mimeNativeSupported++;
      _nativeTried++;

      final sw = Stopwatch()..start();
      result = await _nativeExif_readerExtractor(file, mimeType: mimeType);
      _nativeMs += sw.elapsedMilliseconds;

      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      // Optional fallback to ExifTool when native misses
      if (globalConfig.exifToolInstalled == true &&
          globalConfig.fallbackToExifToolOnNativeMiss == true &&
          exiftool != null) {
        _fallbackTried++;
        final sw2 = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolMs += sw2.elapsedMilliseconds;
        if (result != null) {
          _fallbackHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      return null;
    }

    // Unsupported or unknown MIME → ExifTool if available
    _unsupportedDirect++;
    if (globalConfig.exifToolInstalled == true && exiftool != null) {
      _exiftoolDirectTried++;
      final sw = Stopwatch()..start();
      result = await _exifToolExtractor(file);
      _exiftoolMs += sw.elapsedMilliseconds;
      if (result != null) {
        _exiftoolDirectHit++;
        return result;
      } else {
        _exiftoolFail++;
      }
    }

    // Tailored messages when nothing worked
    if (mimeType == 'image/jpeg') {
      logWarning(
        '${file.path} has a mimeType of $mimeType. However, could not read it with exif_reader. The file may be corrupt.',
      );
    } else if (globalConfig.exifToolInstalled == true) {
      logError(
        "$mimeType is an unusual mime type we can't handle natively. Please create an issue if you get this often.",
      );
    } else {
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. Reading from this kind of file is likely only supported with exiftool.',
      );
    }
    return null;
  }

  /// Extract DateTime via ExifTool, picking the oldest acceptable tag among candidates.
  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) return null;

    try {
      final tags = await exiftool!.readExifData(file);

      // Candidate tags to probe
      final List<String> candidateKeys = [
        'DateTimeOriginal',
        'CreateDate',
        'DateTime',
        'DateCreated',
        'CreationDate',
        'MediaCreateDate',
        'TrackCreateDate',
        'EncodedDate',
        'MetadataDate',
        'ModifyDate',
      ];

      DateTime? best;
      String? bestTag;

      for (final key in candidateKeys) {
        final dynamic value = tags[key];
        if (value == null) continue;

        String datetime = value.toString();

        // Skip obviously invalid dates
        if (datetime.startsWith('0000:00:00') ||
            datetime.startsWith('0000-00-00')) {
          logDebug(
            "ExifTool returned invalid date '$datetime' for ${file.path}. Skipping this tag.",
          );
          continue;
        }

        // Normalize a parseable ISO-like string (keep to 19 chars, swap first 2 ':' to '-')
        datetime = datetime
            .replaceAll('-', ':')
            .replaceAll('/', ':')
            .replaceAll('.', ':')
            .replaceAll('\\', ':')
            .replaceAll(': ', ':0')
            .substring(0, math.min(datetime.length, 19))
            .replaceFirst(':', '-')
            .replaceFirst(':', '-');

        final DateTime? parsed = DateTime.tryParse(datetime);
        if (parsed != null) {
          if (best == null || parsed.isBefore(best)) {
            best = parsed;
            bestTag = key;
          }
        }
      }

      if (best == null) {
        logWarning(
          "Exiftool couldn't extract an acceptable DateTime for ${file.path}. Tags present: ${tags.keys.join(', ')}",
        );
        return null;
      }

      // Handle special ffmpeg/epoch edge case
      if (best == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
        logWarning(
          'Extracted DateTime before 1970 from EXIF for ${file.path}. Will not override other extractors.',
        );
        return null;
      }

      logDebug('ExifTool chose tag $bestTag with value $best for ${file.path}');
      return best;
    } catch (e) {
      logError('exiftool read failed: ${e.toString()}');
      return null;
    }
  }

  /// Extract DateTime using native exif_reader with smart reads (head-only vs full).
  Future<DateTime?> _nativeExif_readerExtractor(
    final File file, {
    required final String? mimeType,
  }) async {
    final _SmartReadResult read = await _smartReadBytes(file, mimeType);
    if (read.usedHeadOnly) {
      _nativeHeadReads++;
    } else {
      _nativeFullReads++;
    }

    _nativeBytes += read.bytes.length;

    final sw = Stopwatch()..start();
    final tags = await readExifFromBytes(read.bytes);
    final elapsed = sw.elapsedMilliseconds;
    _nativeMs += elapsed;

    // Ordered probe: return upon the first valid tag
    final List<MapEntry<String, String?>> ordered = [
      MapEntry('EXIF DateTimeOriginal', tags['EXIF DateTimeOriginal']?.printable),
      MapEntry('Image DateTime', tags['Image DateTime']?.printable),
      MapEntry('EXIF CreateDate', tags['EXIF CreateDate']?.printable),
      MapEntry('EXIF DateCreated', tags['EXIF DateCreated']?.printable),
      MapEntry('EXIF CreationDate', tags['EXIF CreationDate']?.printable),
      MapEntry('EXIF MediaCreateDate', tags['EXIF MediaCreateDate']?.printable),
      MapEntry('EXIF TrackCreateDate', tags['EXIF TrackCreateDate']?.printable),
      MapEntry('EXIF EncodedDate', tags['EXIF EncodedDate']?.printable),
      MapEntry('EXIF MetadataDate', tags['EXIF MetadataDate']?.printable),
      MapEntry('EXIF ModifyDate', tags['EXIF ModifyDate']?.printable),
    ];

    for (final e in ordered) {
      final String? value = e.value;
      if (value == null || value.isEmpty) continue;

      String datetime = value;

      if (datetime.startsWith('0000:00:00') ||
          datetime.startsWith('0000-00-00')) {
        logInfo(
          "exif_reader returned invalid date '$datetime' for ${file.path}. Skipping this tag.",
        );
        continue;
      }

      datetime = datetime
          .replaceAll('-', ':')
          .replaceAll('/', ':')
          .replaceAll('.', ':')
          .replaceAll('\\', ':')
          .replaceAll(': ', ':0')
          .substring(0, math.min(datetime.length, 19))
          .replaceFirst(':', '-')
          .replaceFirst(':', '-');

      final DateTime? parsed = DateTime.tryParse(datetime);
      if (parsed != null) {
        if (parsed == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
          logWarning(
            'Extracted DateTime before 1970 from EXIF for ${file.path}. Will not override other extractors.',
          );
          return null;
        }
        logDebug('exif_reader chose tag ${e.key} with value $parsed for ${file.path}');
        return parsed;
      }
    }

    return null;
  }

  /// Smart byte reader for native EXIF:
  ///  - Whole file for small files or formats with tail metadata (PNG/WEBP/HEIC/JXL).
  ///  - Otherwise read only the first 64KB.
  Future<_SmartReadResult> _smartReadBytes(
    final File file,
    final String? mimeType,
  ) async {
    const int head = 64 * 1024;
    final int len = await file.length();

    final bool likelyTail = mimeType == 'image/png' ||
        mimeType == 'image/webp' ||
        mimeType == 'image/heic' ||
        mimeType == 'image/jxl';

    if (len <= head || likelyTail) {
      final bytes = await file.readAsBytes(); // one full read
      return _SmartReadResult(bytes, false);
    }

    final bytesBuilder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, head)) {
      bytesBuilder.add(chunk);
    }
    return _SmartReadResult(bytesBuilder.takeBytes(), true);
  }
}
