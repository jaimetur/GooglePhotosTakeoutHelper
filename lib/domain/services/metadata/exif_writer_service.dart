import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:mime/mime.dart';

import '../../../infrastructure/exiftool_service.dart';
import '../core/global_config_service.dart';
import '../core/logging_service.dart';
import 'date_extraction/exif_date_extractor.dart';

/// Service for writing EXIF data to media files
class ExifWriterService with LoggerMixin {
  /// Creates a new EXIF writer service
  ExifWriterService(this._exifTool);

  final ExifToolService _exifTool;

  /// Writes EXIF data to a file
  ///
  /// [file] File to write EXIF data to
  /// [exifData] Map of EXIF tags and values to write
  /// Returns true if successful
  Future<bool> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    try {
      await _exifTool.writeExifData(file, exifData);
      return true;
    } catch (e) {
      logError('Failed to write EXIF data to ${file.path}: $e');
      return false;
    }
  }

  /// Writes DateTime to EXIF metadata
  ///
  /// This method attempts to write DateTime information to a file's EXIF data.
  /// For JPEG files, it first tries a native Dart approach, then falls back
  /// to ExifTool if available. For other formats, ExifTool is required.
  ///
  /// [dateTime] DateTime to write
  /// [file] File to write to
  /// [globalConfig] Global configuration service
  /// Returns true if successful, false if file already has DateTime or write failed
  Future<bool> writeDateTimeToExif(
    final DateTime dateTime,
    final File file,
    final GlobalConfigService globalConfig,
  ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );
    final String? mimeTypeFromExtension = lookupMimeType(
      file.path,
    ); // Check if the file already has a DateTime in its EXIF data
    if (await ExifDateExtractor(
          _exifTool,
        ).exifDateTimeExtractor(file, globalConfig: globalConfig) !=
        null) {
      // File already has DateTime, skip writing
      return false;
    }
    if (globalConfig.exifToolInstalled) {
      // Try native Dart implementation for JPEG files first (faster)
      if (mimeTypeFromHeader == 'image/jpeg' &&
          await _noExifToolDateTimeWriter(
            file,
            dateTime,
            mimeTypeFromHeader,
            globalConfig,
          )) {
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

      // Skip AVI files - ExifTool cannot write to RIFF AVI format
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
      // When exiftool is not installed
      return _noExifToolDateTimeWriter(
        file,
        dateTime,
        mimeTypeFromHeader,
        globalConfig,
      );
    }
  }

  /// Writes GPS coordinates to EXIF
  ///
  /// [coordinates] GPS coordinates to write
  /// [file] File to write to
  /// [globalConfig] Global configuration service
  /// Returns true if successful
  Future<bool> writeGpsToExif(
    final DMSCoordinates coordinates,
    final File file,
    final GlobalConfigService globalConfig,
  ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    if (globalConfig.exifToolInstalled) {
      final String? mimeTypeFromExtension = lookupMimeType(file.path);
      // Try native way for JPEG files first
      if (mimeTypeFromHeader == 'image/jpeg' &&
          await _noExifGPSWriter(
            file,
            coordinates,
            mimeTypeFromHeader,
            globalConfig,
          )) {
        return true;
      }
      if (mimeTypeFromExtension != mimeTypeFromHeader) {
        logError(
          "GPSWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'.\n"
          'ExifTool would fail, skipping. You may want to run GPTH with --fix-extensions.\n ${file.path}',
        );
        return false;
      }

      // Skip AVI files - ExifTool cannot write to RIFF AVI format
      if (mimeTypeFromExtension == 'video/x-msvideo' ||
          mimeTypeFromHeader == 'video/x-msvideo') {
        logWarning(
          '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
        );
        return false;
      }

      // Check if the file already has EXIF data
      final Map<String, dynamic> coordinatesMap = await _exifTool.readExifData(
        file,
      );
      final bool filehasExifCoordinates =
          coordinatesMap['GPSLatitude'] != null &&
          coordinatesMap['GPSLongitude'] != null;
      if (!filehasExifCoordinates) {
        logInfo(
          '[Step 5/8] Found coordinates ${coordinates.toString()} in json, but missing in EXIF for file: ${file.path}',
        );

        try {
          await _exifTool.writeExifData(file, {
            'GPSLatitude': coordinates.toDD().latitude.toString(),
            'GPSLongitude': coordinates.toDD().longitude.toString(),
            'GPSLatitudeRef': coordinates.latDirection.abbreviation.toString(),
            'GPSLongitudeRef': coordinates.longDirection.abbreviation
                .toString(),
          });
          logInfo('[Step 5/8] New coordinates written to EXIF: ${file.path}');
          return true;
        } catch (e) {
          logError(
            '[Step 5/8] Coordinates ${coordinates.toString()} could not be written to EXIF: ${file.path}',
          );
          return false;
        }
      }
      // Found coords in json but already present in exif. Skip.
      return false;
    } else {
      // If exiftool is not installed
      return _noExifGPSWriter(
        file,
        coordinates,
        mimeTypeFromHeader,
        globalConfig,
      );
    }
  }

  /// Writes DateTime to EXIF using native Dart libraries (JPEG only)
  ///
  /// Only supports JPEG files
  /// using the 'image' package for EXIF manipulation.
  ///
  /// [file] Image file to write to
  /// [dateTime] DateTime to write to EXIF fields
  /// [mimeTypeFromHeader] MIME type detected from file header
  /// [globalConfig] Global configuration service
  /// Returns true if write was successful
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
      // when it's a jpg and the image library can handle it
      ExifData? exifData;
      final Uint8List origbytes = file.readAsBytesSync();
      try {
        exifData = decodeJpgExif(origbytes); // Decode the exif data of the jpg.
      } catch (e) {
        logError(
          '[Step 5/8] Found DateTime in json, but missing in EXIF for file: ${file.path}. Failed to write because of error during decoding: $e',
        );
        return false; // Ignoring errors during image decoding as it may not be a valid image file
      }
      if (exifData != null && !exifData.isEmpty) {
        exifData.imageIfd['DateTime'] = exifFormat.format(dateTime);
        exifData.exifIfd['DateTimeOriginal'] = exifFormat.format(dateTime);
        exifData.exifIfd['DateTimeDigitized'] = exifFormat.format(dateTime);
        final Uint8List? newbytes = injectJpgExif(
          origbytes,
          exifData,
        ); // This overwrites the original exif data of the image with the altered exif data.
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

  /// Writes GPS coordinates to EXIF using native Dart libraries (JPEG only)
  ///
  /// Only supports JPEG files
  /// using the 'image' package for EXIF manipulation.
  ///
  /// [file] Image file to write to
  /// [coordinates] GPS coordinates to write
  /// [mimeTypeFromHeader] MIME type detected from file header
  /// [globalConfig] Global configuration service
  /// Returns true if write was successful
  Future<bool> _noExifGPSWriter(
    final File file,
    final DMSCoordinates coordinates,
    final String? mimeTypeFromHeader,
    final GlobalConfigService globalConfig,
  ) async {
    if (mimeTypeFromHeader == 'image/jpeg') {
      // when it's a jpg and the image library can handle it
      ExifData? exifData;
      final Uint8List origbytes = file.readAsBytesSync();
      try {
        exifData = decodeJpgExif(origbytes); // Decode the exif data of the jpg.
      } catch (e) {
        logError(
          '[Step 5/8] Found coordinates in json, but missing in EXIF for file: ${file.path}. Failed to write because of error during decoding: $e',
        );
        return false; // Ignoring errors during image decoding as it may not be a valid image file
      }
      if (exifData != null && !exifData.isEmpty) {
        try {
          // Use the same approach as the old exif_writer.dart
          exifData.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
          exifData.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
          exifData.gpsIfd.gpsLatitudeRef =
              coordinates.latDirection.abbreviation;
          exifData.gpsIfd.gpsLongitudeRef =
              coordinates.longDirection.abbreviation;

          final Uint8List? newbytes = injectJpgExif(
            origbytes,
            exifData,
          ); // This overwrites the original exif data of the image with the altered exif data.
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
