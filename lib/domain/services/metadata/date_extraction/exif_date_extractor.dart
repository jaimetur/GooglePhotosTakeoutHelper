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

  // Instrumentation
  static int _total = 0;
  static int _videoDirect = 0;
  static int _mimeNativeSupported = 0;
  static int _nativeHeadReads = 0;
  static int _nativeFullReads = 0;
  static int _nativeHit = 0;
  static int _nativeMiss = 0;
  static int _fallbackTried = 0;
  static int _fallbackHit = 0;
  static int _unsupportedDirect = 0;
  static int _exiftoolDirectHit = 0;
  static int _exiftoolFail = 0;

  static Duration _nativeDur = Duration.zero;
  static Duration _exiftoolDur = Duration.zero;
  static int _nativeBytes = 0;

  static String _fmtSec(final Duration d) =>
      (d.inMilliseconds / 1000.0).toStringAsFixed(3) + 's';

  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin, bool fallbackEnabled = false}) {
    final l1 = '[READ-EXIF] calls=$_total | videos=$_videoDirect | nativeSupported=$_mimeNativeSupported | unsupported=$_unsupportedDirect | fallbackEnabled=$fallbackEnabled';
    final l2 = '[READ-EXIF] native: tried=$_mimeNativeSupported, hit=$_nativeHit, miss=$_nativeMiss, headReads=$_nativeHeadReads, fullReads=$_nativeFullReads, time=${(_nativeMs/1000).toStringAsFixed(3)}s, bytes=$_nativeBytes';
    final l3 = '[READ-EXIF] exiftool: directTried=$_exiftoolDirectTried, directHit=$_exiftoolDirectHit, fallbackTried=$_fallbackTried, fallbackHit=$_fallbackHit, time=${(_exiftoolMs/1000).toStringAsFixed(3)}s, errors=$_exiftoolFail';

    if (loggerMixin != null) {
      loggerMixin.logInfo(l1);
      loggerMixin.logInfo(l2);
      loggerMixin.logInfo(l3);
    } else {
      // ignore: avoid_print
      print(l1); print(l2); print(l3);
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
      _nativeDur = Duration.zero;
      _exiftoolDur = Duration.zero;
      _nativeBytes = 0;
    }
  }

  Future<DateTime?> exifDateTimeExtractor(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
    _total++;

    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        'The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    DateTime? result;

    if (mimeType?.startsWith('video/') == true) {
      _videoDirect++;
      if (globalConfig.exifToolInstalled) {
        final sw = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolDur += sw.elapsed;
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
      _mimeNativeSupported++;
      final sw = Stopwatch()..start();
      result = await _nativeExif_readerExtractor(file, mimeType: mimeType);
      _nativeDur += sw.elapsed;

      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      if (globalConfig.exifToolInstalled &&
          globalConfig.fallbackToExifToolOnNativeMiss == true) {
        _fallbackTried++;
        logWarning(
          'Native exif_reader failed to extract DateTime from ${file.path} ($mimeType). Falling back to ExifTool.',
        );
        final sw2 = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        _exiftoolDur += sw2.elapsed;
        if (result != null) {
          _fallbackHit++;
          return result;
        } else {
          _exiftoolFail++;
        }
      }
      return null;
    }

    _unsupportedDirect++;
    if (globalConfig.exifToolInstalled) {
      final sw = Stopwatch()..start();
      result = await _exifToolExtractor(file);
      _exiftoolDur += sw.elapsed;
      if (result != null) {
        _exiftoolDirectHit++;
        return result;
      } else {
        _exiftoolFail++;
      }
    }

    if (mimeType == 'image/jpeg') {
      logWarning(
        '${file.path} has MIME $mimeType but native read failed; file likely corrupt.',
      );
    } else if (globalConfig.exifToolInstalled) {
      logError(
        "$mimeType is an odd MIME type we can't handle. Please open an issue.",
      );
    } else {
      logWarning(
        'Reading exif from ${file.path} with $mimeType skipped. Probably only supported with ExifTool.',
      );
    }
    return result;
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
