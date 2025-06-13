import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Service for calculating media file hashes and sizes
///
/// Extracted from the Media class to provide better separation of concerns
/// and improved testability. Uses simple file-based hash calculation.
class MediaHashService {
  /// Creates a new instance of MediaHashService
  const MediaHashService();

  /// Calculates the SHA256 hash of a file
  ///
  /// [file] File to calculate hash for
  /// Returns the SHA256 hash as a string
  /// Throws [FileSystemException] if file doesn't exist or can't be read
  Future<String> calculateFileHash(final File file) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }

    try {
      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes);
      return digest.toString();
    } catch (e) {
      throw FileSystemException('Failed to calculate hash: $e', file.path);
    }
  }

  /// Calculates the size of a file in bytes
  ///
  /// [file] File to get size of
  /// Returns file size in bytes
  /// Throws [FileSystemException] if file doesn't exist
  Future<int> calculateFileSize(final File file) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }

    try {
      final stat = await file.stat();
      return stat.size;
    } catch (e) {
      throw FileSystemException('Failed to get file size: $e', file.path);
    }
  }

  /// Calculates both hash and size for a file in a single operation
  ///
  /// More efficient than calling both methods separately.
  ///
  /// [file] File to analyze
  /// Returns a record with (hash, size)
  /// Throws [FileSystemException] if file doesn't exist or can't be read
  Future<({String hash, int size})> calculateHashAndSize(
    final File file,
  ) async {
    if (!await file.exists()) {
      throw FileSystemException('File does not exist', file.path);
    }

    try {
      final stat = await file.stat();
      final size = stat.size;

      final bytes = await file.readAsBytes();
      final digest = sha256.convert(bytes);
      final hash = digest.toString();

      return (hash: hash, size: size);
    } catch (e) {
      throw FileSystemException(
        'Failed to calculate hash and size: $e',
        file.path,
      );
    }
  }

  /// Calculates hashes for multiple files in parallel
  ///
  /// [files] List of files to process
  /// [maxConcurrency] Maximum number of concurrent operations
  /// Returns a map of file path to hash
  Future<Map<String, String>> calculateMultipleHashes(
    final List<File> files, {
    final int? maxConcurrency,
  }) async {
    final concurrency = maxConcurrency ?? Platform.numberOfProcessors;
    final results = <String, String>{};

    // Process files in batches to control concurrency
    for (int i = 0; i < files.length; i += concurrency) {
      final batch = files.skip(i).take(concurrency);
      final futures = batch.map((final file) async {
        try {
          final hash = await calculateFileHash(file);
          return MapEntry(file.path, hash);
        } catch (e) {
          print('Warning: Failed to calculate hash for ${file.path}: $e');
          return null;
        }
      });

      final batchResults = await Future.wait(futures);
      for (final result in batchResults) {
        if (result != null) {
          results[result.key] = result.value;
        }
      }
    }

    return results;
  }

  /// Compares two files by hash to determine if they are identical
  ///
  /// [file1] First file to compare
  /// [file2] Second file to compare
  /// Returns true if files have identical content
  Future<bool> areFilesIdentical(final File file1, final File file2) async {
    // Quick size check first
    final size1 = await calculateFileSize(file1);
    final size2 = await calculateFileSize(file2);

    if (size1 != size2) {
      return false;
    }

    // If sizes match, compare hashes
    final hash1 = await calculateFileHash(file1);
    final hash2 = await calculateFileHash(file2);

    return hash1 == hash2;
  }
}
