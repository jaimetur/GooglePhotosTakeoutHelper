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

class _SmartReadResult {
  _SmartReadResult(this.bytes, this.usedHeadOnly);
  final List<int> bytes;
  final bool usedHeadOnly;
}

/// Fast + instrumented EXIF Date extractor (4.2.2 behavior preserved).
class ExifDateExtractor with LoggerMixin {
  ExifDateExtractor(this.exiftool);
  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Instrumentation (per-process static counters + timers)
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0;                  // files attempted by this extractor
  static int _videoDirect = 0;            // direct exiftool route due to video/*

  static int _nativeSupported = 0;        // files with a native-supported MIME
  static int _nativeUnsupported = 0;      // files routed to exiftool due to unsupported/unknown MIME
  static int _nativeHeadReads = 0;        // native fast head-only reads
  static int _nativeFullReads = 0;        // native full-file reads
  static int _nativeTried = 0;            // equals _mimeNativeSupported
  static int _nativeHit = 0;              // native returned a valid DateTime
  static int _nativeMiss = 0;             // native returned null

  static int _exiftoolDirectTried = 0;    // tried exiftool directly (videos/unsupported)
  static int _exiftoolDirectHit = 0;      // exiftool direct found a date
  static int _exiftoolFallbackTried = 0;  // native miss re-tried via exiftool
  static int _exiftoolFallbackHit = 0;    // fallback succeeded
  static int _exiftoolFail = 0;           // exiftool returned null or threw

  static int _nativeBytes = 0;            // total bytes read by native

  static Duration _nativeDuration = Duration.zero;
  static Duration _exiftoolDuration = Duration.zero;

  static String _fmtSec(final Duration d) =>
      (d.inMilliseconds / 1000.0).toStringAsFixed(3) + 's';

  static void dumpStats({final bool reset = false, final LoggerMixin? loggerMixin, final bool exiftoolFallbackEnabled = false}) {
    final l1 = '[READ-EXIF] calls=$_total | videos=$_videoDirect | nativeSupported=$_nativeSupported | unsupported=$_nativeUnsupported | exiftoolFallbackEnabled=$exiftoolFallbackEnabled';
    final l2 = '[READ-EXIF] native: tried=$_nativeTried, hit=$_nativeHit, miss=$_nativeMiss, headReads=$_nativeHeadReads, fullReads=$_nativeFullReads, time=${_fmtSec(_nativeDuration)}s, bytes=$_nativeBytes';
    final l3 = '[READ-EXIF] exiftool: directTried=$_exiftoolDirectTried , directHit=$_exiftoolDirectHit, fallbackTried=$_exiftoolFallbackTried, fallbackHit=$_exiftoolFallbackHit, time=${_fmtSec(_exiftoolDuration)}s, errors=$_exiftoolFail';

    if (loggerMixin != null) {
      loggerMixin.logInfo(l1, forcePrint: true);
      loggerMixin.logInfo(l2, forcePrint: true);
      loggerMixin.logInfo(l3, forcePrint: true);
      loggerMixin.logInfo('', forcePrint: true);
    } else {
      // ignore: avoid_print
      print(l1);
      print(l2);
      print(l3);
      print('');
    }

    if (reset) {
      _total = 0;
      _videoDirect = 0;
      _nativeSupported = 0;
      _nativeUnsupported = 0;
      _nativeHeadReads = 0;
      _nativeFullReads = 0;
      _nativeTried = 0;
      _nativeHit = 0;
      _nativeMiss = 0;
      _exiftoolDirectTried = 0;
      _exiftoolDirectHit = 0;
      _exiftoolFallbackTried = 0;
      _exiftoolFallbackHit = 0;
      _exiftoolFail = 0;
      _nativeBytes = 0;
      _nativeDuration = Duration.zero;
      _exiftoolDuration = Duration.zero;
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
      if (globalConfig.exifToolInstalled) {
        final sw = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolDuration += sw.elapsed;
        if (result != null) {
          _exiftoolDirectHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. Only supported with ExifTool.',
      );
      return null;
    }

    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      _nativeSupported++;
      _nativeTried++;

      final sw = Stopwatch()..start();
      result = await _nativeExif_readerExtractor(file, mimeType: mimeType);
      _nativeDuration += sw.elapsed;

      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      // Optional fallback to ExifTool when native misses
      if (globalConfig.exifToolInstalled == true &&
          globalConfig.fallbackToExifToolOnNativeMiss == true &&
          exiftool != null) {
        _exiftoolFallbackTried++;
        logWarning(
          'Native exif_reader failed to extract DateTime from ${file.path} ($mimeType). Falling back to ExifTool.',
        );
        final sw2 = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolDuration += sw2.elapsed;
        if (result != null) {
          _exiftoolFallbackHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      return null;
    }

    // Unsupported or unknown MIME → ExifTool if available
    _nativeUnsupported++;
    if (globalConfig.exifToolInstalled == true && exiftool != null) {
      _exiftoolDirectTried++;
      final sw = Stopwatch()..start();
      result = await _exifToolExtractor(file);
      _exiftoolDuration += sw.elapsed;
      if (result != null) {
        _exiftoolDirectHit++;
        return result;
      } else {
        _exiftoolFail++;
      }
    }

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

  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) return null;
    try {
      final tags = await exiftool!.readExifData(file);

      final List<String> keys = [
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
      for (final k in keys) {
        final v = tags[k];
        if (v == null) continue;

        String s = v.toString();
        if (s.startsWith('0000:00:00') || s.startsWith('0000-00-00')) continue;
        s = s
            .replaceAll('-', ':')
            .replaceAll('/', ':')
            .replaceAll('.', ':')
            .replaceAll('\\', ':')
            .replaceAll(': ', ':0')
            .substring(0, math.min(s.length, 19))
            .replaceFirst(':', '-')
            .replaceFirst(':', '-');
        final parsed = DateTime.tryParse(s);
        if (parsed != null) {
          if (best == null || parsed.isBefore(best)) best = parsed;
        }
      }

      if (best == null) {
        logWarning('ExifTool did not return an acceptable DateTime for ${file.path}.');
        return null;
      }

      if (best == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
        logWarning(
          'Extracted DateTime before 1970 from EXIF for ${file.path}. Skipping.',
        );
        return null;
      }
      return best;
    } catch (e) {
      logError('exiftool read failed: $e');
      return null;
    }
  }

  /// Extract DateTime using native exif_reader with smart reads (head-only vs full).
  Future<DateTime?> _nativeExif_readerExtractor(
    final File file, {
    required final String? mimeType,
  }) async {
    final read = await _smartReadBytes(file, mimeType);
    if (read.usedHeadOnly) {
      _nativeHeadReads++;
    } else {
      _nativeFullReads++;
    }

    final tags = await readExifFromBytes(read.bytes);
    _nativeBytes += read.bytes.length;

    final ordered = <String, String?>{
      'EXIF DateTimeOriginal': tags['EXIF DateTimeOriginal']?.printable,
      'Image DateTime': tags['Image DateTime']?.printable,
      'EXIF CreateDate': tags['EXIF CreateDate']?.printable,
      'EXIF DateCreated': tags['EXIF DateCreated']?.printable,
      'EXIF CreationDate': tags['EXIF CreationDate']?.printable,
      'EXIF MediaCreateDate': tags['EXIF MediaCreateDate']?.printable,
      'EXIF TrackCreateDate': tags['EXIF TrackCreateDate']?.printable,
      'EXIF EncodedDate': tags['EXIF EncodedDate']?.printable,
      'EXIF MetadataDate': tags['EXIF MetadataDate']?.printable,
      'EXIF ModifyDate': tags['EXIF ModifyDate']?.printable,
    };

    for (final entry in ordered.entries) {
      final v = entry.value;
      if (v == null || v.isEmpty) continue;

      var s = v;
      if (s.startsWith('0000:00:00') || s.startsWith('0000-00-00')) continue;

      s = s
          .replaceAll('-', ':')
          .replaceAll('/', ':')
          .replaceAll('.', ':')
          .replaceAll('\\', ':')
          .replaceAll(': ', ':0')
          .substring(0, math.min(s.length, 19))
          .replaceFirst(':', '-')
          .replaceFirst(':', '-');

      final parsed = DateTime.tryParse(s);
      if (parsed != null) {
        if (parsed == DateTime.parse('2036-01-01T23:59:59.000000Z')) return null;
        return parsed;
      }
    }
    return null;
  }

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
      final bytes = await file.readAsBytes();
      return _SmartReadResult(bytes, false);
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(0, head)) {
      builder.add(chunk);
    }
    return _SmartReadResult(builder.takeBytes(), true);
  }
}
