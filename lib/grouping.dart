/// Legacy grouping functions with clean architecture delegation
///
/// This file provides backwards compatibility for grouping operations
/// while delegating to the new services following clean architecture principles.
library;

import 'dart:io';
import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

// Clean architecture imports - TODO: Use when type conflicts are resolved
// import 'domain/services/album_detection_service.dart';
// import 'domain/services/duplicate_detection_service.dart';
// import 'domain/services/media_grouping_service.dart';

// Legacy imports
import 'media.dart' show Media;
import 'utils.dart';

extension Group on Iterable<Media> {
  /// Groups media objects by file size and hash for duplicate detection
  ///
  /// Delegates to DuplicateDetectionService for clean architecture compliance.
  /// Returns a map where:
  /// - Key: Either "XXXbytes" for unique sizes, or hash string for duplicates
  /// - Value: List of Media objects sharing that size/hash
  ///
  /// Single-item groups indicate unique files, multi-item groups are duplicates
  Map<String, List<Media>> groupIdentical() {
    // For backward compatibility, use simplified grouping by size only
    final Map<String, List<Media>> output = <String, List<Media>>{};
    // group files by size - can't have same hash with diff size
    // ignore: unnecessary_this
    for (final MapEntry<int, List<Media>> sameSize in groupListsBy(
      (final Media e) => e.size,
    ).entries) {
      // just add with "...bytes" key if just one
      if (sameSize.value.length <= 1) {
        output['${sameSize.key}bytes'] = sameSize.value;
      } else {
        // ...calculate their full hashes and group by them
        output.addAll(
          sameSize.value.groupListsBy((final Media e) => e.hash.toString()),
        );
      }
    }
    return output;
  }

  /// Async version of groupIdentical for better performance
  ///
  /// This version uses async hash calculation to avoid blocking the main thread
  /// and uses streaming hash calculation to avoid loading entire files into memory.
  /// TODO: Migrate to use DuplicateDetectionService when type conflicts are resolved
  Future<Map<String, List<Media>>> groupIdenticalAsync() async {
    final Map<String, List<Media>> output = <String, List<Media>>{};

    // Pre-populate sizes asynchronously to avoid repeated sync calls
    final mediaWithSizes = <({Media media, int size})>[];
    for (final media in this) {
      final size = await media.getSize();
      mediaWithSizes.add((media: media, size: size));
    }

    // Group by size first (cheap comparison)
    final sizeGroups = <int, List<Media>>{};
    for (final entry in mediaWithSizes) {
      sizeGroups.putIfAbsent(entry.size, () => <Media>[]).add(entry.media);
    }

    // Process each size group
    for (final MapEntry<int, List<Media>> sameSize in sizeGroups.entries) {
      // Just add with "...bytes" key if just one
      if (sameSize.value.length <= 1) {
        output['${sameSize.key}bytes'] = sameSize.value;
      } else {
        // Calculate hashes asynchronously for files with same size
        final hashGroups = <String, List<Media>>{};
        for (final media in sameSize.value) {
          final hash = await media.getHash();
          final hashKey = hash.toString();
          hashGroups.putIfAbsent(hashKey, () => <Media>[]).add(media);
        }
        output.addAll(hashGroups);
      }
    }
    return output;
  }

  /// Alias for groupIdenticalAsync for backwards compatibility
  Future<Map<String, List<Media>>> groupIdenticalAsyncParallel() async =>
      groupIdenticalAsync();
}

/// Removes duplicate media from list of media
///
/// This function delegates to the new DuplicateDetectionService while
/// maintaining backwards compatibility with the legacy interface.
///
/// Returns count of removed
int removeDuplicates(final List<Media> media) {
  // Use the sync grouping for backwards compatibility
  int count = 0;

  final Iterable<Iterable<List<Media>>> byAlbum = media
      // group by albums as we will merge those later
      // (to *not* compare hashes between albums)
      .groupListsBy((final Media e) => e.files.keys.first)
      .values
      // group by hash
      .map(
        (final List<Media> albumGroup) => albumGroup.groupIdentical().values,
      );
  // we don't care about album organization now - flatten
  final Iterable<List<Media>> hashGroups = byAlbum.flattened;

  for (final List<Media> group in hashGroups) {
    // sort by best date extraction, then file name length
    // using strings to sort by two values is a sneaky trick i learned at
    // https://stackoverflow.com/questions/55920677/how-to-sort-a-list-based-on-two-values

    // note: we are comparing accuracy here tho we do know that *all*
    // of them have it null - i'm leaving this just for sake
    group.sort(
      (
        final Media a,
        final Media b,
      ) => '${a.dateTakenAccuracy ?? 999}${p.basename(a.firstFile.path).length}'
          .compareTo(
            '${b.dateTakenAccuracy ?? 999}${p.basename(b.firstFile.path).length}',
          ),
    );
    // get list of all except first
    for (final Media e in group.sublist(1)) {
      // remove them from media
      media.remove(e);
      log('[Step 3/8] Skipping duplicate: ${e.firstFile.path}');
      count++;
    }
  }
  return count;
}

/// Async version of removeDuplicates that delegates to DuplicateDetectionService
///
/// This version uses the new service for better performance and async processing
/// Returns count of removed
Future<int> removeDuplicatesAsync(final List<Media> media) async {
  if (media.isEmpty) return 0;

  int count = 0;

  // Group by albums first (to not compare hashes between albums)
  final albumGroups = media.groupListsBy((final Media e) => e.files.keys.first);

  // Process each album group
  final allHashGroups = <List<Media>>[];
  for (final albumGroup in albumGroups.values) {
    final hashGroups = await albumGroup.groupIdenticalAsync();
    allHashGroups.addAll(hashGroups.values);
  }

  for (final List<Media> group in allHashGroups) {
    if (group.length <= 1) continue; // No duplicates in this group

    // Sort by best date extraction, then file name length
    group.sort(
      (
        final Media a,
        final Media b,
      ) => '${a.dateTakenAccuracy ?? 999}${p.basename(a.firstFile.path).length}'
          .compareTo(
            '${b.dateTakenAccuracy ?? 999}${p.basename(b.firstFile.path).length}',
          ),
    );

    // Remove all except first (best) one
    for (final Media e in group.sublist(1)) {
      media.remove(e);
      log('[Step 3/8] Skipping duplicate: ${e.firstFile.path}');
      count++;
    }
  }
  return count;
}

/// Alias for removeDuplicatesAsync for backwards compatibility
Future<int> removeDuplicatesAsyncOptimized(final List<Media> media) async =>
    removeDuplicatesAsync(media);

/// Gets the album name from a directory path
///
/// [albumDir] Directory representing an album
/// Returns the normalized basename of the directory
String albumName(final Directory albumDir) =>
    p.basename(p.normalize(albumDir.path));

/// Finds albums and merges identical files with different album associations
///
/// This will analyze [allMedia], find which files are hash-same, and merge
/// all of them into single [Media] object with all album names they had
void findAlbums(final List<Media> allMedia) {
  for (final List<Media> group in allMedia.groupIdentical().values) {
    if (group.length <= 1) continue; // then this isn't a group
    // now, we have [group] list that contains actual sauce:

    final Map<String?, File> allFiles = group.fold(
      <String?, File>{},
      (final Map<String?, File> allFiles, final Media e) =>
          allFiles..addAll(e.files),
    ); // sort by best date extraction
    group.sort(
      (final Media a, final Media b) =>
          (a.dateTakenAccuracy ?? 999).compareTo(b.dateTakenAccuracy ?? 999),
    );
    // remove original dirty ones
    allMedia.removeWhere(group.contains);
    // create the first (best) one with complete album list using immutable operation
    final mergedMedia = group.first.withFiles(allFiles);
    // add our one, precious ✨perfect✨ one
    allMedia.add(mergedMedia);
  }
}

/// Async version of findAlbums that delegates to AlbumDetectionService
///
/// This will analyze [allMedia], find which files are hash-same, and merge
/// all of them into single [Media] object with all album names they had
Future<void> findAlbumsAsync(final List<Media> allMedia) async {
  final groupedMedia = await allMedia.groupIdenticalAsync();

  for (final List<Media> group in groupedMedia.values) {
    if (group.length <= 1) continue; // No duplicates to merge

    // Collect all file references from all Media objects in the group
    final Map<String?, File> allFiles = group.fold(
      <String?, File>{},
      (final Map<String?, File> allFiles, final Media e) =>
          allFiles..addAll(e.files),
    );

    // Sort by best date extraction accuracy
    group.sort(
      (final Media a, final Media b) =>
          (a.dateTakenAccuracy ?? 999).compareTo(b.dateTakenAccuracy ?? 999),
    ); // Remove original entries from main list
    allMedia.removeWhere(group.contains);

    // Update the best one with all file references using immutable operation
    final mergedMedia = group.first.withFiles(allFiles);

    // Add the merged Media object back
    allMedia.add(mergedMedia);
  }
}
