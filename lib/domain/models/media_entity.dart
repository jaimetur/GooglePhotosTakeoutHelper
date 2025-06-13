import 'dart:io';

/// Immutable domain model representing a media file (photo or video)
///
/// This replaces the mutable Media class with a clean, immutable model
/// that follows domain-driven design principles. Hash and size calculations
/// are handled by dedicated services for better testability.
class MediaEntity {
  const MediaEntity({
    required this.files,
    this.dateTaken,
    this.dateTakenAccuracy,
    this.dateTimeExtractionMethod = DateTimeExtractionMethod.none,
  });

  /// Map between album names and file paths for this media
  ///
  /// Key: Album name (null for files not in albums)
  /// Value: File representing the media in that context
  final Map<String?, File> files;

  /// The date and time when this media was taken
  final DateTime? dateTaken;

  /// Accuracy score for the date taken (lower is more accurate)
  ///
  /// Used to resolve conflicts when merging duplicates.
  /// This and [dateTaken] should either both be null or both be filled.
  final int? dateTakenAccuracy;

  /// Method used to extract the date/time
  final DateTimeExtractionMethod dateTimeExtractionMethod;

  /// First file with media, used in early stage when albums are not merged
  ///
  /// BE AWARE: This is a convenience getter. Use with caution as it
  /// may not represent the actual file you want in multi-album scenarios.
  File get primaryFile => files.values.first;

  /// Creates a copy of this media with updated values
  MediaEntity copyWith({
    final Map<String?, File>? files,
    final DateTime? dateTaken,
    final int? dateTakenAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) => MediaEntity(
    files: files ?? this.files,
    dateTaken: dateTaken ?? this.dateTaken,
    dateTakenAccuracy: dateTakenAccuracy ?? this.dateTakenAccuracy,
    dateTimeExtractionMethod:
        dateTimeExtractionMethod ?? this.dateTimeExtractionMethod,
  );

  /// Creates a new media entity with an additional file in the specified album
  MediaEntity addFileInAlbum(final String? albumName, final File file) {
    final newFiles = Map<String?, File>.from(files);
    newFiles[albumName] = file;
    return copyWith(files: newFiles);
  }

  /// Creates a new media entity with updated date information
  MediaEntity withDateInfo({
    required final DateTime dateTaken,
    required final int accuracy,
    required final DateTimeExtractionMethod method,
  }) => copyWith(
    dateTaken: dateTaken,
    dateTakenAccuracy: accuracy,
    dateTimeExtractionMethod: method,
  );

  /// Returns whether this media has date information
  bool get hasDateInfo => dateTaken != null && dateTakenAccuracy != null;

  /// Returns whether this media is more accurate than another
  bool isMoreAccurateThan(final MediaEntity other) {
    if (!hasDateInfo) return false;
    if (!other.hasDateInfo) return true;
    return dateTakenAccuracy! < other.dateTakenAccuracy!;
  }

  /// Returns all file paths for this media
  Iterable<String> get filePaths => files.values.map((final f) => f.path);

  /// Returns all album names this media appears in
  Iterable<String?> get albumNames => files.keys;

  /// Returns whether this media appears in any albums
  bool get hasAlbums => files.keys.any((final key) => key != null);

  /// Returns whether this media is only in year folders (no albums)
  bool get isOnlyInYearFolders => files.keys.every((final key) => key == null);

  @override
  bool operator ==(final Object other) =>
      identical(this, other) ||
      other is MediaEntity &&
          runtimeType == other.runtimeType &&
          _mapsEqual(files, other.files) &&
          dateTaken == other.dateTaken &&
          dateTakenAccuracy == other.dateTakenAccuracy &&
          dateTimeExtractionMethod == other.dateTimeExtractionMethod;

  @override
  int get hashCode =>
      files.hashCode ^
      dateTaken.hashCode ^
      dateTakenAccuracy.hashCode ^
      dateTimeExtractionMethod.hashCode;

  /// Helper method to compare maps for equality
  bool _mapsEqual<K, V>(final Map<K, V> map1, final Map<K, V> map2) {
    if (map1.length != map2.length) return false;
    for (final key in map1.keys) {
      if (!map2.containsKey(key) || map1[key] != map2[key]) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() =>
      'MediaEntity(files: ${files.length}, dateTaken: $dateTaken, '
      'accuracy: $dateTakenAccuracy, method: $dateTimeExtractionMethod)';
}

/// Enum representing different date/time extraction methods
///
/// Order is important! This represents the preference/accuracy order.
enum DateTimeExtractionMethod {
  /// Extracted from JSON metadata (most accurate)
  json,

  /// Extracted from EXIF data
  exif,

  /// Guessed from filename
  guess,

  /// Extracted from JSON with tryhard mode
  jsonTryHard,

  /// No date extraction performed
  none,
}

/// Extension to add legacy compatibility
extension DateTimeExtractionMethodLegacy on DateTimeExtractionMethod {
  /// Returns the accuracy score for this extraction method
  /// Lower numbers indicate higher accuracy
  int get accuracyScore {
    switch (this) {
      case DateTimeExtractionMethod.json:
        return 1;
      case DateTimeExtractionMethod.exif:
        return 2;
      case DateTimeExtractionMethod.guess:
        return 3;
      case DateTimeExtractionMethod.jsonTryHard:
        return 4;
      case DateTimeExtractionMethod.none:
        return 99;
    }
  }
}
