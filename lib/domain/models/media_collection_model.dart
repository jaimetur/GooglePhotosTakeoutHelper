import 'dart:io';

import '../../extras.dart' as extras;
import '../../grouping.dart' as grouping;
import '../../media.dart';
import '../adapters/media_collection_adapter.dart';
import '../services/date_extraction/date_extractor_service.dart';
import '../services/exif_writer_service.dart';
import '../value_objects/date_time_extraction_method.dart';

/// Domain model representing a collection of media files with business operations
///
/// This replaces the global mutable `List<Media>` media with a proper domain object
/// that encapsulates media-related operations and maintains consistency.
///
/// Now uses MediaEntityCollection internally via adapter for modern immutable operations.
class MediaCollection {
  MediaCollection([final List<Media>? initialMedia])
    : _adapter = MediaCollectionAdapter() {
    if (initialMedia != null) {
      _adapter.addAll(initialMedia);
    }
  }

  final MediaCollectionAdapter _adapter;

  /// Read-only access to the media list
  List<Media> get media => _adapter.media;

  /// Number of media items in the collection
  int get length => _adapter.length;

  /// Whether the collection is empty
  bool get isEmpty => _adapter.isEmpty;
  bool get isNotEmpty => _adapter.isNotEmpty;

  /// Add a single media item to the collection
  void add(final Media media) {
    _adapter.add(media);
  }

  /// Add multiple media items to the collection
  void addAll(final Iterable<Media> mediaItems) {
    _adapter.addAll(mediaItems);
  }

  /// Remove duplicates from the collection and return the count removed
  int removeDuplicates() => grouping.removeDuplicates(_adapter.media);

  /// Ultra-fast async version of removeDuplicates for massive performance gains
  /// Uses parallel processing to dramatically improve performance on large collections
  Future<int> removeDuplicatesAsyncOptimized() =>
      grouping.removeDuplicatesAsyncOptimized(_adapter.media);

  /// Remove "extra" files (edited versions) and return the count removed
  int removeExtras() => extras.removeExtras(_adapter.media);

  /// Find and merge album relationships
  void findAlbums() {
    grouping.findAlbums(_adapter.media);
  }

  /// Async version of findAlbums for better performance
  /// Uses streaming hash calculation to avoid loading entire files into memory
  Future<void> findAlbumsAsync() => grouping.findAlbumsAsync(_adapter.media);

  /// Extract dates from all media using the provided extractors
  Future<Map<DateTimeExtractionMethod, int>> extractDates(
    final List<DateTimeExtractor> extractors, {
    final ProgressCallback? onProgress,
  }) async {
    final extractionStats = <DateTimeExtractionMethod, int>{};
    final mediaList = _adapter.media; // Get current list

    for (int i = 0; i < mediaList.length; i++) {
      int extractorIndex = 0;
      DateTimeExtractionMethod? extractionMethod;
      for (final extractor in extractors) {
        final date = await extractor(mediaList[i].firstFile);
        if (date != null) {
          _adapter[i] = mediaList[i].withDate(
            dateTaken: date,
            dateTakenAccuracy: extractorIndex,
          );
          extractionMethod = DateTimeExtractionMethod.values[extractorIndex];
          break;
        }
        extractorIndex++;
      }

      if (mediaList[i].dateTaken == null) {
        extractionMethod = DateTimeExtractionMethod.none;
        _adapter[i] = mediaList[i].withDate(
          dateTimeExtractionMethod: DateTimeExtractionMethod.none,
        );
      } else {
        _adapter[i] = mediaList[i].withDate(
          dateTimeExtractionMethod: extractionMethod,
        );
      }

      extractionStats[extractionMethod!] =
          (extractionStats[extractionMethod] ?? 0) + 1;

      onProgress?.call(i + 1, mediaList.length);
    }

    return extractionStats;
  }

  /// Write EXIF data to media files and return counts
  Future<ExifWriteResult> writeExifData({
    final ProgressCallback? onProgress,
  }) async {
    int coordinatesWritten = 0;
    int dateTimesWritten = 0;
    final mediaList = _adapter.media; // Get current list

    for (int i = 0; i < mediaList.length; i++) {
      final currentFile = mediaList[i].firstFile;

      // Write coordinates if available
      final coords = await jsonCoordinatesExtractor(currentFile);
      if (coords != null) {
        if (await writeGpsToExif(coords, currentFile)) {
          coordinatesWritten++;
        }
      }

      // Write datetime if not already from EXIF and has a date
      if (mediaList[i].dateTimeExtractionMethod !=
              DateTimeExtractionMethod.exif &&
          mediaList[i].dateTimeExtractionMethod !=
              DateTimeExtractionMethod.none) {
        if (await writeDateTimeToExif(mediaList[i].dateTaken!, currentFile)) {
          dateTimesWritten++;
        }
      }

      onProgress?.call(i + 1, mediaList.length);
    }

    return ExifWriteResult(
      coordinatesWritten: coordinatesWritten,
      dateTimesWritten: dateTimesWritten,
    );
  }

  /// Ensure all media have a null key for ALL_PHOTOS processing
  void ensureAllPhotosKeys() {
    final mediaList = _adapter.media;
    for (final media in mediaList) {
      if (media.files[null] == null) {
        media.files[null] = media.files.values.first;
      }
    }
  }

  /// Transform Pixel Motion Photo extensions
  Future<void> transformPixelExtensions(final String newExtension) async {
    await _changeMPExtensions(_adapter.media, newExtension);
  }

  /// Changes .MP and .MV file extensions to the specified new extension
  ///
  /// This function renames Pixel Motion Photo files (.MP/.MV) to a more
  /// compatible extension like .mp4 for better cross-platform support.
  Future<void> _changeMPExtensions(
    final List<Media> mediaList,
    final String newExtension,
  ) async {
    for (final media in mediaList) {
      // Check if this media has .MP or .MV files
      final filesToRename = <String?, File>{};

      for (final entry in media.files.entries) {
        final file = entry.value;
        final extension = file.path.split('.').last.toLowerCase();

        // Check if this is a Pixel Motion Photo file
        if (extension == 'mp' || extension == 'mv') {
          filesToRename[entry.key] = file;
        }
      }

      // Rename the files
      for (final entry in filesToRename.entries) {
        final albumName = entry.key;
        final oldFile = entry.value;

        // Create new file path with the desired extension
        final pathWithoutExtension = oldFile.path.substring(
          0,
          oldFile.path.lastIndexOf('.'),
        );
        final newPath = '$pathWithoutExtension.$newExtension';
        final newFile = File(newPath);

        try {
          // Rename the file
          await oldFile.rename(newPath);

          // Update the media object
          media.files[albumName] = newFile;
        } catch (e) {
          // Log the error but continue processing other files
          print('Warning: Failed to rename ${oldFile.path} to $newPath: $e');
        }
      }
    }
  }

  /// Get statistics about the media collection
  MediaCollectionStats get stats {
    final albumCounts = <String, int>{};
    final accuracyDistribution = <int, int>{};
    final extractionMethodDistribution = <DateTimeExtractionMethod, int>{};
    final mediaList = _adapter.media;

    for (final media in mediaList) {
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
      totalCount: mediaList.length,
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
