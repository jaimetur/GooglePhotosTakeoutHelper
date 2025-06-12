import '../../extras.dart' as extras;
import '../../grouping.dart' as grouping;
import '../../media.dart';
import '../../utils.dart';
import '../services/date_extraction/date_extractor_service.dart';
import '../services/exif_writer_service.dart';

/// Domain model representing a collection of media files with business operations
///
/// This replaces the global mutable `List<Media>` media with a proper domain object
/// that encapsulates media-related operations and maintains consistency.
class MediaCollection {
  MediaCollection([final List<Media>? initialMedia])
    : _media = initialMedia ?? [];

  final List<Media> _media;

  /// Read-only access to the media list
  List<Media> get media => List.unmodifiable(_media);

  /// Number of media items in the collection
  int get length => _media.length;

  /// Whether the collection is empty
  bool get isEmpty => _media.isEmpty;
  bool get isNotEmpty => _media.isNotEmpty;

  /// Add a single media item to the collection
  void add(final Media media) {
    _media.add(media);
  }

  /// Add multiple media items to the collection
  void addAll(final Iterable<Media> mediaItems) {
    _media.addAll(mediaItems);
  }

  /// Remove duplicates from the collection and return the count removed
  int removeDuplicates() => grouping.removeDuplicates(_media);

  /// Ultra-fast async version of removeDuplicates for massive performance gains
  /// Uses parallel processing to dramatically improve performance on large collections
  Future<int> removeDuplicatesAsyncOptimized() =>
      grouping.removeDuplicatesAsyncOptimized(_media);

  /// Remove "extra" files (edited versions) and return the count removed
  int removeExtras() => extras.removeExtras(_media);

  /// Find and merge album relationships
  void findAlbums() {
    grouping.findAlbums(_media);
  }

  /// Async version of findAlbums for better performance
  /// Uses streaming hash calculation to avoid loading entire files into memory
  Future<void> findAlbumsAsync() => grouping.findAlbumsAsync(_media);

  /// Extract dates from all media using the provided extractors
  Future<Map<DateTimeExtractionMethod, int>> extractDates(
    final List<DateTimeExtractor> extractors, {
    final ProgressCallback? onProgress,
  }) async {
    final extractionStats = <DateTimeExtractionMethod, int>{};

    for (int i = 0; i < _media.length; i++) {
      int extractorIndex = 0;
      DateTimeExtractionMethod? extractionMethod;

      for (final extractor in extractors) {
        final date = await extractor(_media[i].firstFile);
        if (date != null) {
          _media[i].dateTaken = date;
          _media[i].dateTakenAccuracy = extractorIndex;
          extractionMethod = DateTimeExtractionMethod.values[extractorIndex];
          break;
        }
        extractorIndex++;
      }

      if (_media[i].dateTaken == null) {
        extractionMethod = DateTimeExtractionMethod.none;
        _media[i].dateTimeExtractionMethod = DateTimeExtractionMethod.none;
      } else {
        _media[i].dateTimeExtractionMethod = extractionMethod;
      }

      extractionStats[extractionMethod!] =
          (extractionStats[extractionMethod] ?? 0) + 1;

      onProgress?.call(i + 1, _media.length);
    }

    return extractionStats;
  }

  /// Write EXIF data to media files and return counts
  Future<ExifWriteResult> writeExifData({
    final ProgressCallback? onProgress,
  }) async {
    int coordinatesWritten = 0;
    int dateTimesWritten = 0;

    for (int i = 0; i < _media.length; i++) {
      final currentFile = _media[i].firstFile;

      // Write coordinates if available
      final coords = await jsonCoordinatesExtractor(currentFile);
      if (coords != null) {
        if (await writeGpsToExif(coords, currentFile)) {
          coordinatesWritten++;
        }
      }

      // Write datetime if not already from EXIF and has a date
      if (_media[i].dateTimeExtractionMethod != DateTimeExtractionMethod.exif &&
          _media[i].dateTimeExtractionMethod != DateTimeExtractionMethod.none) {
        if (await writeDateTimeToExif(_media[i].dateTaken!, currentFile)) {
          dateTimesWritten++;
        }
      }

      onProgress?.call(i + 1, _media.length);
    }

    return ExifWriteResult(
      coordinatesWritten: coordinatesWritten,
      dateTimesWritten: dateTimesWritten,
    );
  }

  /// Ensure all media have a null key for ALL_PHOTOS processing
  void ensureAllPhotosKeys() {
    for (final media in _media) {
      if (media.files[null] == null) {
        media.files[null] = media.files.values.first;
      }
    }
  }

  /// Transform Pixel Motion Photo extensions
  Future<void> transformPixelExtensions(final String newExtension) async {
    await changeMPExtensions(_media, newExtension);
  }

  /// Get statistics about the media collection
  MediaCollectionStats get stats {
    final albumCounts = <String, int>{};
    final accuracyDistribution = <int, int>{};
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};

    for (final media in _media) {
      // Count albums
      for (final albumName in media.files.keys) {
        if (albumName != null) {
          albumCounts[albumName] = (albumCounts[albumName] ?? 0) + 1;
        }
      }

      // Count accuracy levels
      final accuracy = media.dateTakenAccuracy ?? -1;
      accuracyDistribution[accuracy] =
          (accuracyDistribution[accuracy] ?? 0) + 1;

      // Count extraction methods
      final method =
          media.dateTimeExtractionMethod ?? DateTimeExtractionMethod.none;
      extractionMethodDistribution[method] =
          (extractionMethodDistribution[method] ?? 0) + 1;
    }

    return MediaCollectionStats(
      totalCount: _media.length,
      albumCounts: albumCounts,
      accuracyDistribution: accuracyDistribution,
      extractionMethodDistribution: extractionMethodDistribution,
    );
  }
}

/// Result of EXIF writing operations
class ExifWriteResult {
  const ExifWriteResult({
    required this.coordinatesWritten,
    required this.dateTimesWritten,
  });

  final int coordinatesWritten;
  final int dateTimesWritten;
}

/// Statistics about a media collection
class MediaCollectionStats {
  const MediaCollectionStats({
    required this.totalCount,
    required this.albumCounts,
    required this.accuracyDistribution,
    required this.extractionMethodDistribution,
  });

  final int totalCount;
  final Map<String, int> albumCounts;
  final Map<int, int> accuracyDistribution;
  final Map<DateTimeExtractionMethod, int> extractionMethodDistribution;
}

/// Callback type for progress reporting
typedef ProgressCallback = void Function(int current, int total);
