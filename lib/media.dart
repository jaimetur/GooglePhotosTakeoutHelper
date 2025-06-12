import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'utils.dart';

/// Simple digest collector for streaming hash calculation
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(final Digest data) {
    value = data;
  }

  @override
  void close() {}
}

//Order is important!
///This is the extraction method through which a Media got its dateTime.
enum DateTimeExtractionMethod { json, exif, guess, jsonTryHard, none }

/// Abstract of a *media* - a photo or video
/// Main thing is the [file] - this should not change
///
/// [size] and [hash] getter are here because we can easily cache
///
/// [dateTakenAccuracy] is a number used to compare with other [Media]. When
/// you find a duplicate, use one that has lower [dateTakenAccuracy] number.
/// this and [dateTaken] should either both be null or both filled
class Media {
  Media(
    this.files, {
    this.dateTaken,
    this.dateTakenAccuracy,
    this.dateTimeExtractionMethod,
  });

  /// First file with media, used in early stage when albums are not merged
  ///
  /// BE AWARE OF HOW YOU USE IT
  File get firstFile => files.values.first;

  /// Map between albums and files of same given media
  ///
  /// This is heavily mutated - at first, media from year folders have this
  /// with single null key, and those from albums have one name.
  /// Then, they are merged into one by algos etc.
  ///
  /// At the end of the script, this will have *all* locations of given media,
  /// so that we can safely:
  /// ```dart
  /// // photo.runtimeType == Media;
  /// photo.files[null].move('output/one-big/');  // null is for year folders
  /// photo.files[<album_name>].move('output/albums/<album_name>/');
  /// ```
  Map<String?, File> files;

  // Cache fields
  int? _size;
  Digest? _hash;

  // Futures for race condition protection
  Future<int>? _sizeOperation;
  Future<Digest>? _hashOperation;

  /// will be used for finding duplicates/albums
  Future<int> getSize() async {
    // Return cached value if available
    if (_size != null) return _size!;

    // If operation is in progress, wait for it
    if (_sizeOperation != null) return _sizeOperation!;

    // Start new operation
    return _sizeOperation = _doGetSize();
  }

  /// Internal method to perform the actual size calculation
  Future<int> _doGetSize() async {
    try {
      final size = await firstFile.length();
      _size = size;
      return size;
    } finally {
      _sizeOperation = null; // Clear the operation when done
    }
  }

  /// Synchronous size getter for backwards compatibility
  /// WARNING: Use getSize() for new code to avoid blocking
  int get size {
    if (_size != null) return _size!;
    // For backwards compatibility, fall back to sync operation
    return _size ??= firstFile.lengthSync();
  }

  /// DateTaken from any source
  DateTime? dateTaken;

  /// higher the worse
  int? dateTakenAccuracy;

  /// The method/extractor that produced the DateTime ('json', 'exif', 'guess', 'jsonTryHard', 'none')
  DateTimeExtractionMethod? dateTimeExtractionMethod;

  /// Async hash calculation using streaming to avoid loading entire file into memory
  /// Returns same value for files > [defaultMaxFileSize] to avoid memory issues
  Future<Digest> getHash() async {
    // Return cached value if available
    if (_hash != null) return _hash!;

    // If operation is in progress, wait for it
    if (_hashOperation != null) return _hashOperation!;

    // Start new operation
    return _hashOperation = _doGetHash();
  }

  /// Internal method to perform the actual hash calculation
  Future<Digest> _doGetHash() async {
    try {
      final fileSize = await getSize();
      if (fileSize > defaultMaxFileSize && enforceMaxFileSize) {
        _hash = Digest(<int>[0]);
        return _hash!;
      }

      final hash = await _calculateHashStreaming();
      _hash = hash;
      return hash;
    } finally {
      _hashOperation = null; // Clear the operation when done
    }
  }

  /// Synchronous hash getter for backwards compatibility
  /// WARNING: Use getHash() for new code to avoid blocking
  /// Uses streaming calculation to avoid loading entire file into memory
  Digest get hash {
    if (_hash != null) return _hash!;
    // For backwards compatibility, fall back to sync operation
    final fileSize = firstFile.lengthSync();
    if (fileSize > defaultMaxFileSize && enforceMaxFileSize) {
      return _hash = Digest(<int>[0]);
    }
    return _hash = _calculateHashStreamingSync();
  }

  /// Synchronous streaming hash calculation to avoid loading entire file into memory
  Digest _calculateHashStreamingSync() {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);

    try {
      // Read file in chunks to avoid loading everything into memory
      const chunkSize = 64 * 1024; // 64KB chunks
      final file = firstFile.openSync();

      try {
        while (true) {
          final chunk = file.readSync(chunkSize);
          if (chunk.isEmpty) break;
          input.add(chunk);
        }
      } finally {
        file.closeSync();
      }

      input.close();
      return output.value;
    } catch (e) {
      rethrow;
    }
  }

  /// Calculate hash using streaming to avoid loading entire file into memory
  Future<Digest> _calculateHashStreaming() async {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    try {
      await firstFile.openRead().forEach(input.add);
      input.close();
      return output.value;
    } catch (e) {
      rethrow;
    }
  }

  @override
  String toString() =>
      'Media('
      '$firstFile, '
      'dateTaken: $dateTaken'
      '${files.keys.length > 1 ? ', albums: ${files.keys}' : ''}'
      ')';
}
