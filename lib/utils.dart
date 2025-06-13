/// Utilities file using clean architecture principles
library;

import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:proper_filesize/proper_filesize.dart';

// Clean architecture imports
import 'domain/models/media_entity_collection.dart';
import 'domain/services/extension_fixing_service.dart';
import 'domain/services/logging_service.dart';
import 'domain/services/metadata_matcher_service.dart';
import 'domain/services/mime_type_service.dart';
import 'domain/services/processing_metrics_service.dart';
import 'domain/services/service_container.dart';
import 'infrastructure/disk_space_service.dart';
// Legacy imports
import 'interactive.dart' as interactive;

// remember to bump this
const String version = '4.0.8-Xentraxx';

// Processing constants
const int defaultBarWidth = 40;
const int defaultMaxFileSize = 64 * 1024 * 1024; // 64MB

/// Prints error message to stderr with newline
void error(final Object? object) => stderr.write('$object\n');

/// Exits the program with optional code, showing interactive message if needed
///
/// [code] Exit code (default: 1)
Never quit([final int code = 1]) {
  if (interactive.indeed) {
    print(
      '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - '
      'press enter to close]',
    );
    stdin.readLineSync();
  }
  exit(code);
}

//Support raw formats (dng, cr2) and Pixel motion photos (mp, mv)
//CR2: https://github.com/dart-lang/tools/pull/2105
const List<String> _moreExtensions = <String>['.mp', '.mv', '.dng', '.cr2'];

extension X on Iterable<FileSystemEntity> {
  /// Easy extension allowing you to filter for files that are photo or video
  Iterable<File> wherePhotoVideo() => whereType<File>().where((final File e) {
    final String mime = lookupMimeType(e.path) ?? '';
    final String fileExtension = p.extension(e.path).toLowerCase();
    return mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // https://github.com/dart-lang/mime/issues/102
        // 🙃🙃
        mime == 'model/vnd.mts' ||
        _moreExtensions.contains(fileExtension);
  });
}

extension Y on Stream<FileSystemEntity> {
  /// Easy extension allowing you to filter for files that are photo or video
  Stream<File> wherePhotoVideo() => whereType<File>().where((final File e) {
    final String mime = lookupMimeType(e.path) ?? '';
    final String fileExtension = p.extension(e.path).toLowerCase();
    return mime.startsWith('image/') ||
        mime.startsWith('video/') ||
        // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
        // https://github.com/dart-lang/mime/issues/102
        // 🙃🙃
        mime == 'model/vnd.mts' ||
        _moreExtensions.contains(fileExtension);
  });
}

extension Util on Stream {
  Stream<T> whereType<T>() => where((final e) => e is T).cast<T>();
}

/// Returns disk free space in bytes for the given path
///
/// [path] Directory path to check (defaults to current directory)
/// Returns null if unable to determine free space
Future<int?> getDiskFree([String? path]) async {
  path ??= Directory.current.path;
  final service = DiskSpaceService();
  return service.getAvailableSpace(path);
}

/// Formats byte count into human-readable file size string
///
/// [bytes] Number of bytes to format
/// Returns formatted string like "1.5 MB"
String filesize(final int bytes) => FileSize.fromBytes(bytes).toString(
  unit: Unit.auto(size: bytes, baseType: BaseType.metric),
  decimals: 2,
);

/// Calculates total number of output files based on album behavior
///
/// Delegates to ProcessingMetricsService for clean architecture compliance
int outputFileCount(
  final MediaEntityCollection collection,
  final String albumOption,
) {
  const service = ProcessingMetricsService();
  return service.calculateOutputFileCount(collection, albumOption);
}

extension Z on String {
  /// Returns same string if pattern not found
  String replaceLast(final String from, final String to) {
    final int lastIndex = lastIndexOf(from);
    if (lastIndex == -1) return this;
    return replaceRange(lastIndex, lastIndex + from.length, to);
  }
}

/// Custom logging function with color-coded output levels
///
/// Delegates to LoggingService for clean architecture compliance
void log(
  final String message, {
  final String level = 'info',
  final bool forcePrint = false,
}) {
  // Handle test environment where ServiceContainer might not be initialized
  bool isVerbose = false;
  try {
    isVerbose = ServiceContainer.instance.globalConfig.isVerbose;
  } catch (e) {
    // ServiceContainer not initialized, use default value
    isVerbose = false;
  }

  final service = LoggingService(isVerbose: isVerbose);
  service.log(message, level: level, forcePrint: forcePrint);
}

/// Validates directory exists and is accessible
Future<bool> validateDirectory(
  final Directory dir, {
  final bool shouldExist = true,
}) async {
  final exists = await dir.exists();
  if (shouldExist && !exists) {
    error('Directory does not exist: ${dir.path}');
    return false;
  }
  if (!shouldExist && exists) {
    error('Directory already exists: ${dir.path}');
    return false;
  }
  return true;
}

/// Safely creates directory with error handling
Future<bool> safeCreateDirectory(final Directory dir) async {
  try {
    await dir.create(recursive: true);
    return true;
  } catch (e) {
    error('Failed to create directory ${dir.path}: $e');
    return false;
  }
}

/// Formats a [Duration] as a string: "Xs" if < 1 min, otherwise "Xm Ys".
String formatDuration(final Duration duration) {
  if (duration.inSeconds < 60) {
    return '${duration.inSeconds}s';
  } else {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes}m ${seconds}s';
  }
}

/// Fixes incorrectly named files by renaming them to match their actual MIME type
///
/// Delegates to ExtensionFixingService for clean architecture compliance
Future<int> fixIncorrectExtensions(
  final Directory directory,
  final bool? nonJpeg,
) async {
  final service = ExtensionFixingService();
  return service.fixIncorrectExtensions(
    directory,
    skipJpegFiles: nonJpeg == true,
  );
}

/// Returns preferred extension for a given MIME type
///
/// Delegates to MimeTypeService for clean architecture compliance
String? extensionFromMime(final String mimeType) {
  const service = MimeTypeService();
  return service.getPreferredExtension(mimeType);
}

/// Finds JSON metadata file for a given media file
///
/// Delegates to JsonFileMatcher service from domain layer
Future<File?> jsonForFile(
  final File file, {
  required final bool tryhard,
}) async => JsonFileMatcher.findJsonForFile(file, tryhard: tryhard);
