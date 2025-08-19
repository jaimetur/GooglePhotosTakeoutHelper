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

/// Service for writing EXIF data to media files.
/// - Keeps a fast native JPEG path (date + gps).
/// - Uses exiftool for non-JPEG or when native fails.
/// - Tracks fine-grained instrumentation (counts and time per branch).
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool)
      : _coordinateExtractor = ExifCoordinateExtractor(_exifTool);

  final ExifToolService _exifTool;
  final ExifCoordinateExtractor _coordinateExtractor;

  // ────────────────────────────────────────────────────────────────────────────
  // Instrumentation (static counters + timers) — reset via dumpWriterStats()
  // ────────────────────────────────────────────────────────────────────────────
  static int exiftoolCalls = 0;   // number of exiftool invocations (calls)
  static int exiftoolFiles = 0;   // number of files passed to exiftool

  // Native writes
  static int nativeDateFiles = 0;
  static int nativeGpsFiles = 0;
  static int nativeCombinedFiles = 0; // if both date+gps written natively in one go (rare)

  // Exiftool writes
  static int toolDateFiles = 0;
  static int toolGpsFiles = 0;
  static int toolCombinedFiles = 0; // tags set that include BOTH date & gps

  // Time (ms) per bucket
  static int nativeDateMs = 0;
  static int nativeGpsMs = 0;
  static int nativeCombinedMs = 0;

  static int toolDateMs = 0;
  static int toolGpsMs = 0;
  static int toolCombinedMs = 0;

  /// Print aggregated stats; reset if requested.
  void dumpWriterStats({bool reset = true}) {
    String secs(int ms) => (ms / 1000).toStringAsFixed(3);

    logInfo('[WRITE-EXIF] calls=$exiftoolCalls, files=$exiftoolFiles');
    logInfo(
      '[WRITE-EXIF] native: dateWrites=$nativeDateFiles, gpsWrites=$nativeGpsFiles, '
      'combined=$nativeCombinedFiles, dateTime=${secs(nativeDateMs)}s, '
      'gpsTime=${secs(nativeGpsMs)}s, combinedTime=${secs(nativeCombinedMs)}s',
    );
    logInfo(
      '[WRITE-EXIF] exiftool: dateWrites=$toolDateFiles, gpsWrites=$toolGpsFiles, '
      'combined=$toolCombinedFiles, dateTime=${secs(toolDateMs)}s, '
      'gpsTime=${secs(toolGpsMs)}s, combinedTime=${secs(toolCombinedMs)}s',
    );

    if (reset) {
      exiftoolCalls = 0;
      exiftoolFiles = 0;

      nativeDateFiles = 0;
      nativeGpsFiles = 0;
      nativeCombinedFiles = 0;

      toolDateFiles = 0;
      toolGpsFiles = 0;
      toolCombinedFiles = 0;

      nativeDateMs = 0;
      nativeGpsMs = 0;
      nativeCombinedMs = 0;

      toolDateMs = 0;
      toolGpsMs = 0;
      toolCombinedMs = 0;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Public helpers (static) so other modules can reason about tag sets
  // ────────────────────────────────────────────────────────────────────────────

  /// True if [tags] contains any date-related EXIF keys we write.
  static bool hasDateKeys(final Map<String, dynamic> tags) =>
      _hasDateKeys(tags);

  /// True if [tags] contains any GPS-related EXIF keys we write.
  static bool hasGpsKeys(final Map<String, dynamic> tags) =>
      _hasGpsKeys(tags);

  // ────────────────────────────────────────────────────────────────────────────
  // Public API
  // ────────────────────────────────────────────────────────────────────────────

  /// Write arbitrary tags with exiftool (single file, single call).
  /// Metrics are split into date/gps/combined buckets based on keys.
  Future<bool> writeTagsWithExifTool(
    File file,
    Map<String, dynamic> tags,
  ) async {
    if (tags.isEmpty) return false;
    try {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifData(file, tags);
      final ms = sw.elapsedMilliseconds;

      final hasDate = _hasDateKeys(tags);
      final hasGps = _hasGpsKeys(tags);

      exiftoolCalls++;
      exiftoolFiles++;

      if (hasDate && hasGps) {
        toolCombinedFiles++;
        toolCombinedMs += ms;
      } else if (hasDate) {
        toolDateFiles++;
        toolDateMs += ms;
      } else if (hasGps) {
        toolGpsFiles++;
        toolGpsMs += ms;
      }

      logInfo('[Step 5/8] Wrote tags ${tags.keys.toList()} via exiftool: ${file.path}');
      return true;
    } catch (e) {
      logError('Failed to write tags ${tags.keys.toList()} to ${file.path}: $e');
      return false;
    }
  }

  /// Compatibility method used by existing callers.
  Future<bool> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    if (exifData.isEmpty) return true; // nothing to write, but OK
    try {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifData(file, exifData);
      final ms = sw.elapsedMilliseconds;

      exiftoolCalls++;
      exiftoolFiles++;

      if (_hasDateKeys(exifData) && _hasGpsKeys(exifData)) {
        toolCombinedFiles++;
        toolCombinedMs += ms;
      } else if (_hasDateKeys(exifData)) {
        toolDateFiles++;
        toolDateMs += ms;
      } else if (_hasGpsKeys(exifData)) {
        toolGpsFiles++;
        toolGpsMs += ms;
      }
      return true;
    } catch (e) {
      logError('Failed to write EXIF data to ${file.path}: $e');
      return false;
    }
  }

  /// Write DateTime to EXIF.
  /// - Native fast path for JPEG.
  /// - Otherwise exiftool.
  Future<bool> writeDateTimeToExif(
    final DateTime dateTime,
    final File file,
    final GlobalConfigService globalConfig,
  ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader =
        lookupMimeType(file.path, headerBytes: headerBytes);
    final String? mimeTypeFromExtension = lookupMimeType(file.path);

    // Native JPEG path first (fast)
    if (mimeTypeFromHeader == 'image/jpeg') {
      final sw = Stopwatch()..start();
      final ok = await _noExifToolDateTimeWriter(
        file,
        dateTime,
        mimeTypeFromHeader,
        globalConfig,
      );
      final ms = sw.elapsedMilliseconds;
      if (ok) {
        nativeDateFiles++;
        nativeDateMs += ms;
        return true;
      }
      // fall through to exiftool if available
    }

    if (globalConfig.exifToolInstalled != true) {
      // exiftool not available and native failed or not JPEG
      return false;
    }

    // Avoid exiftool write if extension doesn't match header (common failure).
    if (mimeTypeFromExtension != mimeTypeFromHeader &&
        mimeTypeFromHeader != 'image/tiff') {
      logError(
        "DateWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'.\n"
        'ExifTool would fail due to extension/content mismatch. Consider running GPTH with --fix-extensions.\n ${file.path}',
      );
      return false;
    }

    // Skip AVI (unsupported write)
    if (mimeTypeFromExtension == 'video/x-msvideo' ||
        mimeTypeFromHeader == 'video/x-msvideo') {
      logWarning(
        '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
      );
      return false;
    }

    // Do the exiftool write
    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
    final String dt = exifFormat.format(dateTime);
    try {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifData(file, {
        'DateTimeOriginal': '"$dt"',
        'DateTimeDigitized': '"$dt"',
        'DateTime': '"$dt"',
      });
      final ms = sw.elapsedMilliseconds;

      exiftoolCalls++;
      exiftoolFiles++;
      toolDateFiles++;
      toolDateMs += ms;

      logInfo('[Step 5/8] New DateTime $dt written to EXIF (exiftool): ${file.path}');
      return true;
    } catch (e) {
      logError('[Step 5/8] DateTime $dt could not be written to EXIF: ${file.path}');
      return false;
    }
  }

  /// Write GPS coordinates to EXIF.
  /// - Native fast path for JPEG.
  /// - Otherwise exiftool.
  Future<bool> writeGpsToExif(
    final DMSCoordinates coordinates,
    final File file,
    final GlobalConfigService globalConfig,
  ) async {
    final List<int> headerBytes = await file.openRead(0, 128).first;
    final String? mimeTypeFromHeader =
        lookupMimeType(file.path, headerBytes: headerBytes);

    // Native JPEG path first (fast)
    if (mimeTypeFromHeader == 'image/jpeg') {
      final sw = Stopwatch()..start();
      final ok = await _noExifGPSWriter(
        file,
        coordinates,
        mimeTypeFromHeader,
        globalConfig,
      );
      final ms = sw.elapsedMilliseconds;
      if (ok) {
        nativeGpsFiles++;
        nativeGpsMs += ms;
        return true;
      }
      // fall through to exiftool if available
    }

    if (globalConfig.exifToolInstalled != true) {
      // exiftool not available and native failed or not JPEG
      return false;
    }

    final String? mimeTypeFromExtension = lookupMimeType(file.path);

    // Avoid exiftool write if extension mismatch
    if (mimeTypeFromExtension != mimeTypeFromHeader) {
      logError(
        "GPSWriter - File has a wrong extension indicating '$mimeTypeFromExtension' but actually it is '$mimeTypeFromHeader'.\n"
        'ExifTool would fail. You may want to run GPTH with --fix-extensions.\n ${file.path}',
      );
      return false;
    }

    // Skip AVI (unsupported write)
    if (mimeTypeFromExtension == 'video/x-msvideo' ||
        mimeTypeFromHeader == 'video/x-msvideo') {
      logWarning(
        '[Step 5/8] Skipping AVI file - ExifTool cannot write to RIFF AVI format: ${file.path}',
      );
      return false;
    }

    // Do the exiftool write
    try {
      final sw = Stopwatch()..start();
      await _exifTool.writeExifData(file, {
        'GPSLatitude': coordinates.toDD().latitude.toString(),
        'GPSLongitude': coordinates.toDD().longitude.toString(),
        'GPSLatitudeRef': coordinates.latDirection.abbreviation.toString(),
        'GPSLongitudeRef': coordinates.longDirection.abbreviation.toString(),
      });
      final ms = sw.elapsedMilliseconds;

      exiftoolCalls++;
      exiftoolFiles++;
      toolGpsFiles++;
      toolGpsMs += ms;

      logInfo('[Step 5/8] New coordinates written to EXIF: ${file.path}');
      return true;
    } catch (e) {
      logError(
        '[Step 5/8] Coordinates ${coordinates.toString()} could not be written to EXIF: ${file.path}',
      );
      return false;
    }
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Native JPEG implementations (no exiftool)
  // ────────────────────────────────────────────────────────────────────────────

  /// Native DateTime writer for JPEG using package:image EXIF manipulation.
  /// Returns true if bytes are written successfully.
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
        exifData = decodeJpgExif(origbytes); // decode current EXIF
      } catch (e) {
        logError(
          '[Step 5/8] Found DateTime in json, but missing in EXIF for file: ${file.path}. '
          'Failed to write because of error during decoding: $e',
        );
        return false;
      }

      if (exifData != null && !exifData.isEmpty) {
        final String dt = exifFormat.format(dateTime);
        exifData.imageIfd['DateTime'] = dt;
        exifData.exifIfd['DateTimeOriginal'] = dt;
        exifData.exifIfd['DateTimeDigitized'] = dt;

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

    if (globalConfig.exifToolInstalled != true) {
      logWarning(
        '[Step 5/8] Found DateTime in json, but missing in EXIF. Writing to $mimeTypeFromHeader is not supported without exiftool.',
      );
    }
    return false;
  }

  /// Native GPS writer for JPEG using package:image EXIF manipulation.
  /// Returns true if bytes are written successfully.
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
          '[Step 5/8] Found coordinates in json, but missing in EXIF for file: ${file.path}. '
          'Failed to write because of error during decoding: $e',
        );
        return false;
      }

      if (exifData != null && !exifData.isEmpty) {
        try {
          // Set GPS as DD into EXIF GPS IFD. The image package handles conversion.
          exifData.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
          exifData.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
          exifData.gpsIfd.gpsLatitudeRef = coordinates.latDirection.abbreviation;
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

    if (globalConfig.exifToolInstalled != true) {
      logWarning(
        '[Step 5/8] Found coordinates in json, but missing in EXIF. Writing to $mimeTypeFromHeader is not supported without exiftool.',
      );
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Internal helpers
  // ────────────────────────────────────────────────────────────────────────────

  static bool _hasDateKeys(final Map<String, dynamic> tags) {
    // Any of the three date fields implies a "date write".
    return tags.containsKey('DateTimeOriginal') ||
        tags.containsKey('DateTimeDigitized') ||
        tags.containsKey('DateTime');
  }

  static bool _hasGpsKeys(final Map<String, dynamic> tags) {
    return tags.containsKey('GPSLatitude') ||
        tags.containsKey('GPSLongitude') ||
        tags.containsKey('GPSLatitudeRef') ||
        tags.containsKey('GPSLongitudeRef');
  }
}
