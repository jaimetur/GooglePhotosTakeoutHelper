import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'adapters/legacy_media_adapter.dart';
import 'domain/entities/media_entity.dart';
import 'domain/models/media_entity.dart' as domain;

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
    final domain.DateTimeExtractionMethod? dateTimeExtractionMethod,
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
  Map<String?, File> get files => _adapter.files;
  set files(final Map<String?, File> value) => _adapter.files = value;

  /// DateTaken from any source
  DateTime? get dateTaken => _adapter.dateTaken;
  set dateTaken(final DateTime? value) => _adapter.dateTaken = value;

  /// Higher number means worse accuracy
  int? get dateTakenAccuracy => _adapter.dateTakenAccuracy;
  set dateTakenAccuracy(final int? value) => _adapter.dateTakenAccuracy = value;

  /// The method/extractor that produced the DateTime
  domain.DateTimeExtractionMethod? get dateTimeExtractionMethod =>
      _adapter.dateTimeExtractionMethod;
  set dateTimeExtractionMethod(final domain.DateTimeExtractionMethod? value) =>
      _adapter.dateTimeExtractionMethod = value;

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
