import 'dart:io';
import 'package:proper_filesize/proper_filesize.dart';

/// Consolidated utility service for common formatting and utility operations
///
/// This service consolidates formatting functionality that was previously
/// scattered across multiple services, providing a single source of truth
/// for common utility operations.
class FormattingService {
  /// Creates a new instance of FormattingService
  const FormattingService();

  // ============================================================================
  // FORMATTING OPERATIONS
  // ============================================================================

  /// Formats byte count into human-readable file size string
  ///
  /// Consolidates functionality from:
  /// - UtilityService.formatFileSize()
  /// - FileSystemService.formatFileSize()
  /// - InteractiveConfigurationService._formatBytes()
  ///
  /// [bytes] Number of bytes to format
  /// Returns formatted string like "1.5 MB"
  String formatFileSize(final int bytes) {
    if (bytes < 0) return '0 B';
    if (bytes == 0) return '0 B';

    return FileSize.fromBytes(bytes).toString(
      unit: Unit.auto(size: bytes, baseType: BaseType.metric),
      decimals: 2,
    );
  }

  /// Formats duration in milliseconds to human-readable string
  ///
  /// [milliseconds] Duration in milliseconds
  /// Returns formatted string like "1m 30s" or "45s"
  String formatDuration(final int milliseconds) {
    final seconds = (milliseconds / 1000).round();

    if (seconds < 60) {
      return '${seconds}s';
    }

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

  /// Formats a number with thousand separators
  ///
  /// [number] Number to format
  /// Returns formatted string like "1,234,567"
  String formatNumber(final int number) => number.toString().replaceAllMapped(
    RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
    (final Match match) => '${match[1]},',
  );

  // ============================================================================
  // FILE OPERATIONS
  // ============================================================================

  /// Creates a unique file name by appending (1), (2), etc. until non-existing
  ///
  /// Consolidates functionality from:
  /// - FileSystemService.findUniqueFileName()
  /// - FileOperationService.findUniqueFileName()
  ///
  /// [initialFile] The desired file path
  /// Returns a File object with a unique path that doesn't exist
  File findUniqueFileName(final File initialFile) {
    if (!initialFile.existsSync()) {
      return initialFile;
    }

    final String directory = initialFile.parent.path;
    final String nameWithoutExtension = initialFile.nameWithoutExtension;
    final String extension = initialFile.extension;

    int counter = 1;
    File candidateFile;

    do {
      final String newName = '$nameWithoutExtension($counter)$extension';
      candidateFile = File('$directory${Platform.pathSeparator}$newName');
      counter++;
    } while (candidateFile.existsSync());

    return candidateFile;
  }

  // ============================================================================
  // VALIDATION OPERATIONS
  // ============================================================================

  /// Validates that a directory exists and is accessible
  ///
  /// [directory] Directory to validate
  /// [shouldExist] Whether the directory should exist (default: true)
  /// Returns validation result with success/failure and message
  ValidationResult validateDirectory(
    final Directory directory, {
    final bool shouldExist = true,
  }) {
    final exists = directory.existsSync();

    if (shouldExist && !exists) {
      return ValidationResult.failure(
        'Directory does not exist: ${directory.path}',
      );
    }

    if (!shouldExist && exists) {
      return ValidationResult.failure(
        'Directory already exists: ${directory.path}',
      );
    }

    // Check if directory is accessible (try to list contents)
    if (exists) {
      try {
        directory.listSync(followLinks: false).take(1).toList();
      } catch (e) {
        return ValidationResult.failure(
          'Directory is not accessible: ${directory.path}',
        );
      }
    }

    return const ValidationResult.success();
  }

  /// Validates that a file exists and is readable
  ///
  /// [file] File to validate
  /// Returns validation result with success/failure and message
  ValidationResult validateFile(final File file) {
    if (!file.existsSync()) {
      return ValidationResult.failure('File does not exist: ${file.path}');
    }

    try {
      // Try to read the first byte to check accessibility
      final randomAccess = file.openSync();
      randomAccess.closeSync();
    } catch (e) {
      return ValidationResult.failure('File is not accessible: ${file.path}');
    }

    return const ValidationResult.success();
  }

  // ============================================================================
  // ERROR HANDLING
  // ============================================================================

  /// Prints error message to stderr with consistent formatting
  ///
  /// [message] Error message to print
  void printError(final Object? message) {
    stderr.writeln('[ERROR] $message');
  }

  /// Prints warning message to stderr with consistent formatting
  ///
  /// [message] Warning message to print
  void printWarning(final Object? message) {
    stderr.writeln('[WARNING] $message');
  }
}

/// Extension methods for File class to support utility operations
extension FileUtilityExtensions on File {
  /// Gets the file name without extension
  String get nameWithoutExtension {
    final String fullName = uri.pathSegments.last;
    final int lastDot = fullName.lastIndexOf('.');
    return lastDot == -1 ? fullName : fullName.substring(0, lastDot);
  }

  /// Gets the file extension including the dot
  String get extension {
    final String fullName = uri.pathSegments.last;
    final int lastDot = fullName.lastIndexOf('.');
    return lastDot == -1 ? '' : fullName.substring(lastDot);
  }
}

/// Result of a validation operation
class ValidationResult {
  const ValidationResult._({required this.isSuccess, this.message});

  /// Creates a successful validation result
  const ValidationResult.success() : this._(isSuccess: true);

  /// Creates a failed validation result with message
  const ValidationResult.failure(final String message)
    : this._(isSuccess: false, message: message);

  /// Whether the validation was successful
  final bool isSuccess;

  /// Error message if validation failed
  final String? message;

  /// Whether the validation failed
  bool get isFailure => !isSuccess;
}
