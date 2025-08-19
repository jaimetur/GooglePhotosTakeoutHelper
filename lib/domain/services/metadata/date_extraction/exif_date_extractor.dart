// FILE: lib/domain/services/metadata/date_extraction/exif_date_extractor.dart
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

/// Service for extracting dates from EXIF data
class ExifDateExtractor with LoggerMixin {
  ExifDateExtractor(this.exiftool);

  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Tiny instrumentation (static per-process)
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0;
  static int _videoDirect = 0;
  static int _mimeNativeSupported = 0;

  static int _nativeHeadReads = 0;
  static int _nativeFullReads = 0;

  static int _nativeTried = 0;
  static int _nativeHit = 0;
  static int _nativeMiss = 0;

  static int _fallbackTried = 0;
  static int _fallbackHit = 0;

  static int _unsupportedDirect = 0;
  static int _exiftoolDirectHit = 0;
  static int _exiftoolFail = 0;

  static int _bytesRead = 0;

  static int _nativeTimeMs = 0;
  static int _exiftoolTimeMs = 0;

  /// Print counters (seconds) in compact form — no extra blank lines.
  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin}) {
    final String calls =
        '[INFO] [READ-EXIF] calls=$_total | videos=$_videoDirect | nativeSupported=$_mimeNativeSupported | unsupported=$_unsupportedDirect';
    final String native =
        '[INFO] [READ-EXIF] native: headReads=$_nativeHeadReads, fullReads=$_nativeFullReads, tried=$_nativeTried, hit=$_nativeHit, miss=$_nativeMiss, time=${(_nativeTimeMs / 1000.0).toStringAsFixed(3)}s, bytes=$_bytesRead';
    final String exiftool =
        '[INFO] [READ-EXIF] exiftool: directTried=${_videoDirect + _unsupportedDirect}, directHit=$_exiftoolDirectHit, fallbackTried=$_fallbackTried, fallbackHit=$_fallbackHit, time=${(_exiftoolTimeMs / 1000.0).toStringAsFixed(3)}s, errors=$_exiftoolFail';

    if (loggerMixin != null) {
      loggerMixin.logInfo(calls);
      loggerMixin.logInfo(native);
      loggerMixin.logInfo(exiftool);
    } else {
      // ignore: avoid_print
      print(calls);
      // ignore: avoid_print
      print(native);
      // ignore: avoid_print
      print(exiftool);
    }

    if (reset) {
      _total = 0;
      _videoDirect = 0;
      _mimeNativeSupported = 0;
      _nativeHeadReads = 0;
      _nativeFullReads = 0;
      _nativeTried = 0;
      _nativeHit = 0;
      _nativeMiss = 0;
      _fallbackTried = 0;
      _fallbackHit = 0;
      _unsupportedDirect = 0;
      _exiftoolDirectHit = 0;
      _exiftoolFail = 0;
      _bytesRead = 0;
      _nativeTimeMs = 0;
      _exiftoolTimeMs = 0;
    }
  }

  /// Extract DateTime from EXIF for [file].
  ///
  /// Strategy:
  /// 1) MIME sniff (header bytes).
  /// 2) If video/* → ExifTool.
  /// 3) If native-supported MIME → native first; optional fallback to ExifTool.
  /// 4) Else → ExifTool (if available).
  Future<DateTime?> exifDateTimeExtractor(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
    _total++;

    // Guard large files if configured
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        'The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    // Only need first 128B for MIME detection
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    DateTime? result;

    // Videos → ExifTool (native exif_reader doesn’t support)
    if (mimeType?.startsWith('video/') == true) {
      _videoDirect++;
      if (globalConfig.exifToolInstalled) {
        final sw = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolTimeMs += sw.elapsedMilliseconds;
        if (result != null) {
          _exiftoolDirectHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. Reading from this kind of file is only supported with exiftool.',
      );
      return null;
    }

    // Supported by native reader → try native first
    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      _mimeNativeSupported++;
      _nativeTried++;

      final sw = Stopwatch()..start();
      result = await _nativeExif_readerExtractor(file, mimeType: mimeType);
      _nativeTimeMs += sw.elapsedMilliseconds;

      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      // Optional fallback to ExifTool when native misses
      if (globalConfig.exifToolInstalled &&
          (globalConfig.fallbackToExifToolOnNativeMiss == true)) {
        _fallbackTried++;
        final sw2 = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolTimeMs += sw2.elapsedMilliseconds;

        if (result != null) {
          _fallbackHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      return null;
    }

    // Unsupported/unknown MIME → ExifTool if available
    _unsupportedDirect++;
    if (globalConfig.exifToolInstalled) {
      final sw = Stopwatch()..start();
      result = await _exifToolExtractor(file);
      _exiftoolTimeMs += sw.elapsedMilliseconds;

      if (result != null) {
        _exiftoolDirectHit++;
        return result;
      } else {
        _exiftoolFail++;
      }
    }

    if (mimeType == 'image/jpeg') {
      logWarning(
        '${file.path} has a mimeType of $mimeType. However, could not read it with exif_reader. The file is probably corrupt.',
      );
    } else if (globalConfig.exifToolInstalled) {
      logError(
        "$mimeType is a weird mime type! Please create an issue if you get this message; we currently can't handle it.",
      );
    } else {
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. Likely only supported with exiftool.',
      );
    }
    return result;
  }

  /// Extracts DateTime using ExifTool (keeps the oldest plausible tag).
  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) return null;

    try {
      final tags = await exiftool!.readExifData(file);

      // Candidate tags
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
      for (final key in candidateKeys) {
        final dynamic value = tags[key];
        if (value == null) continue;

        String datetime = value.toString();

        // Skip obviously invalid dates
        if (datetime.startsWith('0000:00:00') ||
            datetime.startsWith('0000-00-00')) {
          continue;
        }

        // Normalize and parse
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
          }
        }
      }

      if (best == null) {
        return null;
      }

      // Special edge case
      if (best == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
        logWarning(
          'Extracted DateTime before 1970 from EXIF for ${file.path}. Not using it.',
        );
        return null;
      }
      return best;
    } catch (e) {
      logError('exiftool read failed: ${e.toString()}');
      return null;
    }
  }

  /// Native exif_reader extractor with smart read (head-only vs full).
  Future<DateTime?> _nativeExif_readerExtractor(
    final File file, {
    required final String? mimeType,
  }) async {
    final sr = await _smartReadBytes(file, mimeType);
    if (sr.usedHeadOnly) {
      _nativeHeadReads++;
    } else {
      _nativeFullReads++;
    }

    _bytesRead += sr.bytes.length;

    final tags = await readExifFromBytes(sr.bytes);

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
      final String? v = e.value;
      if (v == null || v.isEmpty) continue;

      String datetime = v;

      if (datetime.startsWith('0000:00:00') ||
          datetime.startsWith('0000-00-00')) {
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
            'Extracted DateTime before 1970 from EXIF for ${file.path}. Not using it.',
          );
          return null;
        }
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
