import 'dart:io';
import 'dart:typed_data';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';

import '../../../infrastructure/exiftool_service.dart';
import '../core/logging_service.dart';

/// Service for writing EXIF data to media files (fast native JPEG path + exiftool).
/// This module also includes detailed instrumentation so you can see how much
/// time each branch consumes (native vs exiftool, per tag category).
class ExifWriterService with LoggerMixin {
  ExifWriterService(this._exifTool);

  final ExifToolService? _exifTool;

  // ───────────────────────── Instrumentation (static, per run) ───────────────
  // Counts
  static int nativeDateCount = 0;
  static int nativeGpsCount = 0;
  static int nativeCombinedCount = 0;

  static int exiftoolDateCount = 0;
  static int exiftoolGpsCount = 0;
  static int exiftoolCombinedCount = 0;

  static int exiftoolBatchFiles = 0;     // files written via batched exiftool
  static int exiftoolBatchInvocations = 0;

  // Timings (milliseconds)
  static int nativeDateMs = 0;
  static int nativeGpsMs = 0;
  static int nativeCombinedMs = 0;

  static int exiftoolDateMs = 0;
  static int exiftoolGpsMs = 0;
  static int exiftoolCombinedMs = 0;

  static int exiftoolBatchMs = 0; // total time spent inside batched calls

  /// Prints a detailed summary of Step 5 instrumentation.
  /// Set [reset] to true to clear counters after printing.
  static void dumpWriterStatsDetailed({bool reset = true, LoggerMixin? logger}) {
    final lines = <String>[
      '[WRITE-EXIF] native-date: files=$nativeDateCount time=${nativeDateMs}ms',
      '[WRITE-EXIF] native-gps:  files=$nativeGpsCount time=${nativeGpsMs}ms',
      '[WRITE-EXIF] native-combined(date+gps): files=$nativeCombinedCount time=${nativeCombinedMs}ms',
      '[WRITE-EXIF] exiftool-date: files=$exiftoolDateCount time=${exiftoolDateMs}ms',
      '[WRITE-EXIF] exiftool-gps:  files=$exiftoolGpsCount time=${exiftoolGpsMs}ms',
      '[WRITE-EXIF] exiftool-combined(date+gps): files=$exiftoolCombinedCount time=${exiftoolCombinedMs}ms',
      '[WRITE-EXIF] exiftool-batch: invocations=$exiftoolBatchInvocations files=$exiftoolBatchFiles totalTime=${exiftoolBatchMs}ms',
    ];

    if (logger != null) {
      for (final l in lines) {
        // Force print so it shows even without --verbose
        // ignore: invalid_use_of_protected_member
        logger.logger.info(l, forcePrint: true);
      }
    } else {
      for (final l in lines) {
        // ignore: avoid_print
        print(l);
      }
    }

    if (reset) {
      nativeDateCount = 0;
      nativeGpsCount = 0;
      nativeCombinedCount = 0;

      exiftoolDateCount = 0;
      exiftoolGpsCount = 0;
      exiftoolCombinedCount = 0;

      exiftoolBatchFiles = 0;
      exiftoolBatchInvocations = 0;

      nativeDateMs = 0;
      nativeGpsMs = 0;
      nativeCombinedMs = 0;

      exiftoolDateMs = 0;
      exiftoolGpsMs = 0;
      exiftoolCombinedMs = 0;

      exiftoolBatchMs = 0;
    }
  }

  // ───────────────────────── Static helpers (used by collection) ─────────────

  /// Build EXIF date tags map for exiftool.
  static Map<String, dynamic> buildDateTags(DateTime dt) {
    final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
    final s = '"${exifFormat.format(dt)}"';
    return {
      'DateTimeOriginal': s,
      'DateTimeDigitized': s,
      'DateTime': s,
    };
    // Note: Strings are quoted to preserve colons and spaces.
  }

  /// Build EXIF GPS tags map for exiftool.
  static Map<String, dynamic> buildGpsTags(DMSCoordinates c) {
    return {
      'GPSLatitude': c.toDD().latitude.toString(),
      'GPSLongitude': c.toDD().longitude.toString(),
      'GPSLatitudeRef': c.latDirection.abbreviation.toString(),
      'GPSLongitudeRef': c.longDirection.abbreviation.toString(),
    };
  }

  /// Whether the tag map contains any EXIF date keys.
  static bool _hasDateKeys(Map<String, dynamic> tags) =>
      tags.containsKey('DateTimeOriginal') ||
      tags.containsKey('DateTimeDigitized') ||
      tags.containsKey('DateTime');

  /// Whether the tag map contains any EXIF GPS keys.
  static bool _hasGpsKeys(Map<String, dynamic> tags) =>
      tags.containsKey('GPSLatitude') ||
      tags.containsKey('GPSLongitude') ||
      tags.containsKey('GPSLatitudeRef') ||
      tags.containsKey('GPSLongitudeRef');

  // ───────────────────────── Public API (compat) ─────────────────────────────

  /// Generic "write EXIF" wrapper (one-shot). Mostly kept for compatibility.
  Future<bool> writeExifData(File file, Map<String, dynamic> exifData) async {
    if (_exifTool == null || exifData.isEmpty) return false;
    try {
      final sw = Stopwatch()..start();
      await _exifTool!.writeExifData(file, exifData);
      sw.stop();

      // Attribute time into right buckets based on tags.
      final hasDate = _hasDateKeys(exifData);
      final hasGps = _hasGpsKeys(exifData);
      if (hasDate && hasGps) {
        exiftoolCombinedCount++;
        exiftoolCombinedMs += sw.elapsedMilliseconds;
      } else if (hasDate) {
        exiftoolDateCount++;
        exiftoolDateMs += sw.elapsedMilliseconds;
      } else if (hasGps) {
        exiftoolGpsCount++;
        exiftoolGpsMs += sw.elapsedMilliseconds;
      }
      return true;
    } catch (e) {
      logError('Failed to write EXIF data to ${file.path}: $e');
      return false;
    }
  }

  // ───────────────────────── Native JPEG writers (fast path) ─────────────────

  /// Native JPEG write: DateTime only.
  Future<bool> writeDateTimeNativeJpeg(File file, DateTime dateTime) async {
    final sw = Stopwatch()..start();
    try {
      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
      final Uint8List orig = file.readAsBytesSync();
      ExifData? exifData;
      try {
        exifData = decodeJpgExif(orig);
      } catch (e) {
        logError(
          '[Step 5/8] Failed to decode JPEG EXIF for ${file.path}: $e',
        );
        return false;
      }
      if (exifData == null || exifData.isEmpty) return false;

      final s = exifFormat.format(dateTime);
      exifData.imageIfd['DateTime'] = s;
      exifData.exifIfd['DateTimeOriginal'] = s;
      exifData.exifIfd['DateTimeDigitized'] = s;

      final Uint8List? newBytes = injectJpgExif(orig, exifData);
      if (newBytes == null) return false;

      file.writeAsBytesSync(newBytes);
      return true;
    } finally {
      sw.stop();
      nativeDateCount++;
      nativeDateMs += sw.elapsedMilliseconds;
    }
  }

  /// Native JPEG write: GPS only.
  Future<bool> writeGpsNativeJpeg(File file, DMSCoordinates coordinates) async {
    final sw = Stopwatch()..start();
    try {
      final Uint8List orig = file.readAsBytesSync();
      ExifData? exifData;
      try {
        exifData = decodeJpgExif(orig);
      } catch (e) {
        logError(
          '[Step 5/8] Failed to decode JPEG EXIF for ${file.path}: $e',
        );
        return false;
      }
      if (exifData == null || exifData.isEmpty) return false;

      exifData.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
      exifData.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
      exifData.gpsIfd.gpsLatitudeRef = coordinates.latDirection.abbreviation;
      exifData.gpsIfd.gpsLongitudeRef = coordinates.longDirection.abbreviation;

      final Uint8List? newBytes = injectJpgExif(orig, exifData);
      if (newBytes == null) return false;

      file.writeAsBytesSync(newBytes);
      return true;
    } finally {
      sw.stop();
      nativeGpsCount++;
      nativeGpsMs += sw.elapsedMilliseconds;
    }
  }

  /// Native JPEG write: DateTime + GPS combined.
  Future<bool> writeDateTimeAndGpsNativeJpeg(
    File file,
    DateTime dateTime,
    DMSCoordinates coordinates,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
      final Uint8List orig = file.readAsBytesSync();
      ExifData? exifData;
      try {
        exifData = decodeJpgExif(orig);
      } catch (e) {
        logError(
          '[Step 5/8] Failed to decode JPEG EXIF for ${file.path}: $e',
        );
        return false;
      }
      if (exifData == null || exifData.isEmpty) return false;

      final s = exifFormat.format(dateTime);
      exifData.imageIfd['DateTime'] = s;
      exifData.exifIfd['DateTimeOriginal'] = s;
      exifData.exifIfd['DateTimeDigitized'] = s;

      exifData.gpsIfd.gpsLatitude = coordinates.toDD().latitude;
      exifData.gpsIfd.gpsLongitude = coordinates.toDD().longitude;
      exifData.gpsIfd.gpsLatitudeRef = coordinates.latDirection.abbreviation;
      exifData.gpsIfd.gpsLongitudeRef = coordinates.longDirection.abbreviation;

      final Uint8List? newBytes = injectJpgExif(orig, exifData);
      if (newBytes == null) return false;

      file.writeAsBytesSync(newBytes);
      return true;
    } finally {
      sw.stop();
      nativeCombinedCount++;
      nativeCombinedMs += sw.elapsedMilliseconds;
    }
  }

  // ───────────────────────── Batched exiftool write ─────────────────────────

  /// Writes per-file tag maps in a single exiftool invocation using an argfile (-@).
  /// Each file can have a different set of tags. This reduces process startup costs.
  ///
  /// The timing of the whole batch is attributed proportionally across categories
  /// (date-only, gps-only, combined) to keep category times informative.
  Future<void> writeExiftoolBatches(
    Map<File, Map<String, dynamic>> perFileTags, {
    int chunkSize = 48,
  }) async {
    if (_exifTool == null || perFileTags.isEmpty) return;

    final entries = perFileTags.entries.toList();
    for (int i = 0; i < entries.length; i += chunkSize) {
      final chunk = entries.sublist(i, i + chunkSize > entries.length ? entries.length : i + chunkSize);

      // Build argfile content: for each file, write "-overwrite_original", tags, path, "-execute"
      final argLines = <String>[];
      int catDate = 0;
      int catGps = 0;
      int catCombined = 0;

      for (final e in chunk) {
        final file = e.key;
        final tags = e.value;

        final hasDate = _hasDateKeys(tags);
        final hasGps = _hasGpsKeys(tags);
        if (hasDate && hasGps) {
          catCombined++;
        } else if (hasDate) {
          catDate++;
        } else if (hasGps) {
          catGps++;
        }

        argLines.add('-overwrite_original');
        tags.forEach((k, v) => argLines.add('-$k=$v'));
        argLines.add(file.path);
        argLines.add('-execute');
      }

      // Use a temporary argfile for -@
      final tmp = await File('${Directory.systemTemp.path}/exiftool-args-${DateTime.now().microsecondsSinceEpoch}.txt')
          .create(recursive: true);
      await tmp.writeAsString(argLines.join('\n'));

      final sw = Stopwatch()..start();
      try {
        // exiftool -@ /path/to/argfile
        await _exifTool!.executeCommand(['-@', tmp.path]);

        // Update counters
        exiftoolBatchInvocations++;
        exiftoolBatchFiles += chunk.length;
      } finally {
        sw.stop();
        exiftoolBatchMs += sw.elapsedMilliseconds;
        try {
          await tmp.delete();
        } catch (_) {}
      }

      // Attribute batch time proportionally across categories.
      final totalCat = (catCombined + catDate + catGps);
      if (totalCat > 0) {
        final perUnit = sw.elapsedMilliseconds / totalCat;
        exiftoolCombinedCount += catCombined;
        exiftoolDateCount += catDate;
        exiftoolGpsCount += catGps;

        exiftoolCombinedMs += (perUnit * catCombined).round();
        exiftoolDateMs += (perUnit * catDate).round();
        exiftoolGpsMs += (perUnit * catGps).round();
      }
    }
  }
}
