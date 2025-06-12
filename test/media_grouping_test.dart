/// Test suite for Media Grouping and Management functionality.
///
/// This comprehensive test suite validates the core media management system
/// that handles grouping, duplicate detection, and organization of photos
/// and videos from Google Photos Takeout exports. The media system is
/// responsible for:
///
/// 1. Media Object Management:
///    - Creating Media objects from file collections
///    - Managing file associations and metadata
///    - Handling date information and accuracy tracking
///    - Computing content hashes for duplicate detection
///
/// 2. Media Grouping Logic:
///    - Grouping related files (photos, videos, live photos)
///    - Associating metadata JSON files with media files
///    - Handling different file naming conventions
///    - Managing file relationships and dependencies
///
/// 3. Duplicate Detection:
///    - Identifying identical files using content hashing
///    - Detecting near-duplicates with different metadata
///    - Handling edited versions and variants
///    - Managing duplicate resolution strategies
///
/// 4. Extras Processing:
///    - Identifying and handling "extra" files (edited versions, etc.)
///    - Managing file relationships between originals and variants
///    - Processing different types of media modifications
///
/// Key Components Tested:
/// - Media class instantiation and property management
/// - File grouping algorithms and relationship detection
/// - Hash computation for content comparison
/// - Date extraction and accuracy tracking
/// - Extras identification and processing logic
///
/// Testing Strategy:
/// The tests create realistic file structures that mirror Google Photos
/// Takeout exports, including various file types, naming patterns, and
/// metadata configurations. This ensures the grouping logic works correctly
/// with real-world data.
library;

// Tests for Media class, grouping, duplicate detection, and extras.

// ignore_for_file: avoid_redundant_argument_values

import 'package:crypto/crypto.dart';
import 'package:gpth/extras.dart';
import 'package:gpth/grouping.dart';
import 'package:gpth/media.dart';
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('Media and Grouping - Core Content Management System', () {
    late TestFixture fixture;

    setUp(() async {
      // Initialize a clean test environment for each test
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      // Clean up test artifacts to prevent interference between tests
      await fixture.tearDown();
    });

    group('Media Class - Object Creation and Property Management', () {
      /// Validates basic Media object creation with essential properties.
      /// This tests the fundamental Media class instantiation that forms
      /// the foundation of the entire media management system.
      test('creates Media object with required properties', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final media = Media({null: file});

        expect(media.firstFile, file);
        expect(media.files, {null: file});
        expect(media.dateTaken, isNull);
        expect(media.dateTakenAccuracy, isNull);
      });

      /// Tests Media object creation with date metadata, which is crucial
      /// for organizing photos chronologically and maintaining accurate
      /// timeline information from Google Photos exports.
      test('creates Media object with date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final date = DateTime(2023, 1);
        final media = Media(
          {null: file},
          dateTaken: date,
          dateTakenAccuracy: 1,
        );

        expect(media.dateTaken, date);
        expect(media.dateTakenAccuracy, 1);
      });

      /// Validates hash computation for content-based duplicate detection.
      /// Hash calculation is essential for identifying identical files
      /// regardless of filename or metadata differences.
      test('computes hash property correctly for small files', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [1, 2, 3]);
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final media1 = Media({null: file1});
        final media2 = Media({null: file2});
        final media3 = Media({null: file3});

        expect(media1.hash, media2.hash);
        expect(media1.hash, isNot(media3.hash));
      });

      /// Tests Media object behavior with multiple associated files,
      /// which occurs when grouping related media files together.
      test('handles Media objects with multiple files', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [4, 5, 6]);
        final media = Media({null: file1, 'extra': file2});

        expect(media.files.length, 2);
        expect(media.files['extra'], file2);
      });

      /// Validates proper handling of Media objects without date information,
      /// which may occur with certain file types or incomplete metadata.
      test('handles Media objects without date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final media = Media({null: file});

        expect(media.dateTaken, isNull);
        expect(media.dateTakenAccuracy, isNull);
      });
    });

    group('Duplicate Detection and Removal - Content-Based Identification', () {
      /// Tests identification and removal of duplicate files based on content hashing
      /// rather than filename comparison, ensuring accuracy.
      test('removeDuplicates identifies and removes duplicate files', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [
          1,
          2,
          3,
        ]); // Same content
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final mediaList = [
          Media({null: file1}),
          Media({null: file2}), // Duplicate of file1
          Media({null: file3}),
        ];

        final removedCount = removeDuplicates(mediaList);

        expect(removedCount, 1);
        expect(mediaList.length, 2);
        // Should keep the file with shortest name/path
        expect(
          mediaList.any((final m) => m.firstFile.path == file1.path),
          isTrue,
        );
        expect(
          mediaList.any((final m) => m.firstFile.path == file3.path),
          isTrue,
        );
      });

      /// Validates that files with different content are not treated as duplicates.
      test(
        'preserves files with different content during duplicate removal',
        () {
          final file1 = fixture.createFile('photo1.jpg', [1, 2, 3]);
          final file2 = fixture.createFile('photo2.jpg', [4, 5, 6]);
          final file3 = fixture.createFile('photo3.jpg', [7, 8, 9]);

          final mediaList = [
            Media({null: file1}),
            Media({null: file2}),
            Media({null: file3}),
          ];

          final removedCount = removeDuplicates(mediaList);

          expect(removedCount, 0);
          expect(mediaList.length, 3);
        },
      );

      /// Tests performance of duplicate detection with larger file sets
      /// to ensure scalability for extensive photo collections.
      test('performs duplicate detection efficiently with larger sets', () {
        final mediaList = <Media>[];

        // Create 100 unique files with distinct content
        for (int i = 0; i < 100; i++) {
          final file = fixture.createFile('test$i.jpg', [
            i + 1,
          ]); // Start from 1 to avoid single-byte issues
          mediaList.add(Media({null: file}));
        }

        // Add a duplicate of the first file (content [1])
        final duplicateFile = fixture.createFile('duplicate.jpg', [1]);
        mediaList.add(Media({null: duplicateFile}));

        final start = DateTime.now();
        final removedCount = removeDuplicates(mediaList);
        final end = DateTime.now();

        expect(removedCount, 1);
        expect(mediaList.length, 100);
        expect(end.difference(start).inMilliseconds, lessThan(1000));
      });
    });

    group('Album Detection and Management - File Relationship Handling', () {
      /// Tests the album finding functionality that merges related files
      /// from different album sources into single Media objects.
      test('findAlbums merges duplicate files from different albums', () {
        final file1 = fixture.createFile('photo.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('album_photo.jpg', [
          1,
          2,
          3,
        ]); // Same content

        final mediaList = [
          Media({null: file1}, dateTaken: DateTime(2023), dateTakenAccuracy: 1),
          Media(
            {'Vacation': file2},
            dateTaken: DateTime(2023),
            dateTakenAccuracy: 2,
          ),
        ];

        final originalLength = mediaList.length;
        findAlbums(mediaList);

        // Should merge into one Media object with multiple file sources
        expect(mediaList.length, lessThan(originalLength));
        expect(mediaList.length, 1);

        final mergedMedia = mediaList.first;
        expect(mergedMedia.files.length, 2);
        expect(mergedMedia.files.containsKey(null), isTrue);
        expect(mergedMedia.files.containsKey('Vacation'), isTrue);
      });

      /// Validates that files with different content remain separate during album finding.
      test(
        'preserves separate files with different content during album finding',
        () {
          final file1 = fixture.createFile('photo1.jpg', [1, 2, 3]);
          final file2 = fixture.createFile('photo2.jpg', [4, 5, 6]);

          final mediaList = [
            Media({null: file1}),
            Media({'Album': file2}),
          ];

          findAlbums(mediaList);

          expect(mediaList.length, 2);
          expect(mediaList[0].files.length, 1);
          expect(mediaList[1].files.length, 1);
        },
      );

      /// Tests that album finding chooses the best date accuracy when merging files.
      test('chooses best date accuracy when merging album files', () {
        final file1 = fixture.createFile('photo.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('album_photo.jpg', [1, 2, 3]);

        final mediaList = [
          Media({null: file1}, dateTaken: DateTime(2023), dateTakenAccuracy: 2),
          Media(
            {'Album': file2},
            dateTaken: DateTime(2023),
            dateTakenAccuracy: 1,
          ),
        ];

        findAlbums(mediaList);

        expect(mediaList.length, 1);
        final mergedMedia = mediaList.first;
        expect(
          mergedMedia.dateTakenAccuracy,
          1,
        ); // Should choose better accuracy
      });
    });

    group('Extras Processing - Edited File Detection and Removal', () {
      /// Tests identification and removal of "extra" files such as
      /// edited versions, which need special handling in organization.
      test('removeExtras identifies and removes edited files', () {
        final originalFile = fixture.createFile('photo.jpg', [1, 2, 3]);
        final editedFile = fixture.createFile('photo-edited.jpg', [4, 5, 6]);
        final normalFile = fixture.createFile('document.pdf', [7, 8, 9]);

        final mediaList = [
          Media({null: originalFile}),
          Media({null: editedFile}),
          Media({null: normalFile}),
        ];

        final removedCount = removeExtras(mediaList);

        expect(removedCount, 1);
        expect(mediaList.length, 2);
        expect(
          mediaList.any((final m) => m.firstFile.path == originalFile.path),
          isTrue,
        );
        expect(
          mediaList.any((final m) => m.firstFile.path == normalFile.path),
          isTrue,
        );
        expect(
          mediaList.any((final m) => m.firstFile.path == editedFile.path),
          isFalse,
        );
      });

      /// Validates the isExtra helper function for identifying edited files.
      test(
        'isExtra correctly identifies edited files by filename patterns',
        () {
          expect(isExtra('photo-edited.jpg'), isTrue);
          expect(isExtra('photo-bearbeitet.jpg'), isTrue);
          expect(isExtra('photo-modifié.jpg'), isTrue);
          expect(isExtra('photo.jpg'), isFalse);
          expect(isExtra('regular-file.jpg'), isFalse);
        },
      );

      /// Tests handling of various international "edited" filename patterns.
      test('handles different language edited file patterns', () {
        final files = [
          fixture.createFile('photo-edited.jpg', [1, 2, 3]),
          fixture.createFile('bild-bearbeitet.jpg', [4, 5, 6]),
          fixture.createFile('imagen-ha editado.jpg', [7, 8, 9]),
          fixture.createFile('normal.jpg', [10, 11, 12]),
        ];

        final mediaList = files.map((final f) => Media({null: f})).toList();

        final removedCount = removeExtras(mediaList);

        expect(removedCount, 3); // Three edited files should be removed
        expect(mediaList.length, 1);
        expect(mediaList.first.firstFile.path.contains('normal.jpg'), isTrue);
      });
    });

    group('Performance and Integration - Large Collection Handling', () {
      /// Tests comprehensive media processing performance with larger datasets
      /// to ensure the system scales for extensive photo libraries.
      test(
        'handles large numbers of files efficiently in processing pipeline',
        () {
          final mediaList = <Media>[];

          // Create unique files with distinct content
          for (int i = 0; i < 100; i++) {
            final file = fixture.createFile('photo_$i.jpg', [
              i + 1000,
            ]); // Ensure unique content
            mediaList.add(Media({null: file}));
          }

          // Add some duplicates (same content as first 5 unique files)
          for (int i = 0; i < 5; i++) {
            final duplicateFile = fixture.createFile('duplicate_$i.jpg', [
              i + 1000,
            ]); // Same content as photo_$i
            mediaList.add(Media({null: duplicateFile}));
          }

          // Add some edited files with explicit -edited suffix and unique content
          for (int i = 0; i < 5; i++) {
            final editedFile = fixture.createFile(
              'edited_photo_$i-edited.jpg',
              [i + 2000],
            ); // Unique content
            mediaList.add(Media({null: editedFile}));
          }

          final start = DateTime.now();

          final duplicatesRemoved = removeDuplicates(mediaList);
          final extrasRemoved = removeExtras(mediaList);
          findAlbums(mediaList);

          final end = DateTime.now();

          // Should remove 5 duplicates and 5 edited files
          expect(duplicatesRemoved, 5);
          expect(extrasRemoved, 5);
          expect(mediaList.length, 100); // 100 original files remain
          expect(end.difference(start).inMilliseconds, lessThan(2000));
        },
      );

      /// Validates memory usage patterns during intensive operations
      /// to prevent out-of-memory issues with large collections.
      test('manages memory usage during intensive operations', () {
        final mediaList = <Media>[];

        // Create a substantial number of media objects
        for (int i = 0; i < 1000; i++) {
          final file = fixture.createFile('memory_test$i.jpg', [i]);
          mediaList.add(Media({null: file}));
        }

        // Should complete without memory issues
        expect(() => removeDuplicates(mediaList), returnsNormally);
        expect(() => removeExtras(mediaList), returnsNormally);
        expect(() => findAlbums(mediaList), returnsNormally);
      });

      /// Tests that the groupIdentical extension method works correctly
      /// for organizing media by hash and size.
      test('groupIdentical extension correctly groups media by content', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [
          1,
          2,
          3,
        ]); // Same content
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final mediaList = [
          Media({null: file1}),
          Media({null: file2}),
          Media({null: file3}),
        ];

        final grouped = mediaList.groupIdentical();

        // Should have two groups: one with duplicates, one with unique file
        expect(grouped.length, 2);

        // One group should have 2 items (the duplicates)
        final duplicateGroup = grouped.values.firstWhere(
          (final group) => group.length == 2,
        );
        expect(duplicateGroup.length, 2);

        // One group should have 1 item (the unique file)
        final uniqueGroup = grouped.values.firstWhere(
          (final group) => group.length == 1,
        );
        expect(uniqueGroup.length, 1);
      });
    });

    group('Race Condition Safety - Async Operations', () {
      /// Tests that concurrent access to Media properties doesn't cause race conditions
      test(
        'handles concurrent access to size and hash properties safely',
        () async {
          final file = fixture.createFile(
            'race_test.jpg',
            List.generate(1000, (final i) => i % 256),
          );
          final media = Media({null: file});

          // Start multiple concurrent operations for size
          final sizeFutures = List.generate(10, (_) => media.getSize());
          final sizes = await Future.wait(sizeFutures);

          // All size results should be identical
          expect(sizes.every((final size) => size == sizes.first), isTrue);
          expect(sizes.first, 1000); // Should match the file size

          // Start multiple concurrent operations for hash
          final hashFutures = List.generate(10, (_) => media.getHash());
          final hashes = await Future.wait(hashFutures);

          // All hash results should be identical
          expect(
            hashes.every(
              (final hash) => hash.toString() == hashes.first.toString(),
            ),
            isTrue,
          );

          // Verify caching works - should get same values on subsequent calls
          expect(await media.getSize(), sizes.first);
          expect((await media.getHash()).toString(), hashes.first.toString());
        },
      );

      /// Tests that mixed concurrent operations (size and hash) don't interfere
      test('handles mixed concurrent size and hash operations', () async {
        final file = fixture.createFile(
          'mixed_race_test.jpg',
          List.generate(500, (final i) => i % 256),
        );
        final media = Media({null: file});

        // Mix size and hash operations
        final futures = <Future>[];
        for (int i = 0; i < 20; i++) {
          if (i % 2 == 0) {
            futures.add(media.getSize());
          } else {
            futures.add(media.getHash());
          }
        }

        final results = await Future.wait(futures);

        // Extract sizes and hashes
        final sizes = <int>[];
        final hashes = <String>[];

        for (int i = 0; i < results.length; i++) {
          if (i % 2 == 0) {
            sizes.add(results[i] as int);
          } else {
            hashes.add((results[i] as Digest).toString());
          }
        }

        // All sizes should be identical
        expect(sizes.every((final size) => size == sizes.first), isTrue);
        expect(sizes.first, 500);

        // All hashes should be identical
        expect(hashes.every((final hash) => hash == hashes.first), isTrue);
      });

      /// Tests race condition safety in grouping operations
      test('handles concurrent grouping operations safely', () async {
        final files = List.generate(
          5,
          (final i) =>
              fixture.createFile('concurrent_$i.jpg', [i, i + 1, i + 2]),
        );
        final mediaList = files.map((final f) => Media({null: f})).toList();

        // Start multiple concurrent grouping operations
        final groupingFutures = List.generate(
          5,
          (_) => mediaList.groupIdenticalAsync(),
        );
        final results = await Future.wait(groupingFutures);

        // All results should be equivalent
        expect(
          results.every(
            (final result) => result.length == results.first.length,
          ),
          isTrue,
        );

        // Verify the grouping is consistent
        for (int i = 1; i < results.length; i++) {
          expect(results[i].keys.toSet(), results.first.keys.toSet());
        }
      });

      /// Tests that synchronous and asynchronous hash methods produce identical results
      test('sync and async hash methods produce identical results', () async {
        final file1 = fixture.createFile(
          'hash_comparison1.jpg',
          List.generate(2048, (final i) => i % 256),
        );
        final file2 = fixture.createFile(
          'hash_comparison2.jpg',
          List.generate(2048, (final i) => i % 256),
        );

        final media1 = Media({null: file1});
        final media2 = Media({null: file2});

        // Get hash using synchronous method on first media
        final syncHash = media1.hash;

        // Get hash using asynchronous method on second media (same content)
        final asyncHash = await media2.getHash();

        // Both methods should produce identical results for identical content
        expect(syncHash.toString(), asyncHash.toString());

        // Verify both are properly cached
        expect(media1.hash.toString(), syncHash.toString());
        expect((await media2.getHash()).toString(), asyncHash.toString());

        // Cross-verify: async method on first media should match
        expect((await media1.getHash()).toString(), syncHash.toString());
        // And sync method on second media should match
        expect(media2.hash.toString(), asyncHash.toString());
      });
    });
  });
}
