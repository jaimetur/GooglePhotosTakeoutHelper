import 'dart:io';

import 'package:gpth/gpth-lib.dart';
import 'package:proper_filesize/proper_filesize.dart';

/// Consolidated utility service for common formatting and utility operations
///
/// This service consolidates formatting functionality that was previously
/// scattered across multiple services, providing a single source of truth
/// for common utility operations.
class FormattingService {
  /// Creates a new instance of FormattingService
  const FormattingService();

  /// Test override for exitProgram to prevent actual process termination in tests
  static void Function(int code)? testExitOverride;

  // ============================================================================
  // FORMATTING OPERATIONS
  // ============================================================================

  /// Formats byte count into a human-readable file size string.
  ///
  /// [bytes] Number of bytes to format.
  /// Returns a formatted string like "1.50 MB".
  String formatFileSize(final int bytes) {
    if (bytes <= 0) return '0 B';
    return FileSize.fromBytes(bytes).toString(
      unit: Unit.auto(size: bytes, baseType: BaseType.metric),
      decimals: 2,
    );
    // Note: proper_filesize returns a String; no double/int issues here.
  }

  /// Formats a [Duration] to a concise human-readable string.
  ///
  /// Examples: "45s", "1m 30s", "2h 05m".
  String formatDuration(final Duration duration) {
    final seconds = duration.inSeconds;
    if (seconds < 60) return '${seconds}s';

    final minutes = seconds ~/ 60;
    final remainingSeconds = seconds % 60;
    if (minutes < 60) {
      return remainingSeconds > 0
          ? '${minutes}m ${remainingSeconds}s'
          : '${minutes}m';
    }

    final hours = minutes ~/ 60;
    final remainingMinutes = minutes % 60;
    return remainingMinutes > 0
        ? '${hours}h ${remainingMinutes}m'
        : '${hours}h';
  }

  /// Formats an integer with thousands separators.
  ///
  /// [number] The number to format.
  /// Returns a string like "1,234,567".
  String formatNumber(final int number) => number.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
    (final Match m) => '${m[1]},',
  );

  // ============================================================================
  // FILE OPERATIONS
  // ============================================================================

  /// Finds a unique file name by appending "(1)", "(2)", etc. until it doesn't exist.
  ///
  /// [initialFile] Desired file path.
  /// Returns a [File] with a non-existing path.
  File findUniqueFileName(final File initialFile) {
    if (!initialFile.existsSync()) return initialFile;

    final String directory = initialFile.parent.path;
    final String nameWithoutExtension = initialFile.nameWithoutExtension;
    final String extension = initialFile.extension;

    int counter = 1;
    while (true) {
      final String newName = '$nameWithoutExtension($counter)$extension';
      final candidate = File('$directory${Platform.pathSeparator}$newName');
      if (!candidate.existsSync()) return candidate;
      counter++;
    }
  }

  // ============================================================================
  // VALIDATION OPERATIONS
  // ============================================================================

  /// Validates that a directory exists and is accessible.
  ///
  /// [directory] Directory to validate.
  /// [shouldExist] Whether the directory should exist (default: true).
  FormattingValidationResult validateDirectory(
    final Directory directory, {
    final bool shouldExist = true,
  }) {
    final exists = directory.existsSync();

    if (shouldExist && !exists) {
      return FormattingValidationResult.failure(
        'Directory does not exist: ${directory.path}',
      );
    }

    if (!shouldExist && exists) {
      return FormattingValidationResult.failure(
        'Directory already exists: ${directory.path}',
      );
    }

    if (exists) {
      try {
        // Probe access by listing 1 entry without following links
        directory.listSync(followLinks: false).take(1).toList();
      } catch (_) {
        return FormattingValidationResult.failure(
          'Directory is not accessible: ${directory.path}',
        );
      }
    }

    return const FormattingValidationResult.success();
  }

  /// Validates that a file exists and is readable.
  FormattingValidationResult validateFile(final File file) {
    if (!file.existsSync()) {
      return FormattingValidationResult.failure(
        'File does not exist: ${file.path}',
      );
    }
    try {
      final raf = file.openSync();
      raf.closeSync();
    } catch (_) {
      return FormattingValidationResult.failure(
        'File is not accessible: ${file.path}',
      );
    }
    return const FormattingValidationResult.success();
  }

  // ============================================================================
  // UTILITY OPERATIONS (migrated from UtilityService)
  // ============================================================================

  /// Calculates the total number of output artifacts based on album behavior.
  ///
  /// For the new immutable model:
  /// - For "shortcut", "duplicate-copy", "reverse-shortcut":
  ///   we consider 1 primary output + one artifact per album membership.
  ///   (This mirrors the old `files.files.length` = 1 year-slot + N album-slots.)
  /// - For "json": one record per entity.
  /// - For "nothing": count only entities that come from year-based folders.
  int calculateOutputFileCount(
    final List<MediaEntity> media,
    final String albumOption,
  ) {
    if (albumOption == 'shortcut' ||
        albumOption == 'duplicate-copy' ||
        albumOption == 'reverse-shortcut') {
      int total = 0;
      for (final e in media) {
        total += 1 + e.albumNames.length;
      }
      return total;
    } else if (albumOption == 'json') {
      return media.length;
    } else if (albumOption == 'nothing') {
      int total = 0;
      for (final e in media) {
        if (_entityHasYearBasedFiles(e)) total++;
      }
      return total;
    } else {
      throw ArgumentError.value(albumOption, 'albumOption');
    }
  }

  /// Creates a directory safely (best-effort), returning true if created or already exists.
  Future<bool> safeCreateDirectory(final Directory dir) async {
    final p = dir.path;
    if (p.trim().isEmpty) {
      // Treat empty path as a programmer error; don't attempt to create it.
      return false;
    }
    try {
      await dir.create(recursive: true);
      return true;
    } catch (e) {
      printError('Failed to create directory $p: $e');
      return false;
    }
  }

  /// Exits the program with an optional code, optionally waiting for user input.
  Never exitProgram(
    final int code, {
    final bool showInteractiveMessage = false,
  }) {
    // Allow tests to intercept exit to avoid terminating the test process
    final override = testExitOverride;
    if (override != null) {
      override(code);
      throw _TestExitException(code);
    }

    if (showInteractiveMessage) {
      print(
        '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - '
        'press enter to close]',
      );
      stdin.readLineSync();
    }
    exit(code);
  }

  // ============================================================================
  // ERROR HANDLING
  // ============================================================================

  /// Prints an error message to stderr with consistent formatting.
  void printError(final Object? message) {
    stderr.writeln('[ERROR] $message');
  }

  /// Prints a warning message to stderr with consistent formatting.
  void printWarning(final Object? message) {
    stderr.writeln('[WARNING] $message');
  }

  // ============================================================================
  // INTERNAL HELPERS (new to support the immutable MediaEntity)
  // ============================================================================

  /// Heuristic: returns true if any path (primary or secondary) looks like a
  /// Google Takeout year-based path (e.g., ".../Photos from 2019/...").
  bool _entityHasYearBasedFiles(final MediaEntity e) {
    if (_pathLooksYearBased(e.primaryFile.path)) return true;
    for (final f in e.secondaryFiles) {
      if (_pathLooksYearBased(f.path)) return true;
    }
    return false;
  }

  bool _pathLooksYearBased(final String p) {
    final s = p.replaceAll('\\', '/').toLowerCase();
    // Common localized patterns for Google Takeout year folders
    if (RegExp(r'/photos from \d{4}/').hasMatch(s)) return true; // English
    if (RegExp(r'/fotos de \d{4}/').hasMatch(s)) return true; // Spanish
    if (RegExp(r'/fotos del \d{4}/').hasMatch(s)) return true; // Spanish alt.
    if (RegExp(r'/fotos desde \d{4}/').hasMatch(s)) return true; // Spanish alt.
    return false;
  }
}

/// Extension for string utility operations.
extension StringUtilityExtensions on String {
  /// Returns the same string if the pattern isn't found; otherwise replaces the last occurrence.
  String replaceLastOcurrence(final String from, final String to) {
    final int lastIndex = lastIndexOf(from);
    if (lastIndex == -1) return this;
    return replaceRange(lastIndex, lastIndex + from.length, to);
  }
}

/// Extension methods for [File] to support utility operations.
extension FileUtilityExtensions on File {
  /// Returns the file name without extension.
  String get nameWithoutExtension {
    final String fullName = uri.pathSegments.last;
    final int lastDot = fullName.lastIndexOf('.');
    return lastDot == -1 ? fullName : fullName.substring(0, lastDot);
  }

  /// Returns the file extension including the leading dot, or empty string if none.
  String get extension {
    final String fullName = uri.pathSegments.last;
    final int lastDot = fullName.lastIndexOf('.');
    return lastDot == -1 ? '' : fullName.substring(lastDot);
  }
}

/// Result of a validation operation.
class FormattingValidationResult {
  const FormattingValidationResult._({required this.isSuccess, this.message});

  /// Creates a successful validation result.
  const FormattingValidationResult.success() : this._(isSuccess: true);

  /// Creates a failed validation result with a message.
  const FormattingValidationResult.failure(final String message)
    : this._(isSuccess: false, message: message);

  /// Whether the validation was successful.
  final bool isSuccess;

  /// Error message if validation failed.
  final String? message;

  /// Whether the validation failed.
  bool get isFailure => !isSuccess;
}

/// Exception thrown by [exitProgram] when test override is active.
class _TestExitException implements Exception {
  const _TestExitException(this.code);
  final int code;

  @override
  String toString() =>
      'Program attempted to exit with code $code. '
      'This indicates a fatal error or completion condition was reached. '
      'In production, this would terminate the application. '
      'Check logs above for the specific cause of termination.';
}
