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

/// Fast EXIF date extractor (keeps 4.2.2 perf; adds lightweight timings + counters).
class ExifDateExtractor with LoggerMixin {
  ExifDateExtractor(this.exiftool);

  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Instrumentation (static)
  // ────────────────────────────────────────────────────────────────────────────
  static int _total = 0;

  // Decisions
  static int _videoDirect = 0;
  static int _mimeNativeSupported = 0;
  static int _unsupportedDirect = 0;

  // Native
  static int _nativeHeadReads = 0;
  static int _nativeFullReads = 0;
  static int _nativeHit = 0;
  static int _nativeMiss = 0;
  static int _tNativeUs = 0;         // total native time (µs)
  static int _nativeBytes = 0;       // bytes read by native smart reader

  // Fallbacks / ExifTool
  static int _fallbackTried = 0;
  static int _fallbackHit = 0;
  static int _exiftoolDirectHit = 0;
  static int _exiftoolFail = 0;
  static int _tExiftoolVideoUs = 0;        // video/* direct path
  static int _tExiftoolUnsupportedUs = 0;  // unsupported/unknown mime direct path
  static int _tExiftoolFallbackUs = 0;     // after native miss

  static String _s(double seconds) => '${seconds.toStringAsFixed(3)}s';
  static String _sec(int micros) => _s(micros / 1e6);

  /// Pretty printer for READ‑EXIF stats (seconds instead of ms; split lines).
  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin}) {
    final callsLine =
        '[READ-EXIF] calls=$_total | videos=$_videoDirect | nativeSupported=$_mimeNativeSupported | unsupported=$_unsupportedDirect';

    final nativeTried = _mimeNativeSupported;
    final nativeLine =
        '[READ-EXIF] native: headReads=$_nativeHeadReads, fullReads=$_nativeFullReads, '
        'tried=$nativeTried, hit=$_nativeHit, miss=$_nativeMiss, time=${_sec(_tNativeUs)}, bytes=$_nativeBytes';

    final directTried = _videoDirect + _unsupportedDirect;
    final exiftoolTimeUs = _tExiftoolVideoUs + _tExiftoolUnsupportedUs + _tExiftoolFallbackUs;
    final exiftoolLine =
        '[READ-EXIF] exiftool: directTried=$directTried, directHit=$_exiftoolDirectHit, '
        'fallbackTried=$_fallbackTried, fallbackHit=$_fallbackHit, time=${_sec(exiftoolTimeUs)}, errors=$_exiftoolFail';

    final out = loggerMixin?.logInfo ?? (String m, {bool? forcePrint}) { print(m); };
    out(callsLine, forcePrint: true);
    out(nativeLine, forcePrint: true);
    out(exiftoolLine, forcePrint: true);

    if (reset) {
      _total = 0;
      _videoDirect = 0;
      _mimeNativeSupported = 0;
      _unsupportedDirect = 0;
      _nativeHeadReads = 0;
      _nativeFullReads = 0;
      _nativeHit = 0;
      _nativeMiss = 0;
      _tNativeUs = 0;
      _nativeBytes = 0;
      _fallbackTried = 0;
      _fallbackHit = 0;
      _exiftoolDirectHit = 0;
      _exiftoolFail = 0;
      _tExiftoolVideoUs = 0;
      _tExiftoolUnsupportedUs = 0;
      _tExiftoolFallbackUs = 0;
    }
  }

  /// Main entry (keeps 4.2.2 strategy).
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

    // Videos → ExifTool
    if (mimeType?.startsWith('video/') == true) {
      _videoDirect++;
      if (globalConfig.exifToolInstalled) {
        final sw = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        sw.stop();
        _tExiftoolVideoUs += sw.elapsedMicroseconds;

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

    // Native supported
    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      _mimeNativeSupported++;

      final sw = Stopwatch()..start();
      result = await _nativeExif_readerExtractor(file, mimeType: mimeType);
      sw.stop();
      _tNativeUs += sw.elapsedMicroseconds;

      if (result != null) {
        _nativeHit++;
        return result;
      }
      _nativeMiss++;

      // Optional fallback
      if (globalConfig.exifToolInstalled &&
          globalConfig.fallbackToExifToolOnNativeMiss == true) {
        _fallbackTried++;
        logWarning(
          'Native exif_reader failed to extract DateTime from ${file.path} with MIME type $mimeType. '
          'Falling back to ExifTool if available.',
        );

        final sw2 = Stopwatch()..start();
        result = await _exifToolExtractor(file);
        sw2.stop();
        _tExiftoolFallbackUs += sw2.elapsedMicroseconds;

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
      sw.stop();
      _tExiftoolUnsupportedUs += sw.elapsedMicroseconds;

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
        "$mimeType is a weird mime type! Please create an issue if you get this error message, as we currently can't handle it.",
      );
    } else {
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. This is probably only supported with exiftool.',
      );
    }
    return result;
  }

  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) return null;

    try {
      final tags = await exiftool!.readExifData(file);

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

        if (datetime.startsWith('0000:00:00') ||
            datetime.startsWith('0000-00-00')) {
          logDebug(
            "ExifTool returned invalid date '$datetime' for ${file.path}. Skipping this tag.",
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
          if (best == null || parsed.isBefore(best)) {
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

      if (best == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
        logWarning(
          'Extracted DateTime before January 1st 1970 from EXIF for ${file.path}. Therefore the DateTime from other extractors is not being changed.',
        );
        return null;
      } else {
        logDebug('ExifTool chose tag $bestTag with value $best for ${file.path}');
        return best;
      }
    } catch (e) {
      logError('exiftool read failed: ${e.toString()}');
      return null;
    }
  }

  /// Native extractor (smart 64KB head or full read for tail-heavy formats).
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

    final tags = await readExifFromBytes(read.bytes);

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
            'Extracted DateTime before January 1st 1970 from EXIF for ${file.path}. Therefore the DateTime from other extractors is not being changed.',
          );
          return null;
        }
        logDebug('exif_reader chose tag ${e.key} with value $parsed for ${file.path}');
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
