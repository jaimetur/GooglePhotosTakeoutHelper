import 'package:crypto/crypto.dart';

import '../../entities/media_entity.dart';
import '../core/logging_service.dart';

/// Service for detecting and managing album relationships between media files
///
/// This service handles the complex logic of merging media files that appear
/// in both year-based folders and album folders, maintaining all file associations
/// while choosing the best metadata.
class AlbumRelationshipService with LoggerMixin {
  /// Creates a new album relationship service
  AlbumRelationshipService();

  /// Finds and merges album relationships in a list of media entities
  ///
  /// This processes media files that appear in multiple locations (year folders
  /// and album folders) and merges them into single entities with all file
  /// associations preserved.
  ///
  /// Returns a new list with merged entities, where duplicates have been
  /// combined and the best metadata has been preserved.
  Future<List<MediaEntity>> detectAndMergeAlbums(
    final List<MediaEntity> mediaList,
  ) async {
    if (mediaList.isEmpty) {
      return [];
    }

    logInfo('Starting album detection for ${mediaList.length} media files');

    // Group identical media by content
    final identicalGroups = await _groupIdenticalMedia(mediaList);

    final List<MediaEntity> mergedResults = [];
    int mergedCount = 0;

    // Process each group of identical media
    for (final group in identicalGroups.values) {
      if (group.length <= 1) {
        // No duplicates to merge
        mergedResults.addAll(group);
      } else {
        // Merge the group into a single entity
        final merged = _mergeMediaGroup(group);
        mergedResults.add(merged);
        mergedCount += group.length - 1; // Count how many were merged
      }
    }

    logInfo('Album detection complete: merged $mergedCount duplicate files');
    logInfo('Final result: ${mergedResults.length} unique media files');

    return mergedResults;
  }

  /// Groups media entities by their content using file size and content hash
  Future<Map<String, List<MediaEntity>>> _groupIdenticalMedia(
    final List<MediaEntity> mediaList,
  ) async {
    final groups = <String, List<MediaEntity>>{};

    for (final entity in mediaList) {
      try {
        // Use file size and MD5 content hash for reliable duplicate detection
        final size = await entity.primaryFile.length();
        final content = await entity.primaryFile.readAsBytes();

        // Use MD5 hash for consistent content-based grouping
        final digest = md5.convert(content);
        final contentKey = '${size}_$digest';

        groups.putIfAbsent(contentKey, () => []).add(entity);
      } catch (e) {
        logWarning(
          'Skipping file during album detection due to error: ${entity.primaryFile.path} - $e',
        );
        // Add the entity to a special group for unprocessable files
        // This ensures it's still included in the final results
        groups
            .putIfAbsent('unprocessable_${entity.primaryFile.path}', () => [])
            .add(entity);
      }
    }

    return groups;
  }

  /// Merges a group of identical media entities into a single entity
  ///
  /// Combines all file associations and preserves the best metadata
  /// from all entities in the group. The merging process:
  /// 1. Starts with the first entity as the base
  /// 2. Iteratively merges each additional entity
  /// 3. Combines file associations from all entities
  /// 4. Preserves all album relationships
  MediaEntity _mergeMediaGroup(final List<MediaEntity> group) {
    if (group.isEmpty) {
      throw ArgumentError('Cannot merge empty group');
    }
    if (group.length == 1) {
      return group.first;
    }
    logDebug('Merging group of ${group.length} identical media files');

    // Debug: log file associations before merging
    for (int i = 0; i < group.length; i++) {
      final entity = group[i];
      logDebug(
        'Entity $i: ${entity.primaryFile.path}, albums: ${entity.albumNames}',
      );
    }

    // Start with the first entity and merge others into it
    MediaEntity result = group.first;
    for (int i = 1; i < group.length; i++) {
      result = result.mergeWith(group[i]);
      logDebug('After merging with entity $i: albums: ${result.albumNames}');
    }
    logDebug(
      'Merged into entity with ${result.files.length} file associations '
      'and ${result.albumNames.length} album(s)',
    );

    return result;
  }

  /// Finds media entities that exist in albums
  List<MediaEntity> findAlbumMedia(final List<MediaEntity> mediaList) =>
      mediaList.where((final entity) => entity.hasAlbumAssociations).toList();

  /// Finds media entities that only exist in year-based organization
  List<MediaEntity> findYearOnlyMedia(final List<MediaEntity> mediaList) =>
      mediaList
          .where(
            (final entity) =>
                !entity.hasAlbumAssociations && entity.files.hasYearBasedFiles,
          )
          .toList();

  /// Gets statistics about album associations
  AlbumStatistics getAlbumStatistics(final List<MediaEntity> mediaList) {
    final albumMedia = findAlbumMedia(mediaList);
    final yearOnlyMedia = findYearOnlyMedia(mediaList);

    // Count unique albums
    final allAlbums = <String>{};
    for (final entity in albumMedia) {
      allAlbums.addAll(entity.albumNames);
    }

    // Count files with multiple album associations
    final multiAlbumFiles = albumMedia
        .where((final entity) => entity.albumNames.length > 1)
        .length;

    return AlbumStatistics(
      totalFiles: mediaList.length,
      albumFiles: albumMedia.length,
      yearOnlyFiles: yearOnlyMedia.length,
      uniqueAlbums: allAlbums.length,
      multiAlbumFiles: multiAlbumFiles,
      albumNames: allAlbums,
    );
  }
}

/// Statistics about album detection and organization
class AlbumStatistics {
  const AlbumStatistics({
    required this.totalFiles,
    required this.albumFiles,
    required this.yearOnlyFiles,
    required this.uniqueAlbums,
    required this.multiAlbumFiles,
    required this.albumNames,
  });

  final int totalFiles;
  final int albumFiles;
  final int yearOnlyFiles;
  final int uniqueAlbums;
  final int multiAlbumFiles;
  final Set<String> albumNames;

  @override
  String toString() =>
      'AlbumStatistics('
      'total: $totalFiles, '
      'in albums: $albumFiles, '
      'year-only: $yearOnlyFiles, '
      'albums: $uniqueAlbums, '
      'multi-album files: $multiAlbumFiles'
      ')';
}
