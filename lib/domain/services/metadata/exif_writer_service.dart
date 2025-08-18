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
import 'date_extraction/exif_date_extractor.dart';

/// Service for writing EXIF data to media files
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool)
      : _coordinateExtractor = ExifCoordinateExtractor(_exifTool);

  final ExifToolService _exifTool;
  final ExifCoordinateExtractor _coordinateExtractor;

  // ── Writer instrumentation counters ─────────────────────────────────────────
  static int exiftoolCalls = 0;        // number of calls to exiftool process
  static int exiftoolFiles = 0;        // number of files handled by exiftool
  static int nativeJpegDateWrites = 0; // native JPEG writes for DateTime
  static int nativeJpegGpsWrites = 0;  // native JPEG writes for GPS
  static int combinedTagWrites = 0;    // number of times date+GPS combined in one call

  /// Print instrumentation stats about EXIF writing
  void dumpWriterStats({bool reset = true}) {
    logInfo(
      '[WRITER] exiftoolCalls=$exiftoolCalls, exiftoolFiles=$exiftoolFiles, '
          'nativeJpegDateWrites=$nativeJpegDateWrites, nativeJpegGpsWrites=$nativeJpegGpsWrites, '
          'combinedTagWrites=$combinedTagWrites',
      forcePrint: true,
    );
    if (reset) {
      exiftoolCalls = 0;
      exiftoolFiles = 0;
      nativeJpegDateWrites = 0;
      nativeJpegGpsWrites = 0;
      combinedTagWrites = 0;
    }
  }

  /// Generic EXIF writing using exiftool (one single call)
  Future<bool> writeTagsWithExifTool(
      File file,
      Map<String, dynamic> tags,
      ) async {
    if (tags.isEmpty) return false;
    try {
      await _exifTool.writeExifData(file, tags);
      exiftoolCalls++;
      exiftoolFiles++;
      logInfo(
        '[Step 5/8] Wrote tags ${tags.keys.toList()} via exiftool: ${file.path}',
      );
      return true;
    } catch (e) {
      logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    }
  }

  /// Compatibility API (used from other places)
  Future<bool> writeExifData(
      final File file,
      final Map<String, dynamic> exifData,
      ) async {
    try {
      await _exifTool.writeExifData(file, exifData);
      exiftoolCalls++;
      exiftoolFiles++;
      return true;
    } catch (e) {
      logError('Failed to write EXIF data to ${file.path}: $e');
      return false;
    }
  }

  /// Write DateTime (tries native JPEG writer first, otherwise exiftool)
  Future<bool> writeDateTimeToExif(
      final DateTime dateTime,
      final File file,
      final GlobalConfigService globalConfig,
      ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader =
    lookupMimeType(file.path, headerBytes: headerBytes);
    final String? mimeTypeFromExtension = lookupMimeType(file.path);

    // Important: we avoid re-reading EXIF to "check" if it already has a date.
    // Trust Step 4: if the date came from EXIF, that step already marked it.

    if (globalConfig.exifToolInstalled) {
      // Try native JPEG writer first
      if (mimeTypeFromHeader == 'image/jpeg' &&
          await _noExifToolDateTimeWriter(
            file,
            dateTime,
            mimeTypeFromHeader,
            globalConfig,
          )) {
        nativeJpegDateWrites++;
        return true;
      }

      if (mimeTypeFromExtension != mimeTypeFromHeader &&
          mimeTypeFromHeader != 'image/tiff') {
        logError(
          "DateWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'.\n"
              'ExifTool would fail on this file due to extension/content mismatch. Consider running GPTH with --fix-extensions to rename files to correct extensions.\n ${file.path}',
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
      try {
        await _exifTool.writeExifData(file, {
          'DateTimeOriginal': '"$dt"',
          'DateTimeDigitized': '"$dt"',
          'DateTime': '"$dt"',
        });
        exiftoolCalls++;
        exiftoolFiles++;
        logInfo(
          '[Step 5/8] New DateTime $dt written to EXIF (exiftool): ${file.path}',
        );
        return true;
      } catch (e) {
        logError(
          '[Step 5/8] DateTime $dt could not be written to EXIF: ${file.path}',
        );
        return false;
      }
    } else {
      return _noExifToolDateTimeWriter(
        file,
        dateTime,
        mimeTypeFromHeader,
        globalConfig,
      );
    }
  }

  /// Write GPS coordinates (tries native JPEG writer first, otherwise exiftool)
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

      if (mimeTypeFromHeader == 'image/jpeg' &&
          await _noExifGPSWriter(
            file,
            coordinates,
            mimeTypeFromHeader,
            globalConfig,
          )) {
        nativeJpegGpsWrites++;
        return true;
      }

      if (mimeTypeFromExtension != mimeTypeFromHeader) {
        logError(
          "GPSWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'.\n"
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

      // Note: the check whether GPS already exists is done outside when needed.
      // This method only writes if explicitly requested.

      try {
        await _exifTool.writeExifData(file, {
          'GPSLatitude': coordinates.toDD().latitude.toString(),
          'GPSLongitude': coordinates.toDD().longitude.toString(),
          'GPSLatitudeRef': coordinates.latDirection.abbreviation.toString(),
          'GPSLongitudeRef': coordinates.longDirection.abbreviation.toString(),
        });
        exiftoolCalls++;
        exiftoolFiles++;
        logInfo('[Step 5/8] New coordinates written to EXIF: ${file.path}');
        return true;
      } catch (e) {
        logError(
          '[Step 5/8] Coordinates ${coordinates.toString()} could not be written to EXIF: ${file.path}',
        );
        return false;
      }
    } else {
      return _noExifGPSWriter(
        file,
        coordinates,
        mimeTypeFromHeader,
        globalConfig,
      );
    }
  }

  // ── Native JPEG implementations ────────────────────────────────────────────

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
