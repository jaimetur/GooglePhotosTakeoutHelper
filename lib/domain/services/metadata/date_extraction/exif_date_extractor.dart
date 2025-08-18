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

/// Helper to keep parsed DateTime along with the source tag name.
/// Private to this file.
class _ParsedTag {
  _ParsedTag({required this.tag, required this.dateTime});
  final String tag;
  final DateTime dateTime;
}

/// Service for extracting DateTime from EXIF metadata.
///
/// Instrumentation goals:
///  - Count native reads (tried/hit/miss) and time spent
///  - Count ExifTool reads (direct/fallback) and time spent
///  - Count files skipped for size/video, weird MIME, errors
///  - Track bytes scanned in native path (first 64KB window)
class ExifDateExtractor with LoggerMixin {
  ExifDateExtractor(this.exiftool);

  final ExifToolService? exiftool;

  // ── Instrumentation (static, per run) ──────────────────────────────────────
  static int calls = 0;

  static int nativeTried = 0;
  static int nativeHit = 0;
  static int nativeMiss = 0;

  static int fallbackTried = 0;       // native failed -> exiftool
  static int fallbackHit = 0;

  static int directExiftoolTried = 0; // used exiftool directly (unsupported/unknown MIME, video, etc.)
  static int directExiftoolHit = 0;

  static int exiftoolErrors = 0;

  static int filesOverMaxSkipped = 0;
  static int videoSkipped = 0;
  static int weirdMime = 0;

  static int nativeMs = 0;    // total ms in native reader
  static int exiftoolMs = 0;  // total ms calling exiftool

  static int bytesScanned = 0; // sum of bytes read for native scan window

  /// Print a compact summary for Step 4 (READ EXIF / Date Extraction).
  /// If [reset] is true, all counters are cleared after printing.
  /// If [loggerMixin] is provided, it is used to log; otherwise `print`.
  static void dumpStats({bool reset = true, LoggerMixin? loggerMixin}) {
    final String line1 =
        '[READ-EXIF] calls=$calls | native: tried=$nativeTried, hit=$nativeHit, miss=$nativeMiss, time=${nativeMs}ms, bytes=$bytesScanned';
    final String line2 =
        '[READ-EXIF] exiftool: directTried=$directExiftoolTried, directHit=$directExiftoolHit, '
        'fallbackTried=$fallbackTried, fallbackHit=$fallbackHit, time=${exiftoolMs}ms, errors=$exiftoolErrors';
    final String line3 =
        '[READ-EXIF] skipped: overMax=$filesOverMaxSkipped, video=$videoSkipped, weirdMime=$weirdMime';

    if (loggerMixin != null) {
      // Force print so it shows even without --verbose
      // ignore: invalid_use_of_protected_member
      loggerMixin.logger.info(line1, forcePrint: true);
      // ignore: invalid_use_of_protected_member
      loggerMixin.logger.info(line2, forcePrint: true);
      // ignore: invalid_use_of_protected_member
      loggerMixin.logger.info(line3, forcePrint: true);
    } else {
      // ignore: avoid_print
      print(line1);
      // ignore: avoid_print
      print(line2);
      // ignore: avoid_print
      print(line3);
    }

    if (reset) {
      calls = 0;
      nativeTried = 0;
      nativeHit = 0;
      nativeMiss = 0;
      fallbackTried = 0;
      fallbackHit = 0;
      directExiftoolTried = 0;
      directExiftoolHit = 0;
      exiftoolErrors = 0;
      filesOverMaxSkipped = 0;
      videoSkipped = 0;
      weirdMime = 0;
      nativeMs = 0;
      exiftoolMs = 0;
      bytesScanned = 0;
    }
  }

  /// Extract DateTime from EXIF data for [file].
  ///
  /// Strategy:
  ///  1) If video → try ExifTool directly (if installed).
  ///  2) If MIME is supported natively → native read (fast). If that fails and
  ///     ExifTool is available → ExifTool fallback.
  ///  3) Otherwise (unsupported/unknown MIME) → ExifTool directly (if available).
  Future<DateTime?> exifDateTimeExtractor(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
    calls++;

    // Guard for huge files (optional)
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      filesOverMaxSkipped++;
      logError(
        'The file is larger than the maximum supported file size of '
        '${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    // Read only first 128 bytes for MIME detection
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    // Videos: ExifTool only
    if (mimeType?.startsWith('video/') == true) {
      if (globalConfig.exifToolInstalled) {
        directExiftoolTried++;
        final sw = Stopwatch()..start();
        final result = await _exifToolExtractor(file);
        sw.stop();
        exiftoolMs += sw.elapsedMilliseconds;
        if (result != null) {
          directExiftoolHit++;
          return result;
        }
      }
      videoSkipped++;
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. '
        'Reading from this kind of file is only supported with exiftool.',
      );
      return null;
    }

    // Native path for supported MIME types
    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      nativeTried++;
      final sw = Stopwatch()..start();
      final result = await _nativeExif_readerExtractor(file);
      sw.stop();
      nativeMs += sw.elapsedMilliseconds;

      if (result != null) {
        nativeHit++;
        return result;
      } else {
        nativeMiss++;
        // Fallback to ExifTool if available
        if (globalConfig.exifToolInstalled) {
          fallbackTried++;
          final sw2 = Stopwatch()..start();
          final exiftoolResult = await _exifToolExtractor(file);
          sw2.stop();
          exiftoolMs += sw2.elapsedMilliseconds;

          if (exiftoolResult != null) {
            fallbackHit++;
            return exiftoolResult;
          }
        }
        // Both native and exiftool failed
        return null;
      }
    }

    // Unsupported/unknown MIME: ExifTool directly
    if (globalConfig.exifToolInstalled) {
      directExiftoolTried++;
      final sw = Stopwatch()..start();
      final result = await _exifToolExtractor(file);
      sw.stop();
      exiftoolMs += sw.elapsedMilliseconds;

      if (result != null) {
        directExiftoolHit++;
        return result;
      }
    }

    // Tailored warnings for weird cases
    if (mimeType == 'image/jpeg') {
      logWarning(
        '${file.path} has a mimeType of $mimeType. However, could not read it with exif_reader. '
        'This means, the file is probably corrupt.',
      );
    } else if (globalConfig.exifToolInstalled) {
      weirdMime++;
      logError(
        "$mimeType is a weird mime type! Please create an issue if you get this error message, "
        "as we currently can't handle it.",
      );
    } else {
      logWarning(
        'Reading exif from ${file.path} with mimeType $mimeType skipped. '
        'Reading from this kind of file is probably only supported with exiftool.',
      );
    }

    return null;
  }

  /// ExifTool-based extractor (reads multiple candidate tags).
  Future<DateTime?> _exifToolExtractor(final File file) async {
    if (exiftool == null) return null;

    try {
      final tags = await exiftool!.readExifData(file);
      final List<String> candidateKeys = [
        'DateTimeOriginal',
        'DateTime',
        'CreateDate',
        'DateCreated',
        'CreationDate',
        'MediaCreateDate',
        'TrackCreateDate',
        'EncodedDate',
        'MetadataDate',
        'ModifyDate',
      ];

      final List<_ParsedTag> parsedDates = <_ParsedTag>[];
      for (final key in candidateKeys) {
        final dynamic value = tags[key];
        if (value == null) continue;

        String datetime = value.toString();
        // Skip invalid patterns
        if (datetime.startsWith('0000:00:00') ||
            datetime.startsWith('0000-00-00')) {
          logDebug("ExifTool returned invalid date '$datetime' for ${file.path}. Skipping.");
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
          parsedDates.add(_ParsedTag(tag: key, dateTime: parsed));
        }
      }

      if (parsedDates.isEmpty) {
        logWarning(
          "Exiftool was not able to extract an acceptable DateTime for ${file.path}. "
          "Checked tags: 'DateTimeOriginal','DateTime','CreateDate','DateCreated','CreationDate',"
          "'MediaCreateDate','TrackCreateDate','EncodedDate','MetadataDate','ModifyDate'.",
        );
        return null;
      }

      parsedDates.sort((a, b) => a.dateTime.compareTo(b.dateTime));
      final _ParsedTag chosen = parsedDates.first;
      final DateTime parsedDateTime = chosen.dateTime;

      if (parsedDateTime == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
        logWarning(
          'Extracted DateTime before 1970 from EXIF for ${file.path}. '
          'Therefore the DateTime from other extractors is not being changed.',
        );
        return null;
      }

      logDebug('ExifTool chose tag ${chosen.tag} with value $parsedDateTime for ${file.path}');
      return parsedDateTime;
    } catch (e) {
      exiftoolErrors++;
      logError('exiftool read failed: ${e.toString()}');
      return null;
    }
  }

  /// Native exif_reader extractor (fast). Reads only the first 64KB window.
  Future<DateTime?> _nativeExif_readerExtractor(final File file) async {
    const int exifScanWindow = 64 * 1024; // 64KB
    final int fileLength = await file.length();
    final int end = fileLength < exifScanWindow ? fileLength : exifScanWindow;
    final bytesBuilder = BytesBuilder(copy: false);

    await for (final chunk in file.openRead(0, end)) {
      bytesBuilder.add(chunk);
    }
    final bytes = bytesBuilder.takeBytes();
    bytesScanned += bytes.length;

    final tags = await readExifFromBytes(bytes);

    final Map<String, String?> candidateTags = {
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

    final List<_ParsedTag> parsedDates = <_ParsedTag>[];
    for (final entry in candidateTags.entries) {
      final String key = entry.key;
      final String? value = entry.value;
      if (value == null || value.isEmpty) continue;

      String datetime = value;

      // Skip obviously invalid date patterns
      if (datetime.startsWith('0000:00:00') || datetime.startsWith('0000-00-00')) {
        logInfo("exif_reader returned invalid date '$datetime' for ${file.path}. Skipping.");
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
        parsedDates.add(_ParsedTag(tag: key, dateTime: parsed));
      }
    }

    if (parsedDates.isEmpty) return null;

    parsedDates.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    final _ParsedTag chosen = parsedDates.first;
    final DateTime parsedDateTime = chosen.dateTime;

    if (parsedDateTime == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
      logWarning(
        'Extracted DateTime before 1970 from EXIF for ${file.path}. '
        'Therefore the DateTime from other extractors is not being changed.',
      );
      return null;
    } else {
      logDebug('exif_reader chose tag ${chosen.tag} with value $parsedDateTime for ${file.path}');
      return parsedDateTime;
    }
  }
}
