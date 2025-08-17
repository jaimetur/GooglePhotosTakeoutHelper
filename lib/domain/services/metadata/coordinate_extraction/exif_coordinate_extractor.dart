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
  /// Creates a new instance of ExifCoordinateExtractor
  ExifCoordinateExtractor(this.exiftool);

  /// The ExifTool service instance (can be null if ExifTool is not available)
  final ExifToolService? exiftool;

  /// Extracts GPS coordinates from file using optimized method
  ///
  /// Uses native exif_reader library for supported formats, falls back to ExifTool
  /// for unsupported formats or when native extraction fails.
  ///
  /// [file] File to extract GPS coordinates from
  /// [globalConfig] Global configuration service
  /// Returns Map with GPS data or null if extraction fails
  Future<Map<String, dynamic>?> extractGPSCoordinates(
    final File file, {
    required final GlobalConfigService globalConfig,
  }) async {
    //If file is >maxFileSize - return null.
    if (await file.length() > defaultMaxFileSize &&
        globalConfig.enforceMaxFileSize) {
      logError(
        'The file is larger than the maximum supported file size of ${defaultMaxFileSize.toString()} bytes. File: ${file.path}',
      );
      return null;
    }

    //We only read the first 128 bytes as that's sufficient for MIME type detection
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;

    //Getting mimeType.
    final String? mimeType = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    // Use the centralized supported MIME types from constants
    Map<String, dynamic>? result;

    // For video files, we should use exiftool directly
    if (mimeType?.startsWith('video/') == true) {
      if (globalConfig.exifToolInstalled) {
        result = await _exifToolGPSExtractor(file);
        if (result != null) {
          return result;
        }
      }
      return null;
    }

    if (supportedNativeExifMimeTypes.contains(mimeType)) {
      result = await _nativeExif_readerGPSExtractor(file);
      if (result != null) {
        return result;
      } else {
        logWarning(
          'Native exif_reader failed to extract GPS coordinates from ${file.path} with MIME type $mimeType. '
          'This format should be supported by exif_reader library. If you see this warning frequently, '
          'please create an issue on GitHub. Falling back to ExifTool if available.',
        );
        // Continue to ExifTool fallback
      }
    }

    // Fall back to ExifTool for unsupported formats or if native extraction failed
    if (globalConfig.exifToolInstalled) {
      result = await _exifToolGPSExtractor(file);
      if (result != null) {
        return result;
      }
    }

    return result;
  }

  /// Extracts GPS coordinates using native exif_reader library
  ///
  /// Faster than ExifTool but supports fewer file formats. Reads standard
  /// GPS EXIF tags for coordinate extraction.
  ///
  /// [file] File to extract GPS coordinates from
  /// Returns Map with GPS data or null if extraction fails
  Future<Map<String, dynamic>?> _nativeExif_readerGPSExtractor(
    final File file,
  ) async {
    try {
      // Read only the first 64KB which should contain EXIF APP1/APP2 segments.
      const int exifScanWindow = 64 * 1024; // 64KB
      final int fileLength = await file.length();
      final int end = fileLength < exifScanWindow ? fileLength : exifScanWindow;
      final bytesBuilder = BytesBuilder(copy: false);
      // ignore: prefer_foreach
      await for (final chunk in file.openRead(0, end)) {
        bytesBuilder.add(chunk);
      }
      final tags = await readExifFromBytes(bytesBuilder.takeBytes());

      // Look for GPS coordinates in EXIF data
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
    } catch (e) {
      // If native extraction fails, return null to allow fallback to ExifTool
      return null;
    }
  }

  /// Extracts GPS coordinates using ExifTool
  ///
  /// Uses ExifTool external process for comprehensive format support.
  ///
  /// [file] File to extract GPS coordinates from
  /// Returns Map with GPS data or null if extraction fails
  Future<Map<String, dynamic>?> _exifToolGPSExtractor(final File file) async {
    // Return null if ExifTool is not available
    if (exiftool == null) {
      return null;
    }

    try {
      final tags = await exiftool!.readExifData(file);

      // Check if GPS coordinates exist
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
