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

/// Service for extracting GPS coordinates from EXIF data
class ExifCoordinateExtractor with LoggerMixin {
  ExifCoordinateExtractor(this.exiftool);

  final ExifToolService? exiftool;

  // 📊 Instrumentation counters
  static int nativeHit = 0;
  static int nativeMiss = 0;
  static int fallbackTried = 0;
  static int exifToolHit = 0;
  static int exifToolMiss = 0;

  /// Extracts GPS coordinates from file using optimized method
  Future<Map<String, dynamic>?> extractGPSCoordinates(
      final File file, {
        required final GlobalConfigService globalConfig,
      }) async {
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        'The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(file.path, headerBytes: headerBytes);

    Map<String, dynamic>? result;

    // 🎥 Direct ExifTool for video
    if (mimeType?.startsWith('video/') == true) {
      if (globalConfig.exifToolInstalled) {
        fallbackTried++;
        result = await _exifToolGPSExtractor(file);
        if (result != null) {
          exifToolHit++;
          return result;
        } else {
          exifToolMiss++;
        }
      }
      return null;
    }

    // 📷 Try native first
    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      result = await _nativeExif_readerGPSExtractor(file);
      if (result != null) {
        nativeHit++;
        return result;
      } else {
        nativeMiss++;
        logWarning(
          'Native exif_reader failed to extract GPS coordinates from ${file.path} with MIME type $mimeType. '
              'This format should be supported by exif_reader library. If you see this warning frequently, '
              'please create an issue on GitHub. Falling back to ExifTool if available.',
        );
      }
    }

    // 🛟 Fallback ExifTool
    if (globalConfig.exifToolInstalled) {
      fallbackTried++;
      result = await _exifToolGPSExtractor(file);
      if (result != null) {
        exifToolHit++;
        return result;
      } else {
        exifToolMiss++;
      }
    }

    return result;
  }

  Future<Map<String, dynamic>?> _nativeExif_readerGPSExtractor(
      final File file,
      ) async {
    try {
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

  Future<Map<String, dynamic>?> _exifToolGPSExtractor(final File file) async {
    if (exiftool == null) return null;

    try {
      final tags = await exiftool!.readExifData(file);

      if (tags['GPSLatitude'] != null && tags['GPSLongitude'] != null) {
        return {
          'GPSLatitude': tags['GPSLatitude'],
          'GPSLongitude': tags['GPSLongitude'],
          'GPSLatitudeRef': tags['GPSLatitudeRef'],
          'GPSLongitudeRef': tags['GPSLongitudeRef'],
        };
      }

      return null;
    } catch (e) {
      logError('exiftool GPS read failed: ${e.toString()}');
      return null;
    }
  }

  /// 📊 Dump stats for debugging/benchmarking
  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin}) {
    final msg =
        'GPS Extraction stats: nativeHit=$nativeHit, nativeMiss=$nativeMiss, '
        'fallbackTried=$fallbackTried, exifToolHit=$exifToolHit, exifToolMiss=$exifToolMiss';
    if (loggerMixin != null) {
      loggerMixin.logInfo(msg, forcePrint: true);
    } else {
      print(msg);
    }

    if (reset) {
      nativeHit = 0;
      nativeMiss = 0;
      fallbackTried = 0;
      exifToolHit = 0;
      exifToolMiss = 0;
    }
  }
}
