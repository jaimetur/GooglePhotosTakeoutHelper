// ignore_for_file: file_names

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'utils.dart';

ExiftoolInterface? exiftool;

Future<bool> initExiftool() async {
  exiftool = await ExiftoolInterface.find();
  if (exiftool != null) {
    exifToolInstalled = true;
    return true;
  } else {
    return false;
  }
}

/// Cross-platform interface for exiftool (read/write EXIF data)
class ExiftoolInterface {
  ExiftoolInterface._(this.exiftoolPath);

  final String exiftoolPath;

  /// Attempts to find exiftool in PATH and returns an instance, or null if not found
  static Future<ExiftoolInterface?> find() async {
    final String exe = Platform.isWindows ? 'exiftool.exe' : 'exiftool';
    final String? path = await _which(exe);
    if (path != null) {
      return ExiftoolInterface._(path);
    }
    // Not found in PATH, check same directory as running binary
    String? binDir;
    try {
      binDir = File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      binDir = null;
    }
    if (binDir != null) {
      final exiftoolFile = File(p.join(binDir, exe));
      if (await exiftoolFile.exists()) {
        return ExiftoolInterface._(exiftoolFile.path);
      }
      final exiftoolSubdirFile = File(
        p.join(binDir, 'gpth_tool', 'exif_tool', exe),
      );
      if (await exiftoolSubdirFile.exists()) {
        return ExiftoolInterface._(exiftoolSubdirFile.path);
      }
    }
    return null;
  }

  /// Reads all EXIF data from [file] and returns as a Map
  Future<Map<String, dynamic>> readExif(final File file) async {
    final result = await Process.run(exiftoolPath, ['-j', '-n', file.path]);
    if (result.exitCode != 0) {
      log(
        'exiftool returned a non 0 code for reading ${file.path} with error: ${result.stderr}',
        level: 'error',
      );
    }
    try {
      final List<dynamic> jsonList = jsonDecode(result.stdout);
      if (jsonList.isEmpty) return {};
      final map = Map<String, dynamic>.from(jsonList.first);
      map.remove('SourceFile');
      return map;
    } on FormatException catch (_) {
      // this is when json is bad
      return {};
    } on FileSystemException catch (_) {
      // this happens for issue #143
      // "Failed to decode data using encoding 'utf-8'"
      // maybe this will self-fix when dart itself support more encodings
      return {};
    } on NoSuchMethodError catch (_) {
      // this is when tags like photoTakenTime aren't there
      return {};
    }
  }

  /// Reads only the specified EXIF tags from [file] and returns as a Map
  Future<Map<String, dynamic>> readExifBatch(
    final File file,
    final List<String> tags,
  ) async {
    final String filepath = file.path;

    if (tags.isEmpty) {
      return <String, dynamic>{};
    }
    final args = <String>['-j', '-n'];
    args.addAll(tags.map((final tag) => '-$tag'));
    args.add(filepath);
    final result = await Process.run(exiftoolPath, args);
    if (result.exitCode != 0) {
      log(
        'exiftool returned a non 0 code for reading ${file.path} with error: ${result.stderr}',
        level: 'error',
      );
    }
    try {
      final List<dynamic> jsonList = jsonDecode(result.stdout);
      if (jsonList.isEmpty) return {};
      final map = Map<String, dynamic>.from(jsonList.first);
      map.remove('SourceFile');
      return map;
    } on FormatException catch (_) {
      // this is when json is bad
      return {};
    } on FileSystemException catch (_) {
      // this happens for issue #143
      // "Failed to decode data using encoding 'utf-8'"
      // maybe this will self-fix when dart itself support more encodings
      return {};
    } on NoSuchMethodError catch (_) {
      // this is when tags like photoTakenTime aren't there
      return {};
    }
  }

  /// Writes multiple EXIF tags to [file]. [tags] is a map of tag name to value.
  Future<bool> writeExifBatch(
    final File file,
    final Map<String, String> tags,
  ) async {
    final String filepath = file.path;

    final args = <String>['-overwrite_original'];
    tags.forEach((final tag, final value) => args.add('-$tag=$value'));
    args.add(filepath);
    final result = await Process.run(exiftoolPath, args);
    if (result.exitCode != 0) {
      log(
        '[Step 5/8] Writing exif to file ${file.path} failed. ${result.stderr}',
        level: 'error',
        forcePrint: true,
      );
    }
    if (result.exitCode != 0) {
      return false;
    } else {
      return true;
    }
  }
}

/// Helper to find an executable in PATH (like 'which' or 'where')
Future<String?> _which(final String bin) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    bin,
  ]);
  if (result.exitCode != 0) return null;
  final output = result.stdout.toString();
  final lines = output
      .split(RegExp(r'[\r\n]+'))
      .where((final l) => l.trim().isNotEmpty)
      .toList();
  return lines.isEmpty ? null : lines.first.trim();
}
