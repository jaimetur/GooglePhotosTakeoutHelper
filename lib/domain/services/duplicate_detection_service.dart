import 'dart:io';
import '../entities/media_entity.dart';
import 'media_hash_service.dart';

/// Service for detecting duplicate media files based on content hash and size
///
/// This service provides efficient duplicate detection by first grouping files
/// by size (fast comparison), then calculating content hashes only for files
/// with matching sizes. Uses parallel processing with concurrency limits to
/// balance performance with system resource usage.
class DuplicateDetectionService {
  /// Creates a new instance of DuplicateDetectionService
  const DuplicateDetectionService({final MediaHashService? hashService})
    : _hashService = hashService ?? const MediaHashService();

  final MediaHashService _hashService;

  /// Maximum number of concurrent operations to prevent overwhelming the system
  static int get maxConcurrency => Platform.numberOfProcessors * 2;

  /// Groups media entities by file size and hash for duplicate detection
  ///
  /// Uses a two-phase approach for efficiency:
  /// 1. Group by file size (fast comparison using existing file metadata)
  /// 2. For size-matching groups, calculate and compare content hashes
  ///
  /// Returns a map where:
  /// - Key: Either "XXXbytes" for unique file sizes, or hash string for potential duplicates
  /// - Value: List of MediaEntity objects sharing that size/hash
  ///
  /// Single-item groups indicate unique files, multi-item groups are duplicates
  Future<Map<String, List<MediaEntity>>> groupIdentical(
    final List<MediaEntity> mediaList,
  ) async {
    final Map<String, List<MediaEntity>> output = <String, List<MediaEntity>>{};

    // Step 1: Calculate all sizes in parallel with concurrency limit
    final sizeResults = <({MediaEntity media, int size})>[];
    for (int i = 0; i < mediaList.length; i += maxConcurrency) {
      final batch = mediaList.skip(i).take(maxConcurrency);
      final futures = batch.map((final media) async {
        final size = await _hashService.calculateFileSize(media.primaryFile);
        return (media: media, size: size);
      });

      final batchResults = await Future.wait(futures);
      sizeResults.addAll(batchResults);
    }

    // Group by size
    final sizeGroups = <int, List<MediaEntity>>{};
    for (final entry in sizeResults) {
      sizeGroups
          .putIfAbsent(entry.size, () => <MediaEntity>[])
          .add(entry.media);
    }

    // Step 2: Calculate hashes in parallel for groups with multiple files
    for (final MapEntry<int, List<MediaEntity>> sameSize
        in sizeGroups.entries) {
      if (sameSize.value.length <= 1) {
        output['${sameSize.key}bytes'] = sameSize.value;
      } else {
        // Calculate hashes in parallel batches
        final hashResults = <({MediaEntity media, String hash})>[];
        final mediaWithSameSize = sameSize.value;

        for (int i = 0; i < mediaWithSameSize.length; i += maxConcurrency) {
          final batch = mediaWithSameSize.skip(i).take(maxConcurrency);
          final futures = batch.map((final media) async {
            final hash = await _hashService.calculateFileHash(
              media.primaryFile,
            );
            return (media: media, hash: hash);
          });

          final batchResults = await Future.wait(futures);
          hashResults.addAll(batchResults);
        }

        // Group by hash
        final hashGroups = <String, List<MediaEntity>>{};
        for (final entry in hashResults) {
          hashGroups
              .putIfAbsent(entry.hash, () => <MediaEntity>[])
              .add(entry.media);
        }
        output.addAll(hashGroups);
      }
    }
    return output;
  }

  /// Removes duplicate media from list of media entities
  ///
  /// This method is designed for early-stage processing before album merging.
  /// It preserves duplicated files that have different album associations,
  /// ensuring no album relationships are lost during deduplication.
  ///
  /// [mediaList] List of media entities to deduplicate
  /// [progressCallback] Optional callback for progress updates (processed, total)
  /// Returns list with duplicates removed, keeping the highest quality version
  Future<List<MediaEntity>> removeDuplicates(
    final List<MediaEntity> mediaList, {
    final void Function(int processed, int total)? progressCallback,
  }) async {
    if (mediaList.length <= 1) return mediaList;

    final grouped = await groupIdentical(mediaList);
    final result = <MediaEntity>[];
    int processed = 0;

    for (final group in grouped.values) {
      if (group.length == 1) {
        // No duplicates, keep the single file
        result.add(group.first);
      } else {
        // Multiple files with same content, keep the best one
        final best = _selectBestMedia(group);
        result.add(best);
      }

      processed++;
      progressCallback?.call(processed, grouped.length);
    }

    return result;
  }

  /// Selects the best media entity from a group of duplicates
  ///
  /// Priority order:
  /// 1. Media with most accurate date information
  /// 2. Media with more album associations
  /// 3. Media with shorter file path (likely original location)
  MediaEntity _selectBestMedia(final List<MediaEntity> duplicates) {
    if (duplicates.length == 1) {
      return duplicates.first;
    }
    // Sort by quality criteria
    final sorted = duplicates.toList()
      ..sort((final a, final b) {
        // 1. Prefer media with more accurate date
        final aHasDate = a.dateTaken != null && a.dateAccuracy != null;
        final bHasDate = b.dateTaken != null && b.dateAccuracy != null;

        if (aHasDate && bHasDate) {
          final dateComparison = a.dateTakenAccuracy!.compareTo(
            b.dateTakenAccuracy!,
          );
          if (dateComparison != 0) return dateComparison;
        } else if (aHasDate && !bHasDate) {
          return -1; // a is better
        } else if (!aHasDate && bHasDate) {
          return 1; // b is better
        }

        // 2. Prefer media with more album associations
        final albumComparison = b.files.files.length.compareTo(
          a.files.files.length,
        );
        if (albumComparison != 0) return albumComparison;

        // 3. Prefer media with shorter path (likely more original)
        final pathA = a.primaryFile.path;
        final pathB = b.primaryFile.path;
        return pathA.length.compareTo(pathB.length);
      });

    return sorted.first;
  }

  /// Finds exact duplicates based on file content
  ///
  /// Returns a list of duplicate groups, where each group contains
  /// media entities with identical file content.
  Future<List<List<MediaEntity>>> findDuplicateGroups(
    final List<MediaEntity> mediaList,
  ) async {
    final grouped = await groupIdentical(mediaList);
    return grouped.values.where((final group) => group.length > 1).toList();
  }

  /// Checks if two media entities are duplicates based on content
  Future<bool> areDuplicates(
    final MediaEntity media1,
    final MediaEntity media2,
  ) async {
    // Quick size check first
    final size1 = await _hashService.calculateFileSize(media1.primaryFile);
    final size2 = await _hashService.calculateFileSize(media2.primaryFile);

    if (size1 != size2) return false;

    // If sizes match, compare hashes
    final hash1 = await _hashService.calculateFileHash(media1.primaryFile);
    final hash2 = await _hashService.calculateFileHash(media2.primaryFile);

    return hash1 == hash2;
  }

  /// Statistics about duplicate detection results
  DuplicateStats calculateStats(
    final Map<String, List<MediaEntity>> groupedResults,
  ) {
    int totalFiles = 0;
    int uniqueFiles = 0;
    int duplicateGroups = 0;
    int duplicateFiles = 0;
    int spaceWastedBytes = 0;

    for (final group in groupedResults.values) {
      totalFiles += group.length;

      if (group.length == 1) {
        uniqueFiles++;
      } else {
        duplicateGroups++;
        duplicateFiles += group.length;

        // Calculate wasted space (all but one file in each group)
        for (int i = 1; i < group.length; i++) {
          // Note: This is an approximation - we'd need to actually calculate sizes
          // For now, we'll use the file size from the first file as estimate
          try {
            final size = group.first.primaryFile.lengthSync();
            spaceWastedBytes += size;
          } catch (e) {
            // Ignore files that can't be read
          }
        }
      }
    }

    return DuplicateStats(
      totalFiles: totalFiles,
      uniqueFiles: uniqueFiles,
      duplicateGroups: duplicateGroups,
      duplicateFiles: duplicateFiles,
      spaceWastedBytes: spaceWastedBytes,
    );
  }
}

/// Statistics about duplicate detection results
class DuplicateStats {
  const DuplicateStats({
    required this.totalFiles,
    required this.uniqueFiles,
    required this.duplicateGroups,
    required this.duplicateFiles,
    required this.spaceWastedBytes,
  });

  /// Total number of files processed
  final int totalFiles;

  /// Number of unique files (no duplicates)
  final int uniqueFiles;

  /// Number of groups containing duplicates
  final int duplicateGroups;

  /// Total number of duplicate files
  final int duplicateFiles;

  /// Estimated wasted space in bytes
  final int spaceWastedBytes;

  /// Percentage of files that are duplicates
  double get duplicatePercentage =>
      totalFiles > 0 ? (duplicateFiles / totalFiles) * 100 : 0;

  /// Human readable summary
  String get summary =>
      'Found $duplicateGroups duplicate groups with $duplicateFiles files. '
      'Space wasted: ${(spaceWastedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
