/// Utilities file using clean architecture principles
library;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:proper_filesize/proper_filesize.dart';

// Clean architecture imports
import 'domain/services/global_config_service.dart';
import 'domain/services/metadata_matcher_service.dart';

// Legacy imports
import 'extras.dart';
import 'interactive.dart' as interactive;
import 'media.dart';

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
  if (Platform.isLinux) {
    return _dfLinux(path);
  } else if (Platform.isWindows) {
    return _dfWindoza(path);
  } else if (Platform.isMacOS) {
    return _dfMcOS(path);
  } else {
    return null;
  }
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
/// [media] List of media objects
/// [albumOption] Album handling option ('shortcut', 'duplicate-copy', etc.)
/// Returns expected number of output files
int outputFileCount(final List<Media> media, final String albumOption) {
  if (<String>[
    'shortcut',
    'duplicate-copy',
    'reverse-shortcut',
  ].contains(albumOption)) {
    return media.fold(
      0,
      (final int prev, final Media e) => prev + e.files.length,
    );
  } else if (albumOption == 'json') {
    return media.length;
  } else if (albumOption == 'nothing') {
    return media.where((final Media e) => e.files.containsKey(null)).length;
  } else {
    throw ArgumentError.value(albumOption, 'albumOption');
  }
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
/// [message] The message to log
/// [level] Log level: 'info' (green), 'warning' (yellow), 'error' (red)
/// [forcePrint] If true, prints even when verbose mode is disabled
void log(
  final String message, {
  final String level = 'info',
  final bool forcePrint = false,
}) {
  if (GlobalConfigService.instance.isVerbose || forcePrint == true) {
    final String color;
    switch (level.toLowerCase()) {
      case 'error':
        color = '\x1B[31m'; // Red for errors
        break;
      case 'warning':
        color = '\x1B[33m'; // Yellow for warnings
        break;
      case 'info':
      default:
        color = '\x1B[32m'; // Green for info
        break;
    }
    print(
      '\r$color[${level.toUpperCase()}] $message\x1B[0m',
    ); // Reset color after the message
  }
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

// Legacy complex functions - these should be moved to domain services in future iterations

/// Fixes incorrectly named files by renaming them to match their actual MIME type
/// TODO: Move to domain/services/extension_fixing_service.dart
Future<int> fixIncorrectExtensions(
  final Directory directory,
  final bool? nonJpeg,
) async {
  int fixedCount = 0;
  await for (final FileSystemEntity file
      in directory.list(recursive: true).wherePhotoVideo()) {
    final List<int> headerBytes = await File(file.path).openRead(0, 128).first;
    final String? mimeTypeFromHeader = lookupMimeType(
      file.path,
      headerBytes: headerBytes,
    );

    if (nonJpeg == true && mimeTypeFromHeader == 'image/jpeg') {
      continue; // Skip 'actual' JPEGs in non-jpeg mode
    }

    final String? mimeTypeFromExtension = lookupMimeType(file.path);

    // Since for ex. CR2 is based on TIFF and mime lib does not support RAW
    // lets skip everything that has TIFF header
    if (mimeTypeFromHeader != null &&
        mimeTypeFromHeader != 'image/tiff' &&
        mimeTypeFromHeader != mimeTypeFromExtension) {
      // Special case: Handle AVI files that Google Photos incorrectly renamed to .MP4
      if (mimeTypeFromExtension == 'video/mp4' &&
          mimeTypeFromHeader == 'video/x-msvideo') {
        log(
          '[Step 1/8] Detected AVI file incorrectly named as .mp4: ${p.basename(file.path)}',
        );
      }

      final String? newExtension = extensionFromMime(mimeTypeFromHeader);

      if (newExtension == null) {
        log(
          '[Step 1/8] Could not determine correct extension for file ${p.basename(file.path)}. Moving on..',
          level: 'warning',
        );
        continue;
      }

      final String newFilePath = '${file.path}.$newExtension';
      final File newFile = File(newFilePath);
      File? jsonFile = await jsonForFile(File(file.path), tryhard: false);

      if (jsonFile == null) {
        jsonFile = await jsonForFile(File(file.path), tryhard: true);
        if (jsonFile == null) {
          log(
            '[Step 1/8] unable to find matching json for file: ${file.path}',
            level: 'warning',
            forcePrint: true,
          );
        }
      }

      // Verify if the file renamed already exists
      if (await newFile.exists()) {
        log(
          '[Step 1/8] Skipped fixing extension because it already exists: $newFilePath',
          level: 'warning',
          forcePrint: true,
        );
        continue;
      }

      try {
        if (jsonFile != null && jsonFile.existsSync() && !isExtra(file.path)) {
          // Rename both file and JSON
          await file.rename(newFilePath);

          final String jsonNewPath = '$newFilePath.json';
          await jsonFile.rename(jsonNewPath);

          log(
            '[Step 1/8] Fixed extension: ${p.basename(file.path)} -> ${p.basename(newFilePath)}',
          );
          fixedCount++;
        }
      } catch (e) {
        log(
          '[Step 1/8] Failed to rename file ${file.path}: $e',
          level: 'error',
        );
      }
    }
  }
  return fixedCount;
}

/// Returns preferred extension for a given MIME type
String? extensionFromMime(final String mimeType) {
  final Map<String, String> mimeToExt = {
    'image/jpeg': 'jpg',
    'image/png': 'png',
    'image/gif': 'gif',
    'image/webp': 'webp',
    'image/heic': 'heic',
    'image/avif': 'avif',
    'video/mp4': 'mp4',
    'video/avi': 'avi',
    'video/mov': 'mov',
    'video/quicktime': 'mov',
    'video/x-msvideo': 'avi',
    'video/webm': 'webm',
  };
  return mimeToExt[mimeType];
}

/// Finds JSON metadata file for a given media file
Future<File?> jsonForFile(
  final File file, {
  required final bool tryhard,
}) async =>
    // Use the proper JsonFileMatcher service from domain layer
    JsonFileMatcher.findJsonForFile(file, tryhard: tryhard);

/// Gets disk free space on Linux using df command
///
/// [path] Directory path to check
/// Returns free space in bytes or null on failure
Future<int?> _dfLinux(final String path) async {
  final ProcessResult res = await Process.run('df', <String>[
    '-B1',
    '--output=avail',
    path,
  ]);
  return res.exitCode != 0
      ? null
      : int.tryParse(
          res.stdout.toString().split('\n').elementAtOrNull(1) ?? '',
          radix: 10, // to be sure
        );
}

/// Gets disk free space on Windows using PowerShell
///
/// [path] Directory path to check
/// Returns free space in bytes or null on failure
Future<int?> _dfWindoza(final String path) async {
  final String driveLetter = p
      .rootPrefix(p.absolute(path))
      .replaceAll('\\', '')
      .replaceAll(':', '');
  final ProcessResult res = await Process.run('powershell', <String>[
    '-Command',
    'Get-PSDrive -Name ${driveLetter[0]} | Select-Object -ExpandProperty Free',
  ]);
  final int? result = res.exitCode != 0 ? null : int.tryParse(res.stdout);
  return result;
}

/// Gets disk free space on macOS using df command
///
/// [path] Directory path to check
/// Returns free space in bytes or null on failure
Future<int?> _dfMcOS(final String path) async {
  final ProcessResult res = await Process.run('df', <String>['-k', path]);
  if (res.exitCode != 0) return null;
  final String? line2 = res.stdout.toString().split('\n').elementAtOrNull(1);
  if (line2 == null) return null;
  final List<String> elements = line2.split(' ')
    ..removeWhere((final String e) => e.isEmpty);
  final int? macSays = int.tryParse(
    elements.elementAtOrNull(3) ?? '',
    radix: 10, // to be sure
  );
  return macSays != null ? macSays * 1024 : null;
}
