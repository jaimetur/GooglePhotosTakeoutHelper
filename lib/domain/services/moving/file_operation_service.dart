import 'dart:io';

import 'package:path/path.dart' as p;

/// Service responsible for safe file operations with proper error handling
///
/// This service abstracts file operations used in moving logic and provides
/// consistent error handling, progress tracking, and cross-platform compatibility.
class FileOperationService {
  /// Creates a unique file name by appending (1), (2), etc. until non-existing
  ///
  /// [initialFile] The file to find a unique name for
  /// Returns a File object with a unique path that doesn't exist yet
  File findUniqueFileName(final File initialFile) {
    File file = initialFile;
    int counter = 1;
    while (file.existsSync()) {
      final String baseName = p.withoutExtension(initialFile.path);
      final String extension = p.extension(initialFile.path);
      file = File('$baseName($counter)$extension');
      counter++;
    }
    return file;
  }

  /// Safely moves or copies a file to the target location
  ///
  /// [sourceFile] The source file to move/copy
  /// [targetDirectory] The target directory
  /// [copyMode] Whether to copy (true) or move (false)
  /// Returns the result file
  Future<File> moveOrCopyFile(
    final File sourceFile,
    final Directory targetDirectory, {
    required final bool copyMode,
  }) async {
    // Ensure target directory exists
    await targetDirectory.create(recursive: true);

    final File targetFile = findUniqueFileName(
      File(p.join(targetDirectory.path, p.basename(sourceFile.path))),
    );

    try {
      return copyMode
          ? await sourceFile.copy(targetFile.path)
          : await sourceFile.rename(targetFile.path);
    } on FileSystemException catch (e) {
      // Handle cross-device move errors
      if (e.osError?.errorCode == 18 || e.message.contains('cross-device')) {
        throw FileOperationException(
          'Cannot move files across different drives. '
          'Please select an output location on the same drive as the input.',
          originalException: e,
        );
      }
      rethrow;
    }
  }

  /// Sets the last modified time for a file with proper error handling
  ///
  /// [file] The file to modify
  /// [timestamp] The timestamp to set
  Future<void> setFileTimestamp(
    final File file,
    final DateTime timestamp,
  ) async {
    // Handle Windows date limitations
    DateTime adjustedTime = timestamp;
    if (Platform.isWindows && timestamp.isBefore(DateTime(1970))) {
      print(
        '[Info]: ${file.path} has date $timestamp, which is before 1970 '
        '(not supported on Windows) - will be set to 1970-01-01',
      );
      adjustedTime = DateTime(1970);
    }

    try {
      await file.setLastModified(adjustedTime);
    } on OSError catch (e) {
      // Sometimes Windows throws error but succeeds anyway
      // Only throw if it's not error code 0
      if (e.errorCode != 0) {
        throw FileOperationException(
          "Can't set modification time on $file: $e",
          originalException: e,
        );
      }
      // Error code 0 means success, so we ignore it
    } catch (e) {
      // For other exceptions, we can log and continue
      print(
        "[Warning]: Can't set modification time on $file: $e. "
        'This happens on Windows sometimes. Can be ignored.',
      );
    }
  }

  /// Ensures a directory exists, creating it if necessary
  Future<void> ensureDirectoryExists(final Directory directory) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }
}

/// Exception thrown when file operations fail
class FileOperationException implements Exception {
  const FileOperationException(this.message, {this.originalException});
  final String message;
  final Object? originalException;

  @override
  String toString() => 'FileOperationException: $message';
}
