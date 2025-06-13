import '../entities/media_entity.dart';
import '../services/exif_writer_service.dart';
import '../value_objects/date_time_extraction_method.dart';

/// Modern domain model representing a collection of media entities
///
/// This replaces MediaCollection to use the new immutable MediaEntity
/// throughout the processing pipeline, providing better type safety and performance.
class MediaEntityCollection {
  MediaEntityCollection([final List<MediaEntity>? initialMedia])
    : _media = initialMedia ?? [];

  final List<MediaEntity> _media;

  /// Read-only access to the media list
  List<MediaEntity> get media => List.unmodifiable(_media);

  /// Number of media items in the collection
  int get length => _media.length;

  /// Whether the collection is empty
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;

  /// Add a single media entity to the collection
  void add(final MediaEntity mediaEntity) {
    _media.add(mediaEntity);
  }

  /// Add multiple media entities to the collection
  void addAll(final Iterable<MediaEntity> mediaEntities) {
    _media.addAll(mediaEntities);
  }

  /// Remove a media entity from the collection
  bool remove(final MediaEntity mediaEntity) => _media.remove(mediaEntity);

  /// Clear all media from the collection
  void clear() {
    _media.clear();
  }

  /// Extract dates from all media entities using configured date extractors
  ///
  /// This method applies date extraction algorithms to media entities that don't
  /// have dates, providing extraction method statistics.
  Future<Map<DateTimeExtractionMethod, int>> extractDates(
    final List<Future<DateTime?> Function(MediaEntity)> extractors, {
    final void Function(int current, int total)? onProgress,
  }) async {
    final extractionStats = <DateTimeExtractionMethod, int>{};

    for (int i = 0; i < _media.length; i++) {
      DateTimeExtractionMethod? extractionMethod;

      // Skip if media already has a date
      if (_media[i].dateTaken != null) {
        extractionMethod =
            _media[i].dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
      } else {
        // Try each extractor in sequence until one succeeds
        for (final extractor in extractors) {
          final extractedDate = await extractor(_media[i]);
          if (extractedDate != null) {
            _media[i] = _media[i].withDate(
              dateTaken: extractedDate,
              dateTimeExtractionMethod: DateTimeExtractionMethod
                  .guess, // Will be determined by extractor
            );
            extractionMethod = DateTimeExtractionMethod.guess;
            break;
          }
        }

        if (_media[i].dateTaken == null) {
          extractionMethod = DateTimeExtractionMethod.none;
          _media[i] = _media[i].withDate(
            dateTimeExtractionMethod: DateTimeExtractionMethod.none,
          );
        }
      }

      extractionStats[extractionMethod!] =
          (extractionStats[extractionMethod] ?? 0) + 1;

      onProgress?.call(i + 1, _media.length);
    }

    return extractionStats;
  }

  /// Write EXIF data to media files
  ///
  /// Updates EXIF metadata for media entities that have date/time information
  /// and coordinate data, tracking success statistics.
  Future<Map<String, int>> writeExifData({
    final void Function(int current, int total)? onProgress,
  }) async {
    const coordinatesWritten = 0;
    var dateTimesWritten = 0;

    for (int i = 0; i < _media.length; i++) {
      final mediaEntity = _media[i];

      // Write date/time to EXIF if available
      if (mediaEntity.dateTaken != null &&
          mediaEntity.dateTimeExtractionMethod !=
              DateTimeExtractionMethod.exif &&
          mediaEntity.dateTimeExtractionMethod !=
              DateTimeExtractionMethod.none) {
        final success = await writeDateTimeToExif(
          mediaEntity.dateTaken!,
          mediaEntity.files.firstFile,
        );
        if (success) {
          dateTimesWritten++;
        }
      }

      onProgress?.call(i + 1, _media.length);
    }

    return {
      'coordinatesWritten': coordinatesWritten,
      'dateTimesWritten': dateTimesWritten,
    };
  }

  /// Get processing statistics for the collection
  ///
  /// Returns comprehensive statistics about the media collection including
  /// file counts, date information, and extraction method distribution.
  ProcessingStatistics getStatistics() {
    var mediaWithDates = 0;
    var mediaWithAlbums = 0;
    var totalFiles = 0;
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final mediaEntity in _media) {
      // Count media with dates
      if (mediaEntity.dateTaken != null) {
        mediaWithDates++;
      }

      // Count media with album associations
      if (mediaEntity.files.hasAlbumFiles) {
        mediaWithAlbums++;
      }

      // Count total files
      totalFiles += mediaEntity.files.files.length;

      // Track extraction method distribution
      final method =
          mediaEntity.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
      extractionMethodDistribution[method] =
          (extractionMethodDistribution[method] ?? 0) + 1;
    }

    return ProcessingStatistics(
      totalMedia: _media.length,
      mediaWithDates: mediaWithDates,
      mediaWithAlbums: mediaWithAlbums,
      totalFiles: totalFiles,
      extractionMethodDistribution: extractionMethodDistribution,
    );
  }

  /// Get media entities as an iterable for processing
  Iterable<MediaEntity> get entities => _media;

  /// Access media entity by index
  MediaEntity operator [](final int index) => _media[index];

  /// Set media entity at index
  void operator []=(final int index, final MediaEntity mediaEntity) {
    _media[index] = mediaEntity;
  }
}

/// Statistics about processed media collection
class ProcessingStatistics {
  const ProcessingStatistics({
    required this.totalMedia,
    required this.mediaWithDates,
    required this.mediaWithAlbums,
    required this.totalFiles,
    required this.extractionMethodDistribution,
  });

  final int totalMedia;
  final int mediaWithDates;
  final int mediaWithAlbums;
  final int totalFiles;
  final Map<DateTimeExtractionMethod, int> extractionMethodDistribution;
}
