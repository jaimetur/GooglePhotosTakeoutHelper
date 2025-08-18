import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../infrastructure/exiftool_service.dart';
import '../core/global_config_service.dart';
import '../core/logging_service.dart';
import 'coordinate_extraction/exif_coordinate_extractor.dart';

/// Writes EXIF data (keeps perf characteristics; adds per-branch counters + timing in seconds).
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool)
      : _coordinateExtractor = ExifCoordinateExtractor(_exifTool);

  final ExifToolService _exifTool;
  final ExifCoordinateExtractor _coordinateExtractor;

  // ── Instrumentation ─────────────────────────────────────────────────────────
  static int exiftoolCalls = 0;
  static int exiftoolFiles = 0;

  // Per-branch counts
  static int nativeJpegDateWrites = 0;
  static int nativeJpegGpsWrites = 0;
  static int nativeCombinedWrites = 0;   // if you ever add native combined
  static int exiftoolDateWrites = 0;
  static int exiftoolGpsWrites = 0;
  static int exiftoolCombinedWrites = 0;

  // Timing (µs)
  static int _tNativeDateUs = 0;
  static int _tNativeGpsUs = 0;
  static int _tNativeCombinedUs = 0;
  static int _tExiftoolDateUs = 0;
  static int _tExiftoolGpsUs = 0;
  static int _tExiftoolCombinedUs = 0;

  static String _s(double seconds) => '${seconds.toStringAsFixed(3)}s';
  static String _sec(int micros) => _s(micros / 1e6);

  /// Print writer stats (seconds + split lines).
  void dumpWriterStats({bool reset = true}) {
    final callsLine =
        '[WRITE-EXIF] calls=$exiftoolCalls, files=$exiftoolFiles';

    final nativeLine =
        '[WRITE-EXIF] native: dateWrites=$nativeJpegDateWrites, gpsWrites=$nativeJpegGpsWrites, '
        'combined=$nativeCombinedWrites, dateTime=${_sec(_tNativeDateUs)}, gpsTime=${_sec(_tNativeGpsUs)}, combinedTime=${_sec(_tNativeCombinedUs)}';

    final exiftoolLine =
        '[WRITE-EXIF] exiftool: dateWrites=$exiftoolDateWrites, gpsWrites=$exiftoolGpsWrites, '
        'combined=$exiftoolCombinedWrites, dateTime=${_sec(_tExiftoolDateUs)}, gpsTime=${_sec(_tExiftoolGpsUs)}, combinedTime=${_sec(_tExiftoolCombinedUs)}';

    logInfo(callsLine, forcePrint: true);
    logInfo(nativeLine, forcePrint: true);
    logInfo(exiftoolLine, forcePrint: true);

    if (reset) {
      exiftoolCalls = 0;
      exiftoolFiles = 0;
      nativeJpegDateWrites = 0;
      nativeJpegGpsWrites = 0;
      nativeCombinedWrites = 0;
      exiftoolDateWrites = 0;
      exiftoolGpsWrites = 0;
      exiftoolCombinedWrites = 0;
      _tNativeDateUs = 0;
      _tNativeGpsUs = 0;
      _tNativeCombinedUs = 0;
      _tExiftoolDateUs = 0;
      _tExiftoolGpsUs = 0;
      _tExiftoolCombinedUs = 0;
    }
  }

  /// One-shot exiftool write (we infer the branch type from the tag set).
  Future<bool> writeTagsWithExifTool(
    File file,
    Map<String, dynamic> tags,
  ) async {
    if (tags.isEmpty) return false;

    final hasDate = _hasDateKeys(tags);
    final hasGps = _hasGpsKeys(tags);

    final sw = Stopwatch()..start();
    try {
      await _exifTool.writeExifData(file, tags);
      exiftoolCalls++;
      exiftoolFiles++;

      if (hasDate && hasGps) {
        exiftoolCombinedWrites++;
      } else if (hasDate) {
        exiftoolDateWrites++;
      } else if (hasGps) {
        exiftoolGpsWrites++;
      }

      return true;
    } catch (e) {
      logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    } finally {
      sw.stop();
      if (hasDate && hasGps) {
        _tExiftoolCombinedUs += sw.elapsedMicroseconds;
      } else if (hasDate) {
        _tExiftoolDateUs += sw.elapsedMicroseconds;
      } else if (hasGps) {
        _tExiftoolGpsUs += sw.elapsedMicroseconds;
      }
    }
  }

  /// Legacy API compatibility
  Future<bool> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    final hasDate = _hasDateKeys(exifData);
    final hasGps = _hasGpsKeys(exifData);
    final sw = Stopwatch()..start();

    try {
      await _exifTool.writeExifData(file, exifData);
      exiftoolCalls++;
      exiftoolFiles++;
      if (hasDate && hasGps) {
        exiftoolCombinedWrites++;
      } else if (hasDate) {
        exiftoolDateWrites++;
      } else if (hasGps) {
        exiftoolGpsWrites++;
      }
      return true;
    } catch (e) {
      logError('Failed to write EXIF data to ${file.path}: $e');
      return false;
    } finally {
      sw.stop();
      if (hasDate && hasGps) {
        _tExiftoolCombinedUs += sw.elapsedMicroseconds;
      } else if (hasDate) {
        _tExiftoolDateUs += sw.elapsedMicroseconds;
      } else if (hasGps) {
        _tExiftoolGpsUs += sw.elapsedMicroseconds;
      }
    }
  }

  static bool _hasDateKeys(Map<String, dynamic> tags) =>
      tags.containsKey('DateTimeOriginal') ||
      tags.containsKey('DateTimeDigitized') ||
      tags.containsKey('DateTime') ||
      tags.containsKey('CreateDate');

  static bool _hasGpsKeys(Map<String, dynamic> tags) =>
      tags.containsKey('GPSLatitude') ||
      tags.containsKey('GPSLongitude') ||
      tags.containsKey('GPSLatitudeRef') ||
      tags.containsKey('GPSLongitudeRef');

  /// Write DateTime (native for JPEG if possible; otherwise exiftool).
  Future<bool> writeDateTimeToExif(
    final DateTime dateTime,
    final File file,
    final GlobalConfigService globalConfig,
  ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader =
        lookupMimeType(file.path, headerBytes: headerBytes);
    final String? mimeTypeFromExtension = lookupMimeType(file.path);

    if (globalConfig.exifToolInstalled) {
      // Native for JPEG first (fast)
      if (mimeTypeFromHeader == 'image/jpeg') {
        final sw = Stopwatch()..start();
        final ok = await _noExifToolDateTimeWriter(
          file,
          dateTime,
          mimeTypeFromHeader,
          globalConfig,
        );
        sw.stop();
        if (ok) {
          nativeJpegDateWrites++;
          _tNativeDateUs += sw.elapsedMicroseconds;
          return true;
        }
      }

      if (mimeTypeFromExtension != mimeTypeFromHeader &&
          mimeTypeFromHeader != 'image/tiff') {
        logError(
          "DateWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'. "
          'ExifTool would fail on this file due to extension/content mismatch. Consider running GPTH with --fix-extensions.\n ${file.path}',
        );
        return false;
      }

      if (mimeTypeFromExtension == 'video/x-msvideo' ||
          mimeTypeFromHeader == 'video/x-msvideo') {
        logWarning(
          '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
        );
        return false;
      }

      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
      final String dt = exifFormat.format(dateTime);
      final sw = Stopwatch()..start();
      try {
        await _exifTool.writeExifData(file, {
          'DateTimeOriginal': '"$dt"',
          'DateTimeDigitized': '"$dt"',
          'DateTime': '"$dt"',
        });
        exiftoolCalls++;
        exiftoolFiles++;
        exiftoolDateWrites++;
        return true;
      } catch (e) {
        logError(
          '[Step 5/8] DateTime $dt could not be written to EXIF: ${file.path}',
        );
        return false;
      } finally {
        sw.stop();
        _tExiftoolDateUs += sw.elapsedMicroseconds;
      }
    } else {
      final sw = Stopwatch()..start();
      final ok = await _noExifToolDateTimeWriter(
        file,
        dateTime,
        mimeTypeFromHeader,
        globalConfig,
      );
      sw.stop();
      if (ok) {
        nativeJpegDateWrites++;
        _tNativeDateUs += sw.elapsedMicroseconds;
      }
      return ok;
    }
  }

  /// Write GPS (native for JPEG if possible; otherwise exiftool).
  Future<bool> writeGpsToExif(
    final DMSCoordinates coordinates,
    final File file,
    final GlobalConfigService globalConfig,
  ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader =
        lookupMimeType(file.path, headerBytes: headerBytes);

    if (globalConfig.exifToolInstalled) {
      final String? mimeTypeFromExtension = lookupMimeType(file.path);

      if (mimeTypeFromHeader == 'image/jpeg') {
        final sw = Stopwatch()..start();
        final ok = await _noExifGPSWriter(
          file,
          coordinates,
          mimeTypeFromHeader,
          globalConfig,
        );
        sw.stop();
        if (ok) {
          nativeJpegGpsWrites++;
          _tNativeGpsUs += sw.elapsedMicroseconds;
          return true;
        }
      }

      if (mimeTypeFromExtension != mimeTypeFromHeader) {
        logError(
          "GPSWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'. "
          'ExifTool would fail, skipping. You may want to run GPTH with --fix-extensions.\n ${file.path}',
        );
        return false;
      }

      if (mimeTypeFromExtension == 'video/x-msvideo' ||
          mimeTypeFromHeader == 'video/x-msvideo') {
        logWarning(
          '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
        );
        return false;
      }

      final sw = Stopwatch()..start();
      try {
        await _exifTool.writeExifData(file, {
          'GPSLatitude': coordinates.toDD().latitude.toString(),
          'GPSLongitude': coordinates.toDD().longitude.toString(),
          'GPSLatitudeRef': coordinates.latDirection.abbreviation.toString(),
          'GPSLongitudeRef': coordinates.longDirection.abbreviation.toString(),
        });
        exiftoolCalls++;
        exiftoolFiles++;
        exiftoolGpsWrites++;
        logInfo('[Step 5/8] New coordinates written to EXIF: ${file.path}');
        return true;
      } catch (e) {
        logError(
          '[Step 5/8] Coordinates ${coordinates.toString()} could not be written to EXIF: ${file.path}',
        );
        return false;
      } finally {
        sw.stop();
        _tExiftoolGpsUs += sw.elapsedMicroseconds;
      }
    } else {
      final sw = Stopwatch()..start();
      final ok = await _noExifGPSWriter(
        file,
        coordinates,
        mimeTypeFromHeader,
        globalConfig,
      );
      sw.stop();
      if (ok) {
        nativeJpegGpsWrites++;
        _tNativeGpsUs += sw.elapsedMicroseconds;
      }
      return ok;
    }
  }

  // ── Native JPEG implementations ─────────────────────────────────────────────

  Future<bool> _noExifToolDateTimeWriter(
    final File file,
    final DateTime dateTime,
    final String? mimeTypeFromHeader,
    final GlobalConfigService globalConfig,
  ) async {
    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
    final String? mimeTypeFromExtension = lookupMimeType(file.path);

    if (mimeTypeFromHeader == 'image/jpeg') {
      if (mimeTypeFromHeader != mimeTypeFromExtension) {
        logWarning(
          "DateWriter - File has a wrong extension indicating '$mimeTypeFromExtension'"
          " but actually it is '$mimeTypeFromHeader'. Will use native JPEG writer.\n ${file.path}",
        );
      }
      ExifData? exifData;
      final Uint8List origbytes = file.readAsBytesSync();
      try {
        exifData = decodeJpgExif(origbytes);
      } catch (e) {
        logError(
          '[Step 5/8] Found DateTime in json, but missing in EXIF for file: ${file.path}. Failed to write because of error during decoding: $e',
        );
        return false;
      }
      if (exifData != null && !exifData.isEmpty) {
        exifData.imageIfd['DateTime'] = exifFormat.format(dateTime);
        exifData.exifIfd['DateTimeOriginal'] = exifFormat.format(dateTime);
        exifData.exifIfd['DateTimeDigitized'] = exifFormat.format(dateTime);
        final Uint8List? newbytes = injectJpgExif(origbytes, exifData);
        if (newbytes != null) {
          file.writeAsBytesSync(newbytes);
          logInfo(
            '[Step 5/8] New DateTime ${dateTime.toString()} written to EXIF (natively): ${file.path}',
          );
          return true;
        }
      }
    }
    if (!globalConfig.exifToolInstalled) {
      logWarning(
        '[Step 5/8] Found DateTime in json, but missing in EXIF. Writing to $mimeTypeFromHeader is not supported without exiftool.',
      );
    }
    return false;
  }

  Future<bool> _noExifGPSWriter(
    final File file,
    final DMSCoordinates coordinates,
    final String? mimeTypeFromHeader,
    final GlobalConfigService globalConfig,
  ) async {
    if (mimeTypeFromHeader == 'image/jpeg') {
      ExifData? exifData;
      final Uint8List origbytes = file.readAsBytesSync();
      try {
        exifData = decodeJpgExif(origbytes);
      } catch (e) {
        logError(
          '[Step 5/8] Found coordinates in json, but missing in EXIF for file: ${file.path}. Failed to write because of error during decoding: $e',
        );
        return false;
      }
      if (exifData != null && !exifData.isEmpty) {
        try {
          exifData.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
          exifData.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
          exifData.gpsIfd.gpsLatitudeRef =
              coordinates.latDirection.abbreviation;
          exifData.gpsIfd.gpsLongitudeRef =
              coordinates.longDirection.abbreviation;

          final Uint8List? newbytes = injectJpgExif(origbytes, exifData);
          if (newbytes != null) {
            file.writeAsBytesSync(newbytes);
            logInfo(
              '[Step 5/8] New coordinates written to EXIF (natively): ${file.path}',
            );
            return true;
          }
        } catch (e) {
          logError(
            '[Step 5/8] Error writing GPS coordinates to EXIF for file: ${file.path}. Error: $e',
          );
          return false;
        }
      }
    }
    if (!globalConfig.exifToolInstalled) {
      logWarning(
        '[Step 5/8] Found coordinates in json, but missing in EXIF. Writing to $mimeTypeFromHeader is not supported without exiftool.',
      );
    }
    return false;
  }
}
