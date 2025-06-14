import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:path/path.dart' as p;
import '../service_container.dart';

/// High-performance file operation service with optimized I/O and concurrency control
///
/// This service provides efficient file operations with streaming for large files,
/// proper concurrency control, and cross-platform optimizations.
class FileOperationService {
  static const int _defaultBufferSize = 64 * 1024; // 64KB buffer
  static const int _largeFileThreshold = 100 * 1024 * 1024; // 100MB
  static const int _maxConcurrentOperations = 4;

  final _operationSemaphore = _Semaphore(_maxConcurrentOperations);

  /// Creates a unique file name by appending (1), (2), etc. until non-existing
  ///
  /// [initialFile] The file to find a unique name for
  /// Returns a File object with a unique path that doesn't exist yet
  ///
  /// @deprecated Use ConsolidatedUtilityService.findUniqueFileName() instead
  File findUniqueFileName(final File initialFile) =>
      ServiceContainer.instance.utilityService.findUniqueFileName(initialFile);

  /// Safely moves or copies a file to the target location with basic implementation
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

  /// High-performance file copy/move using optimized streaming and concurrency control
  ///
  /// Uses platform-specific optimizations and streaming for large files
  Future<File> moveOrCopyFileOptimized(
    final File sourceFile,
    final Directory targetDirectory, {
    required final bool copyMode,
  }) async {
    await _operationSemaphore.acquire();
    try {
      // Ensure target directory exists
      await targetDirectory.create(recursive: true);

      final File targetFile = findUniqueFileName(
        File(p.join(targetDirectory.path, p.basename(sourceFile.path))),
      );

      if (copyMode) {
        return await _copyFileOptimized(sourceFile, targetFile);
      } else {
        return await _moveFileOptimized(sourceFile, targetFile);
      }
    } finally {
      _operationSemaphore.release();
    }
  }

  /// Internal optimized file copy implementation
  Future<File> _copyFileOptimized(final File source, final File destination) async {
    final fileSize = await source.length();

    // For very large files, use isolate-based copying
    if (fileSize > _largeFileThreshold) {
      return _copyLargeFileInIsolate(source, destination);
    }

    // For smaller files, use streaming copy
    return _copyFileStreaming(source, destination);
  }

  /// Internal optimized file move implementation
  Future<File> _moveFileOptimized(final File source, final File destination) async {
    // Check if it's a same-drive operation for optimization
    if (_isSameDrive(source.path, destination.path)) {
      try {
        return await source.rename(destination.path);
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 18 || e.message.contains('cross-device')) {
          // Fall through to copy+delete
        } else {
          rethrow;
        }
      }
    }

    // Cross-drive move requires copy + delete
    final copied = await _copyFileOptimized(source, destination);
    await source.delete();
    return copied;
  }

  /// Streaming file copy for better memory efficiency
  Future<File> _copyFileStreaming(final File source, final File destination) async {
    final sourceStream = source.openRead();
    final destinationSink = destination.openWrite();

    try {
      await sourceStream.pipe(destinationSink);
      return destination;
    } finally {
      await destinationSink.close();
    }
  }

  /// Copy large files using isolates to avoid blocking the main thread
  Future<File> _copyLargeFileInIsolate(final File source, final File destination) async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateCopyFile,
      _IsolateCopyData(
        sourcePath: source.path,
        destinationPath: destination.path,
        sendPort: receivePort.sendPort,
        bufferSize: _defaultBufferSize,
      ),
    );

    final result = await receivePort.first;
    isolate.kill();

    if (result is String) {
      throw FileOperationException('Isolate copy failed: $result');
    }

    return destination;
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

  /// Batch create multiple directories with concurrency control
  Future<void> ensureDirectoriesExist(final List<Directory> directories) async {
    final semaphore = _Semaphore(_maxConcurrentOperations);
    final futures = directories.map((final dir) async {
      await semaphore.acquire();
      try {
        await ensureDirectoryExists(dir);
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
  }

  /// Batch file operations with progress reporting
  Future<List<FileOperationResult>> batchMoveOrCopy(
    final List<({File source, Directory target, bool copyMode})> operations, {
    final void Function(int completed, int total)? onProgress,
  }) async {
    final results = <FileOperationResult>[];
    final semaphore = _Semaphore(_maxConcurrentOperations);
    int completed = 0;

    final futures = operations.map((final op) async {
      await semaphore.acquire();
      try {
        final result = await moveOrCopyFileOptimized(
          op.source,
          op.target,
          copyMode: op.copyMode,
        );
        completed++;
        onProgress?.call(completed, operations.length);
        return FileOperationResult(
          success: true,
          sourceFile: op.source,
          resultFile: result,
        );
      } catch (e) {
        completed++;
        onProgress?.call(completed, operations.length);
        return FileOperationResult(
          success: false,
          sourceFile: op.source,
          error: e.toString(),
        );
      } finally {
        semaphore.release();
      }
    });

    results.addAll(await Future.wait(futures));
    return results;
  }
}

/// Thread-safe semaphore for controlling concurrency
class _Semaphore {
  _Semaphore(this.maxCount) : _currentCount = maxCount;

  final int maxCount;
  int _currentCount;
  final List<Completer<void>> _waitQueue = [];

  Future<void> acquire() async {
    if (_currentCount > 0) {
      _currentCount--;
      return;
    }

    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeAt(0);
      completer.complete();
    } else {
      _currentCount++;
    }
  }
}

/// Data structure for isolate-based file copying
class _IsolateCopyData {
  const _IsolateCopyData({
    required this.sourcePath,
    required this.destinationPath,
    required this.sendPort,
    required this.bufferSize,
  });

  final String sourcePath;
  final String destinationPath;
  final SendPort sendPort;
  final int bufferSize;
}

/// Isolate entry point for large file copying
Future<void> _isolateCopyFile(final _IsolateCopyData data) async {
  try {
    final source = File(data.sourcePath);
    final destination = File(data.destinationPath);

    final sourceStream = source.openRead();
    final destinationSink = destination.openWrite();

    await sourceStream.pipe(destinationSink);
    await destinationSink.close();

    data.sendPort.send(true);
  } catch (e) {
    data.sendPort.send(e.toString());
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
