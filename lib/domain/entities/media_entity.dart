import 'dart:io';

import '../models/media_entity.dart' as domain;
import '../value_objects/date_accuracy.dart';
import '../value_objects/media_files_collection.dart';

/// Immutable domain entity representing a media file (photo or video)
///
/// This is the core domain model for media files, designed to be immutable
/// and thread-safe. All modifications return new instances rather than
/// mutating existing state.
class MediaEntity {
  /// Creates a new media entity
  const MediaEntity({
    required this.files,
    this.dateTaken,
    this.dateAccuracy,
    this.dateTimeExtractionMethod,
  });

  /// Creates a media entity with a single file
  factory MediaEntity.single({
    required final File file,
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final domain.DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) => MediaEntity(
    files: MediaFilesCollection.single(file),
    dateTaken: dateTaken,
    dateAccuracy: dateAccuracy,
    dateTimeExtractionMethod: dateTimeExtractionMethod,
  );

  /// Creates a media entity from a legacy map structure
  factory MediaEntity.fromMap({
    required final Map<String?, File> files,
    final DateTime? dateTaken,
    final int? dateTakenAccuracy,
    final domain.DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) => MediaEntity(
    files: MediaFilesCollection.fromMap(files),
    dateTaken: dateTaken,
    dateAccuracy: DateAccuracy.fromNullableInt(dateTakenAccuracy),
    dateTimeExtractionMethod: dateTimeExtractionMethod,
  );

  /// Collection of files associated with this media
  final MediaFilesCollection files;

  /// Date when the media was taken/created
  final DateTime? dateTaken;

  /// Accuracy of the date extraction
  final DateAccuracy? dateAccuracy;

  /// Method used to extract the date/time
  final domain.DateTimeExtractionMethod? dateTimeExtractionMethod;

  /// Gets the primary file for this media
  File get primaryFile => files.firstFile;

  /// Gets the legacy accuracy value for backward compatibility
  int? get dateTakenAccuracy => dateAccuracy?.value;

  /// Whether this media has reliable date information
  bool get hasReliableDate => dateAccuracy?.isReliable ?? false;

  /// Whether this media is associated with albums
  bool get hasAlbumAssociations => files.hasAlbumFiles;

  /// Gets all album names this media is associated with
  Set<String> get albumNames => files.albumNames;

  /// Creates a new media entity with additional file association
  MediaEntity withFile(final String? albumName, final File file) => MediaEntity(
    files: files.withFile(albumName, file),
    dateTaken: dateTaken,
    dateAccuracy: dateAccuracy,
    dateTimeExtractionMethod: dateTimeExtractionMethod,
  );

  /// Creates a new media entity with multiple additional files
  MediaEntity withFiles(final Map<String?, File> additionalFiles) =>
      MediaEntity(
        files: files.withFiles(additionalFiles),
        dateTaken: dateTaken,
        dateAccuracy: dateAccuracy,
        dateTimeExtractionMethod: dateTimeExtractionMethod,
      );

  /// Creates a new media entity with updated date information
  MediaEntity withDate({
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final domain.DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) => MediaEntity(
    files: files,
    dateTaken: dateTaken ?? this.dateTaken,
    dateAccuracy: dateAccuracy ?? this.dateAccuracy,
    dateTimeExtractionMethod:
        dateTimeExtractionMethod ?? this.dateTimeExtractionMethod,
  );

  /// Creates a new media entity without a specific album association
  MediaEntity withoutAlbum(final String? albumName) => MediaEntity(
    files: files.withoutAlbum(albumName),
    dateTaken: dateTaken,
    dateAccuracy: dateAccuracy,
    dateTimeExtractionMethod: dateTimeExtractionMethod,
  );

  /// Merges this media entity with another, taking the better date accuracy
  MediaEntity mergeWith(final MediaEntity other) {
    // Combine all files
    final combinedFiles = files.withFiles(other.files.files);

    // Choose better date information
    final DateTime? bestDate;
    final DateAccuracy? bestAccuracy;
    final domain.DateTimeExtractionMethod? bestMethod;

    if (dateAccuracy == null && other.dateAccuracy == null) {
      // Neither has date info
      bestDate = dateTaken ?? other.dateTaken;
      bestAccuracy = null;
      bestMethod = dateTimeExtractionMethod ?? other.dateTimeExtractionMethod;
    } else if (dateAccuracy == null) {
      // Other has date info, this doesn't
      bestDate = other.dateTaken;
      bestAccuracy = other.dateAccuracy;
      bestMethod = other.dateTimeExtractionMethod;
    } else if (other.dateAccuracy == null) {
      // This has date info, other doesn't
      bestDate = dateTaken;
      bestAccuracy = dateAccuracy;
      bestMethod = dateTimeExtractionMethod;
    } else {
      // Both have date info, choose better accuracy
      if (dateAccuracy!.isBetterThan(other.dateAccuracy!)) {
        bestDate = dateTaken;
        bestAccuracy = dateAccuracy;
        bestMethod = dateTimeExtractionMethod;
      } else {
        bestDate = other.dateTaken;
        bestAccuracy = other.dateAccuracy;
        bestMethod = other.dateTimeExtractionMethod;
      }
    }

    return MediaEntity(
      files: combinedFiles,
      dateTaken: bestDate,
      dateAccuracy: bestAccuracy,
      dateTimeExtractionMethod: bestMethod,
    );
  }

  @override
  bool operator ==(final Object other) {
    if (identical(this, other)) return true;
    return other is MediaEntity &&
        other.files == files &&
        other.dateTaken == dateTaken &&
        other.dateAccuracy == dateAccuracy &&
        other.dateTimeExtractionMethod == dateTimeExtractionMethod;
  }

  @override
  int get hashCode =>
      Object.hash(files, dateTaken, dateAccuracy, dateTimeExtractionMethod);

  @override
  String toString() {
    final dateInfo = dateTaken != null ? ', dateTaken: $dateTaken' : '';
    final accuracyInfo = dateAccuracy != null
        ? ' (${dateAccuracy!.description})'
        : '';
    return 'MediaEntity(${primaryFile.path}$dateInfo$accuracyInfo, albums: ${albumNames.length})';
  }
}
