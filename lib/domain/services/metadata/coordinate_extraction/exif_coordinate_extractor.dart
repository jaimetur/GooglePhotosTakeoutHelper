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

/// Service for extracting GPS coordinates from EXIF data.
class ExifCoordinateExtractor with LoggerMixin {
  ExifCoordinateExtractor(this.exiftool);

  final ExifToolService? exiftool;

  // ────────────────────────────────────────────────────────────────────────────
  // Instrumentation (static counters + timers)
  // ────────────────────────────────────────────────────────────────────────────
  static int _nativeHit = 0;
  static int _nativeMiss = 0;
  static int _fallbackTried = 0;
  static int _exifToolHit = 0;
  static int _exifToolMiss = 0;
  static int _nativeMs = 0;
  static int _exiftoolMs = 0;

  static void dumpStats({bool reset = false, LoggerMixin? loggerMixin}) {
    String secs(int ms) => (ms / 1000).toStringAsFixed(3);

    final line =
        '[GPS-EXTRACT] native: hit=$_nativeHit, miss=$_nativeMiss, time=${secs(_nativeMs)}s | exiftool: tried=${_fallbackTried}, hit=$_exifToolHit, miss=$_exifToolMiss, time=${secs(_exiftoolMs)}s';

    if (loggerMixin != null) {
      loggerMixin.logInfo(line);
    } else {
      // ignore: avoid_print
      print(line);
    }

    if (reset) {
      _nativeHit = 0;
      _nativeMiss = 0;
      _fallbackTried = 0;
      _exifToolHit = 0;
      _exifToolMiss = 0;
      _nativeMs = 0;
      _exiftoolMs = 0;
    }
  }

  /// Extracts GPS coordinates, trying native exif_reader first for supported images,
  /// then falling back to ExifTool where available (and on videos).
  Future<Map<String, dynamic>?> extractGPSCoordinates(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
    // Enforce file size if configured
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        'The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    // Header sniff for MIME
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    // Videos → ExifTool only
    if (mimeType?.startsWith('video/') == true) {
      if (globalConfig.exifToolInstalled == true && exiftool != null) {
        _fallbackTried++;
        final sw = Stopwatch()..start();
        final r = await _exifToolGPSExtractor(file);
        _exiftoolMs += sw.elapsedMilliseconds;
        if (r != null) {
          _exifToolHit++;
        } else {
          _exifToolMiss++;
        }
        return r;
      }
      return null;
    }

    // Try native if supported
    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      final sw = Stopwatch()..start();
      final r = await _nativeExif_readerGPSExtractor(file);
      _nativeMs += sw.elapsedMilliseconds;
      if (r != null) {
        _nativeHit++;
        return r;
      }
      _nativeMiss++;
      // fallthrough to exiftool (optional)
    }

    // Fallback to ExifTool if available
    if (globalConfig.exifToolInstalled == true && exiftool != null) {
      _fallbackTried++;
      final sw = Stopwatch()..start();
      final r = await _exifToolGPSExtractor(file);
      _exiftoolMs += sw.elapsedMilliseconds;
      if (r != null) {
        _exifToolHit++;
      } else {
        _exifToolMiss++;
      }
      return r;
    }

    return null;
  }

  /// Native exif_reader GPS extraction (fast).
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

  /// ExifTool GPS extraction (broad format support).
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
}
