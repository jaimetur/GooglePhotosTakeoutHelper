import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'adapters/legacy_media_adapter.dart';
import 'domain/entities/media_entity.dart';
import 'domain/value_objects/date_accuracy.dart';
import 'domain/value_objects/date_time_extraction_method.dart';

/// Abstract of a *media* - a photo or video
///
/// This class now delegates to the immutable MediaEntity through an adapter
/// to maintain backward compatibility while transitioning to clean architecture.
///
/// The [files] map maintains album associations where null represents year-based
/// organization and strings represent album names.
///
/// [dateTakenAccuracy] is used for comparison - lower values indicate better accuracy.
/// When merging duplicates, the media with lower accuracy value is preferred.
class Media {
  /// Creates a new Media instance
  Media(
    final Map<String?, File> files, {
    final DateTime? dateTaken,
    final int? dateTakenAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) : _adapter = LegacyMediaAdapter.fromLegacy(
         files,
         dateTaken: dateTaken,
         dateTakenAccuracy: dateTakenAccuracy,
         dateTimeExtractionMethod: dateTimeExtractionMethod,
       );

  /// Creates from an immutable MediaEntity
  Media.fromEntity(final MediaEntity entity)
    : _adapter = LegacyMediaAdapter(entity);

  final LegacyMediaAdapter _adapter;

  /// Gets the immutable entity for services that need it
  MediaEntity get entity => _adapter.entity;

  /// Gets the adapter for clean architecture services
  LegacyMediaAdapter get adapter => _adapter;

  /// First file with media, used in early stage when albums are not merged
  File get firstFile => _adapter.firstFile;

  /// Map between albums and files of same given media
  ///
  /// Note: This returns a copy for safety. Use immutable operations like
  /// withFile() or withFiles() to create modified versions.
  Map<String?, File> get files => Map.unmodifiable(_adapter.files);

  /// DateTaken from any source
  DateTime? get dateTaken => _adapter.dateTaken;

  /// Higher number means worse accuracy
  int? get dateTakenAccuracy => _adapter.dateTakenAccuracy;

  /// The method/extractor that produced the DateTime
  DateTimeExtractionMethod? get dateTimeExtractionMethod =>
      _adapter.dateTimeExtractionMethod;

  /// Creates a new Media instance with additional file association
  /// This replaces direct modification of the files map
  Media withFile(final String? albumName, final File file) =>
      Media.fromEntity(_adapter.entity.withFile(albumName, file));

  /// Creates a new Media instance with multiple additional files
  /// This replaces direct modification of the files map
  Media withFiles(final Map<String?, File> additionalFiles) =>
      Media.fromEntity(_adapter.entity.withFiles(additionalFiles));

  /// Creates a new Media instance with updated date information
  /// This replaces direct modification of date properties
  Media withDate({
    final DateTime? dateTaken,
    final int? dateTakenAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) => Media.fromEntity(
    _adapter.entity.withDate(
      dateTaken: dateTaken,
      dateAccuracy: dateTakenAccuracy != null
          ? DateAccuracy.fromInt(dateTakenAccuracy)
          : null,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
    ),
  );

  /// Creates a new Media instance without a specific album association
  Media withoutAlbum(final String? albumName) =>
      Media.fromEntity(_adapter.entity.withoutAlbum(albumName));

  /// Merges this media with another, taking the better date accuracy
  Media mergeWith(final Media other) =>
      Media.fromEntity(_adapter.entity.mergeWith(other.entity));

  /// Async size calculation - preferred method
  Future<int> getSize() => _adapter.getSize();

  /// Synchronous size getter for backward compatibility
  int get size => _adapter.size;

  /// Async hash calculation - preferred method
  Future<Digest> getHash() => _adapter.getHash();

  /// Synchronous hash getter for backward compatibility
  Digest get hash => _adapter.hash;

  @override
  String toString() => _adapter.toString();
}
