// FILE: lib/domain/services/metadata/coordinate_extraction/exif_coordinate_extractor.dart
// ignore_for_file: non_constant_identifier_names

import 'dart:io';
import 'dart:typed_data';

import 'package:exif_reader/exif_reader.dart';
import 'package:mime/mime.dart';

import '../../../../infrastructure/exiftool_service.dart';
import '../../../../shared/constants.dart';
import '../../../../shared/constants/exif_constants.dart';
import '../../core/global_config_service.dart';
import '../../core/logging_service.dart';

/// Service for extracting GPS coordinates from EXIF data (with tiny instrumentation)
class ExifCoordinateExtractor with LoggerMixin {
  ExifCoordinateExtractor(this.exiftool);

  final ExifToolService? exiftool;

  // Stats (per-process)
  static int nativeHit = 0;
  static int nativeMiss = 0;
  static int fallbackTried = 0;
  static int exifToolHit = 0;
  static int exifToolMiss = 0;

  static int nativeTimeMs = 0;
  static int exiftoolTimeMs = 0;

  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin}) {
    final line =
        '[INFO] [GPS Extraction stats]: nativeHit=$nativeHit, nativeMiss=$nativeMiss, fallbackTried=$fallbackTried, exifToolHit=$exifToolHit, exifToolMiss=$exifToolMiss, nativeTime=${(nativeTimeMs / 1000.0).toStringAsFixed(3)}s, exiftoolTime=${(exiftoolTimeMs / 1000.0).toStringAsFixed(3)}s';
    if (loggerMixin != null) {
      loggerMixin.logInfo(line);
    } else {
      // ignore: avoid_print
      print(line);
    }
    if (reset) {
      nativeHit = 0;
      nativeMiss = 0;
      fallbackTried = 0;
      exifToolHit = 0;
      exifToolMiss = 0;
      nativeTimeMs = 0;
      exiftoolTimeMs = 0;
    }
  }

  /// Extracts GPS coordinates (Map) using native reader first if supported; fallback to ExifTool if allowed.
  Future<Map<String, dynamic>?> extractGPSCoordinates(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
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

    // Videos -> go exiftool if available
    if (mimeType?.startsWith('video/') == true) {
      if (globalConfig.exifToolInstalled && exiftool != null) {
        final sw = Stopwatch()..start();
        final tags = await exiftool!.readExifData(file);
        exiftoolTimeMs += sw.elapsedMilliseconds;
        final ok = _gpsFromMap(tags);
        if (ok != null) {
          exifToolHit++;
          return ok;
        } else {
          exifToolMiss++;
        }
      }
      return null;
    }

    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      final sw = Stopwatch()..start();
      final res = await _nativeExif_readerGPSExtractor(file);
      nativeTimeMs += sw.elapsedMilliseconds;
      if (res != null) {
        nativeHit++;
        return res;
      }
      nativeMiss++;

      if (globalConfig.exifToolInstalled && exiftool != null) {
        fallbackTried++;
        final sw2 = Stopwatch()..start();
        final tags = await exiftool!.readExifData(file);
        exiftoolTimeMs += sw2.elapsedMilliseconds;
        final ok = _gpsFromMap(tags);
        if (ok != null) {
          exifToolHit++;
          return ok;
        } else {
          exifToolMiss++;
        }
      }
      return null;
    }

    // Unsupported -> exiftool if available
    if (globalConfig.exifToolInstalled && exiftool != null) {
      final sw = Stopwatch()..start();
      final tags = await exiftool!.readExifData(file);
      exiftoolTimeMs += sw.elapsedMilliseconds;
      final ok = _gpsFromMap(tags);
      if (ok != null) {
        exifToolHit++;
        return ok;
      } else {
        exifToolMiss++;
      }
    }
    return null;
  }

  Map<String, dynamic>? _gpsFromMap(Map<String, dynamic> tags) {
    if (tags['GPSLatitude'] != null && tags['GPSLongitude'] != null) {
      return {
        'GPSLatitude': tags['GPSLatitude'],
        'GPSLongitude': tags['GPSLongitude'],
        'GPSLatitudeRef': tags['GPSLatitudeRef'],
        'GPSLongitudeRef': tags['GPSLongitudeRef'],
      };
    }
    return null;
  }

  /// Native reader path for GPS (fast for many JPEG/TIFF/PNG/etc supported by exif_reader)
  Future<Map<String, dynamic>?> _nativeExif_readerGPSExtractor(
    final File file,
  ) async {
    try {
      // Read a small window (EXIF segments are usually at head for JPEG/TIFF)
      const int exifScanWindow = 64 * 1024; // 64KB
      final int fileLength = await file.length();
      final int end = fileLength < exifScanWindow ? fileLength : exifScanWindow;
      final bytesBuilder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead(0, end)) {
        bytesBuilder.add(chunk);
      }
      final tags = await readExifFromBytes(bytesBuilder.takeBytes());

      final latitude = tags['GPS GPSLatitude']?.printable;
      final longitude = tags['GPS GPSLongitude']?.printable;
      final latRef = tags['GPS GPSLatitudeRef']?.printable;
      final longRef = tags['GPS GPSLongitudeRef']?.printable;

      if (latitude != null && longitude != null) {
        return {
          'GPSLatitude': latitude,
          'GPSLongitude': longitude,
          'GPSLatitudeRef': latRef,
          'GPSLongitudeRef': longRef,
        };
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
