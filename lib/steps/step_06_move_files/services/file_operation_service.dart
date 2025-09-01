import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:gpth/gpth-lib.dart';

/// High-performance file operation service with optimized I/O and concurrency control
///
/// This service provides efficient file operations with streaming for large files,
/// proper concurrency control, and cross-platform optimizations.
class FileOperationService with LoggerMixin {
  FileOperationService();

  /// Safely moves a file to the target location
  ///
  /// [sourceFile] The source file to move
  /// [targetDirectory] The target directory
  /// [dateTaken] Optional date to set as file modification time
  /// Returns the result file
  Future<File> moveFile(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async {
    // Ensure target directory exists
    final Directory normalizedTargetDir = Directory(_normalizePathForWrite(targetDirectory.path));
    await normalizedTargetDir.create(recursive: true);

    final File targetFile = ServiceContainer.instance.utilityService.findUniqueFileName(
      File(p.join(normalizedTargetDir.path, p.basename(sourceFile.path))),
    );

    try {
      final resultFile = await sourceFile.rename(targetFile.path);

      // Set file timestamp if dateTaken is provided
      if (dateTaken != null) {
        await setFileTimestamp(resultFile, dateTaken);
      }

      return resultFile;
    } on FileSystemException catch (e) {
      // Handle cross-device move errors
      if (e.osError?.errorCode == 18 || e.message.contains('cross-device')) {
        throw FileOperationException(
          'Cannot move files across different drives. Please select an output location on the same drive as the input.',
          originalException: e,
        );
      }
      rethrow;
    }
  }

  /// High-performance file move using optimized streaming and concurrency control
  ///
  /// Uses platform-specific optimizations and streaming for large files
  /// [dateTaken] Optional date to set as file modification time
  Future<File> moveFileOptimized(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async =>
      GlobalPools.poolFor(ConcurrencyOperation.fileIO).withResource(() async {
        // Ensure target directory exists
        final Directory normalizedTargetDir = Directory(_normalizePathForWrite(targetDirectory.path));
        await normalizedTargetDir.create(recursive: true);

        final File targetFile = ServiceContainer.instance.utilityService.findUniqueFileName(
          File(p.join(normalizedTargetDir.path, p.basename(sourceFile.path))),
        );

        final resultFile = await _moveFileOptimized(sourceFile, targetFile);

        // Set file timestamp if dateTaken is provided
        if (dateTaken != null) {
          await setFileTimestamp(resultFile, dateTaken);
        }

        return resultFile;
      });

  /// Internal optimized file move implementation
  Future<File> _moveFileOptimized(
    final File source,
    final File destination,
  ) async {
    // Normalize destination path to avoid trailing-space/dot segments
    final File normalizedDest = File(_normalizePathForWrite(destination.path));

    // Check if it's a same-drive operation for optimization
    if (_isSameDrive(source.path, normalizedDest.path)) {
      try {
        return await source.rename(normalizedDest.path);
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 18 || e.message.contains('cross-device')) {
          // Fall through to copy+delete
        } else {
          rethrow;
        }
      }
    }

    // Cross-drive move requires copy + delete
    final copied = await _copyFileStreaming(source, normalizedDest);
    await source.delete();
    return copied;
  }

  /// Streaming file copy for better memory efficiency
  Future<File> _copyFileStreaming(
    final File source,
    final File destination,
  ) async {
    // Normalize destination before writing
    final File normalizedDest = File(_normalizePathForWrite(destination.path));
    final Directory parent = Directory(p.dirname(normalizedDest.path));
    await parent.create(recursive: true);

    final sourceStream = source.openRead();
    final destinationSink = normalizedDest.openWrite();

    try {
      await sourceStream.pipe(destinationSink);
      return normalizedDest;
    } finally {
      await destinationSink.close();
    }
  }

  /// Check if two paths are on the same drive (for optimization)
  bool _isSameDrive(final String path1, final String path2) {
    if (!Platform.isWindows) {
      return true; // Unix systems don't have drive letters
    }

    final drive1 = path1.length >= 2 ? path1.substring(0, 2).toUpperCase() : '';
    final drive2 = path2.length >= 2 ? path2.substring(0, 2).toUpperCase() : '';

    return drive1 == drive2 && drive1.contains(':');
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
      print('[Info]: ${file.path} has date $timestamp, which is before 1970 (not supported on Windows) - will be set to 1970-01-01');
      adjustedTime = DateTime(1970);
    }

    try {
      await file.setLastModified(adjustedTime);
    } on OSError catch (e) {
      // Sometimes Windows throws error but succeeds anyway
      // Only throw if it's not error code 0
      if (e.errorCode != 0) {
        throw FileOperationException("Can't set modification time on $file: $e", originalException: e);
      }
      // Error code 0 means success, so we ignore it
    } catch (e) {
      // For other exceptions, check if it's the Windows "success" quirk
      final errorMessage = e.toString();
      if (errorMessage.contains('The operation completed successfully')) {
        // This is a Windows quirk where it reports success as an error - ignore it
        return;
      }

      // For genuine errors, we can log and continue
      logError("Can't set modification time on $file: $e.");
    }
  }

  /// Ensures a directory exists, creating it if necessary
  Future<void> ensureDirectoryExists(final Directory directory) async {
    final Directory normalized = Directory(_normalizePathForWrite(directory.path));
    if (!await normalized.exists()) {
      await normalized.create(recursive: true);
    }
  }

  /// Batch create multiple directories with concurrency control
  Future<void> ensureDirectoriesExist(final List<Directory> directories) async {
    final pool = GlobalPools.poolFor(ConcurrencyOperation.fileIO);
    final concurrency = ConcurrencyManager().concurrencyFor(ConcurrencyOperation.fileIO);
    logDebug('Starting $concurrency threads (fileIO directory ensure concurrency)');
    await Future.wait(
      directories.map((final dir) => pool.withResource(() => ensureDirectoryExists(dir))),
    );
  }

  /// Batch file move operations with progress reporting
  Future<List<FileOperationResult>> batchMove(
    final List<({File source, Directory target})> operations, {
    final void Function(int completed, int total)? onProgress,
  }) async {
    final results = <FileOperationResult>[];
    final pool = GlobalPools.poolFor(ConcurrencyOperation.fileIO);
    final concurrency = ConcurrencyManager().concurrencyFor(ConcurrencyOperation.fileIO);
    logDebug('Starting $concurrency threads (fileIO move concurrency)');
    int completed = 0;

    final futures = operations.map((final op) async => pool.withResource(() async {
          try {
            final result = await moveFileOptimized(op.source, op.target);
            completed++;
            onProgress?.call(completed, operations.length);
            return FileOperationResult(success: true, sourceFile: op.source, resultFile: result);
          } catch (e) {
            completed++;
            onProgress?.call(completed, operations.length);
            return FileOperationResult(success: false, sourceFile: op.source, error: e.toString());
          }
        }));

    results.addAll(await Future.wait(futures));
    return results;
  }

  /// Copies a file to the target location (for duplicate copy strategy)
  ///
  /// [sourceFile] The source file to copy
  /// [targetDirectory] The target directory
  /// [dateTaken] Optional date to set as file modification time
  /// Returns the copied file
  Future<File> copyFile(
    final File sourceFile,
    final Directory targetDirectory, {
    final DateTime? dateTaken,
  }) async {
    // Ensure target directory exists
    final Directory normalizedTargetDir = Directory(_normalizePathForWrite(targetDirectory.path));
    await normalizedTargetDir.create(recursive: true);

    final File targetFile = ServiceContainer.instance.utilityService.findUniqueFileName(
      File(p.join(normalizedTargetDir.path, p.basename(sourceFile.path))),
    );

    final resultFile = await _copyFileStreaming(sourceFile, targetFile);

    // Set file timestamp if dateTaken is provided
    if (dateTaken != null) {
      await setFileTimestamp(resultFile, dateTaken);
    }

    return resultFile;
  }

  /// NEW: normalize destination paths before touching the filesystem
  ///
  /// - Trims **trailing spaces and dots** from **each path segment** (cross-platform)
  ///   to avoid directories like "Fotos de " that later cause “No such file or directory”.
  /// - Removes ASCII control chars.
  /// - Keeps Unicode (accents, emojis) intact.
  /// - Ensures no empty segments remain (replaces with "_").
  String _normalizePathForWrite(final String rawPath) {
    if (rawPath.isEmpty) return rawPath;

    // Normalize to forward slashes to split, then rebuild with platform separator.
    final String unified = rawPath.replaceAll('\\', '/');
    final parts = unified.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) return rawPath;

    final List<String> norm = <String>[];
    for (int i = 0; i < parts.length; i++) {
      var seg = parts[i];

      // Remove ASCII control characters
      seg = seg.replaceAll(RegExp(r'[\x00-\x1F]'), '_');

      // Trim trailing spaces/dots (Takeout quirk)
      seg = seg.replaceAll(RegExp(r'[. ]+$'), '');

      // Avoid empty component
      if (seg.isEmpty) seg = '_';

      // Preserve Unicode; do not touch valid characters
      norm.add(seg);
    }

    return norm.join(Platform.pathSeparator);
  }
}

/// Result of a file operation
class FileOperationResult {
  const FileOperationResult({
    required this.success,
    required this.sourceFile,
    this.resultFile,
    this.error,
  });

  final bool success;
  final File sourceFile;
  final File? resultFile;
  final String? error;
}

/// Exception thrown when file operations fail
class FileOperationException implements Exception {
  const FileOperationException(this.message, {this.originalException});
  final String message;
  final Object? originalException;

  @override
  String toString() => 'FileOperationException: $message';
}
