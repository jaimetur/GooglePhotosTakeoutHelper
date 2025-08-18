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
  /// Creates a new instance of ExifDateExtractor
  ExifDateExtractor(this.exiftool);

  /// The ExifTool service instance (can be null if ExifTool is not available)
  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Tiny instrumentation (per-process static counters)
  // Call ExifDateExtractor.dumpStats() to print & optionally reset.
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0;
  static int _videoDirect = 0;
  static int _mimeNativeSupported = 0;

  static int _nativeHeadReads = 0;
  static int _nativeFullReads = 0;

  static int _nativeHit = 0;        // native returned a DateTime
  static int _nativeMiss = 0;       // native returned null

  static int _fallbackTried = 0;    // native miss + fallback enabled
  static int _fallbackHit = 0;      // fallback returned a DateTime

  static int _unsupportedDirect = 0;       // unsupported/unknown MIME → ExifTool path taken
  static int _exiftoolDirectHit = 0;       // ExifTool on direct path returned a DateTime
  static int _exiftoolFail = 0;            // ExifTool returned null (any path)

  /// Print counters; pass reset:true to zero them after printing.
  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin}) {
    final String line1 = '[EXIF STATS] total=$_total, videoDirect=$_videoDirect, '
        'mimeNativeSupported=$_mimeNativeSupported';
    final String line2 = '[EXIF STATS] nativeHeadReads=$_nativeHeadReads, nativeFullReads=$_nativeFullReads, '
        'nativeHit=$_nativeHit, nativeMiss=$_nativeMiss';
    final String line3 = '[EXIF STATS] fallbackTried=$_fallbackTried, fallbackHit=$_fallbackHit, '
        'unsupportedDirect=$_unsupportedDirect, exiftoolDirectHit=$_exiftoolDirectHit, exiftoolFail=$_exiftoolFail';

    if (loggerMixin != null) {
      loggerMixin.logInfo(line1, forcePrint: true);
      loggerMixin.logInfo(line2, forcePrint: true);
      loggerMixin.logInfo(line3, forcePrint: true);
    } else {
      // ignore: avoid_print
      print(line1);
      // ignore: avoid_print
      print(line2);
      // ignore: avoid_print
      print(line3);
    }

    if (reset) {
      _total = 0;
      _videoDirect = 0;
      _mimeNativeSupported = 0;
      _nativeHeadReads = 0;
      _nativeFullReads = 0;
      _nativeHit = 0;
      _nativeMiss = 0;
      _fallbackTried = 0;
      _fallbackHit = 0;
      _unsupportedDirect = 0;
      _exiftoolDirectHit = 0;
      _exiftoolFail = 0;
    }
  }

  /// Extract DateTime from EXIF for [file].
  ///
  /// Strategy:
  /// 1) Determine MIME via header bytes.
  /// 2) If video/* → ExifTool (if available).
  /// 3) If MIME is supported natively → try native reader first (smart read).
  ///    - If native returns null, optionally (config) fallback to ExifTool.
  /// 4) If MIME unsupported/unknown → ExifTool (if available).
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
        result = await _exifToolExtractor(file);
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
      result = await _nativeExif_readerExtractor(file, mimeType: mimeType);
      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      // Optional fallback to ExifTool when native misses (default OFF)
      if (globalConfig.exifToolInstalled &&
          globalConfig.fallbackToExifToolOnNativeMiss == true) {
        _fallbackTried++;
        logWarning(
          'Native exif_reader failed to extract DateTime from ${file.path} with MIME type $mimeType. '
              'This format should be supported by exif_reader library. If you see this warning frequently, '
              'please create an issue on GitHub. Falling back to ExifTool if available.',
        );
        result = await _exifToolExtractor(file);
        if (result != null) {
          _fallbackHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      // Native failed and no (or failed) fallback
      return null;
    }

    // Unsupported/unknown MIME → ExifTool if available
    _unsupportedDirect++;
    if (globalConfig.exifToolInstalled) {
      result = await _exifToolExtractor(file);
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
        '${file.path} has a mimeType of $mimeType. However, could not read it with exif_reader. This means, the file is probably corrupt.',
      );
    } else if (globalConfig.exifToolInstalled) {
      logError(
        "$mimeType is a weird mime type! Please create an issue if you get this error message, as we currently can't handle it.",
      );
    } else {
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. Reading from this kind of file is probably only supported with exiftool.',
      );
    }
    return result; // null if nothing found
  }

  /// Extracts DateTime using ExifTool.
  ///
  /// Optimized: keep a running minimum (oldest) rather than building a list and sorting.
  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) {
      return null;
    }

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
          if (best == null || parsed.isBefore(best!)) {
            best = parsed;
            bestTag = key;
          }
        }
      }

      if (best == null) {
        logWarning(
          "Exiftool was not able to extract an acceptable DateTime for ${file.path}.\n\tThose Tags are accepted: 'DateTimeOriginal','DateTime','CreateDate','DateCreated','CreationDate','MediaCreateDate','TrackCreateDate','EncodedDate','MetadataDate','ModifyDate','FileModifyDate'. The file has those Tags: ${tags.toString()}",
        );
        return null;
      }

      final DateTime parsedDateTime = best;

      // Handle special ffmpeg/epoch edge case
      if (parsedDateTime ==
          DateTime.parse('2036-01-01T23:59:59.000000Z')) {
        logWarning(
          'Extracted DateTime before January 1st 1970 from EXIF for ${file.path}. Therefore the DateTime from other extractors is not being changed.',
        );
        return null;
      } else {
        logDebug(
          'ExifTool chose tag $bestTag with value $parsedDateTime for ${file.path}',
        );
        return parsedDateTime;
      }
    } catch (e) {
      logError('exiftool read failed: ${e.toString()}');
      return null;
    }
  }

  /// Extracts DateTime using the native exif_reader library (faster for many formats).
  ///
  /// Uses a smart 2-phase read:
  ///  - For formats that often store metadata at the tail (PNG/WEBP/HEIC/JXL) or small files,
  ///    read the whole file once.
  ///  - Otherwise read only the first 64KB (fast path).
  ///
  /// Returns `null` if no acceptable DateTime is found.
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

    // Empty map if no EXIF — that’s fine.
    final tags = await readExifFromBytes(read.bytes);

    // Ordered probe: return upon the first valid tag
    final List<MapEntry<String, String?>> ordered = [
      MapEntry('EXIF DateTimeOriginal', tags['EXIF DateTimeOriginal']?.printable),
      MapEntry('Image DateTime',       tags['Image DateTime']?.printable),
      MapEntry('EXIF CreateDate',      tags['EXIF CreateDate']?.printable),
      MapEntry('EXIF DateCreated',     tags['EXIF DateCreated']?.printable),
      MapEntry('EXIF CreationDate',    tags['EXIF CreationDate']?.printable),
      MapEntry('EXIF MediaCreateDate', tags['EXIF MediaCreateDate']?.printable),
      MapEntry('EXIF TrackCreateDate', tags['EXIF TrackCreateDate']?.printable),
      MapEntry('EXIF EncodedDate',     tags['EXIF EncodedDate']?.printable),
      MapEntry('EXIF MetadataDate',    tags['EXIF MetadataDate']?.printable),
      MapEntry('EXIF ModifyDate',      tags['EXIF ModifyDate']?.printable),
    ];

    for (final e in ordered) {
      final String? value = e.value;
      if (value == null || value.isEmpty) continue;

      String datetime = value;

      // Skip obviously invalid patterns early
      if (datetime.startsWith('0000:00:00') ||
          datetime.startsWith('0000-00-00')) {
        logInfo(
          "exif_reader returned invalid date '$datetime' for ${file.path}. Skipping this tag.",
        );
        continue;
      }

      // Normalize to an ISO-parseable subset (keep timezone if present initially)
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
        if (parsed ==
            DateTime.parse('2036-01-01T23:59:59.000000Z')) {
          logWarning(
            'Extracted DateTime before January 1st 1970 from EXIF for ${file.path}. Therefore the DateTime from other extractors is not being changed.',
          );
          return null;
        }
        logDebug(
          'exif_reader chose tag ${e.key} with value $parsed for ${file.path}',
        );
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
