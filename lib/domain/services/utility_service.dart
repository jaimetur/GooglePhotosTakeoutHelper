import 'dart:io';
import 'package:proper_filesize/proper_filesize.dart';
import '../../media.dart';

/// Service for miscellaneous utility functions
///
/// Contains helper functions that don't fit into other specific services
/// but are used throughout the application.
class UtilityService {
  /// Creates a new instance of UtilityService
  const UtilityService();

  /// Prints error message to stderr with newline
  void printError(final Object? object) => stderr.write('$object\n');

  /// Formats byte count into human-readable file size string
  ///
  /// [bytes] Number of bytes to format
  /// Returns formatted string like "1.5 MB"
  String formatFileSize(final int bytes) => FileSize.fromBytes(bytes).toString(
    unit: Unit.auto(size: bytes, baseType: BaseType.metric),
    decimals: 2,
  );

  /// Calculates total number of output files based on album behavior
  ///
  /// [media] List of media objects
  /// [albumOption] Album handling option ('shortcut', 'duplicate-copy', etc.)
  /// Returns expected number of output files
  int calculateOutputFileCount(
    final List<Media> media,
    final String albumOption,
  ) {
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

  /// Validates directory exists and is accessible
  Future<bool> validateDirectory(
    final Directory dir, {
    final bool shouldExist = true,
  }) async {
    final exists = await dir.exists();
    if (shouldExist && !exists) {
      printError('Directory does not exist: ${dir.path}');
      return false;
    }
    if (!shouldExist && exists) {
      printError('Directory already exists: ${dir.path}');
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
      printError('Failed to create directory ${dir.path}: $e');
      return false;
    }
  }

  /// Exits the program with optional code, showing interactive message if needed
  ///
  /// [code] Exit code (default: 1)
  /// [showInteractiveMessage] Whether to show press-enter prompt
  Never exitProgram(
    final int code, {
    final bool showInteractiveMessage = false,
  }) {
    if (showInteractiveMessage) {
      print(
        '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - '
        'press enter to close]',
      );
      stdin.readLineSync();
    }
    exit(code);
  }
}

/// Extension for string utility operations
extension StringUtilityExtensions on String {
  /// Returns same string if pattern not found, otherwise replaces last occurrence
  String replaceLast(final String from, final String to) {
    final int lastIndex = lastIndexOf(from);
    if (lastIndex == -1) return this;
    return replaceRange(lastIndex, lastIndex + from.length, to);
  }
}
