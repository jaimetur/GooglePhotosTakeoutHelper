import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/entities/media_entity.dart';
import '../domain/models/media_entity.dart' as domain;
import '../domain/services/global_config_service.dart';
import '../domain/services/media_hash_service.dart';
import '../shared/constants.dart' as constants;

/// Adapter that bridges the gap between old Media class and new MediaEntity
///
/// This provides backward compatibility while the codebase transitions to
/// the immutable domain model. It delegates to services for caching and
/// calculations while maintaining the mutable interface.
class LegacyMediaAdapter {
  /// Creates an adapter wrapping an immutable media entity
  LegacyMediaAdapter(this._entity) : _hashService = const MediaHashService();

  /// Creates from legacy constructor parameters
  LegacyMediaAdapter.fromLegacy(
    final Map<String?, File> files, {
    final DateTime? dateTaken,
    final int? dateTakenAccuracy,
    final domain.DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) : _entity = MediaEntity.fromMap(
         files: files,
         dateTaken: dateTaken,
         dateTakenAccuracy: dateTakenAccuracy,
         dateTimeExtractionMethod: dateTimeExtractionMethod,
       ),
       _hashService = const MediaHashService();

  MediaEntity _entity;
  final MediaHashService _hashService;

  // Cache fields for performance
  int? _size;
  Digest? _hash;
  Future<int>? _sizeOperation;
  Future<Digest>? _hashOperation;

  /// Gets the immutable entity (for services that need it)
  MediaEntity get entity => _entity;

  /// Updates the underlying entity (creates new immutable instance)
  set entity(final MediaEntity newEntity) {
    _entity = newEntity;
    // Clear caches when entity changes
    _size = null;
    _hash = null;
  }

  /// Legacy property: first file
  File get firstFile => _entity.primaryFile;

  /// Legacy property: mutable files map
  /// Note: Returns unmodifiable view. Use withFiles() for modifications.
  Map<String?, File> get files => Map.unmodifiable(_entity.files.files);

  /// Legacy property: date taken
  DateTime? get dateTaken => _entity.dateTaken;

  /// Legacy property: date accuracy
  int? get dateTakenAccuracy =>
      _entity.dateAccuracy == null ? null : _entity.dateTakenAccuracy;

  /// Legacy property: extraction method
  domain.DateTimeExtractionMethod? get dateTimeExtractionMethod =>
      _entity.dateTimeExtractionMethod;

  /// Async size calculation with caching
  Future<int> getSize() async {
    if (_size != null) return _size!;
    if (_sizeOperation != null) return _sizeOperation!;

    return _sizeOperation = _doGetSize();
  }

  Future<int> _doGetSize() async {
    try {
      final size = await firstFile.length();
      _size = size;
      return size;
    } finally {
      _sizeOperation = null;
    }
  }

  /// Synchronous size getter (legacy compatibility)
  int get size {
    if (_size != null) return _size!;
    return _size = firstFile.lengthSync();
  }

  /// Async hash calculation with caching
  Future<Digest> getHash() async {
    if (_hash != null) return _hash!;
    if (_hashOperation != null) return _hashOperation!;

    return _hashOperation = _doGetHash();
  }

  Future<Digest> _doGetHash() async {
    try {
      final fileSize = await getSize();
      if (fileSize > constants.defaultMaxFileSize &&
          GlobalConfigService.instance.enforceMaxFileSize) {
        _hash = Digest(<int>[0]);
        return _hash!;
      }

      // Use the service for hash calculation
      final hashString = await _hashService.calculateFileHash(firstFile);
      // Convert string hash to Digest for compatibility
      final bytes = <int>[];
      for (int i = 0; i < hashString.length; i += 2) {
        final hex = hashString.substring(i, i + 2);
        bytes.add(int.parse(hex, radix: 16));
      }
      _hash = Digest(bytes);
      return _hash!;
    } finally {
      _hashOperation = null;
    }
  }

  /// Synchronous hash getter (legacy compatibility)
  Digest get hash {
    if (_hash != null) return _hash!;

    final fileSize = firstFile.lengthSync();
    if (fileSize > constants.defaultMaxFileSize &&
        GlobalConfigService.instance.enforceMaxFileSize) {
      return _hash = Digest(<int>[0]);
    }

    // Fallback to streaming sync calculation
    return _hash = _calculateHashStreamingSync();
  }

  /// Fallback synchronous hash calculation
  Digest _calculateHashStreamingSync() {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);

    try {
      const chunkSize = 1024 * 1024; // 1MB chunks
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
      input.close();
      rethrow;
    }
  }

  @override
  String toString() => _entity.toString();
}

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
