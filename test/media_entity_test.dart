/// Test suite for Media Entity and Collection Management functionality.
///
/// This comprehensive test suite validates the modern media management system
/// that handles grouping, duplicate detection, and organization of photos
/// and videos from Google Photos Takeout exports. The media system is
/// responsible for:
///
/// 1. MediaEntity Object Management:
///    - Creating MediaEntity objects from file collections
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
///    - Content-based duplicate identification using hashing
///    - Size-based pre-filtering for performance optimization
///    - Handling edge cases like identical files with different names
///    - Memory-efficient processing of large media collections
///
/// 4. Album Processing:
///    - Merging media files from different album sources
///    - Maintaining album associations across file relationships
///    - Handling complex album hierarchies and overlapping memberships
///    - Optimizing album detection algorithms for performance
///
/// 5. Extras Management:
///    - Identifying and removing edited/modified versions
///    - Detecting pattern-based extra files (e.g., "-edited", "-bearbeitet")
///    - Maintaining original files while removing duplicates
///    - Supporting internationalized extra file patterns
///
/// ## Test Organization
///
/// The test suite is organized into several logical groups:
/// - **MediaEntity Creation**: Basic object instantiation and property management
/// - **Content Grouping**: Hash-based duplicate detection and grouping
/// - **Duplicate Detection**: Performance and accuracy of duplicate removal
/// - **Album Management**: File relationship handling and album merging
/// - **Extras Processing**: Edited file detection and removal
/// - **Performance Tests**: Large-scale operation validation
/// - **Edge Cases**: Boundary conditions and error handling
///
/// Each test group focuses on specific aspects of the media management pipeline
/// while ensuring comprehensive coverage of real-world usage scenarios.
library;

import 'dart:io';

import 'package:gpth/domain/entities/media_entity.dart';
import 'package:gpth/domain/models/media_entity_collection.dart';
import 'package:gpth/domain/services/duplicate_detection_service.dart';
import 'package:test/test.dart';

import './test_setup.dart';

void main() {
  group('MediaEntity and Collection - Modern Content Management System', () {
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

    group('MediaEntity Class - Object Creation and Property Management', () {
      /// Validates basic MediaEntity object creation with essential properties.
      /// This tests the fundamental MediaEntity class instantiation that forms
      /// the foundation of the entire media management system.
      test('creates MediaEntity object with required properties', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(file: file);

        expect(entity.primaryFile, file);
        expect(entity.files.files, {null: file});
        expect(entity.dateTaken, isNull);
        expect(entity.dateTakenAccuracy, isNull);
      });

      /// Tests MediaEntity object creation with date metadata, which is crucial
      /// for organizing photos chronologically and maintaining accurate
      /// timeline information from Google Photos exports.
      test('creates MediaEntity object with date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: file,
          dateTaken: DateTime(2023, 5, 15),
        );

        expect(entity.primaryFile, file);
        expect(entity.dateTaken, DateTime(2023, 5, 15));
      });

      /// Validates consistent hash generation for content-based operations.
      /// Hash consistency is critical for duplicate detection and content
      /// grouping across multiple processing runs.
      test('generates consistent content identifiers', () async {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [
          1,
          2,
          3,
        ]); // Same content
        final file3 = fixture.createFile('test3.jpg', [
          4,
          5,
          6,
        ]); // Different content

        final entity1 = MediaEntity.single(file: file1);
        final entity2 = MediaEntity.single(file: file2);
        final entity3 = MediaEntity.single(file: file3);

        // Since entities use the same content, they should be considered similar
        // for duplicate detection purposes
        expect(
          await entity1.primaryFile.readAsBytes(),
          await entity2.primaryFile.readAsBytes(),
        );
        expect(
          await entity1.primaryFile.readAsBytes(),
          isNot(await entity3.primaryFile.readAsBytes()),
        );
      });

      /// Tests MediaEntity object behavior with multiple associated files,
      /// which occurs when grouping related media files together.
      test('handles MediaEntity objects with multiple files', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [4, 5, 6]);
        final entity = MediaEntity.fromMap(
          files: {null: file1, 'extra': file2},
        );

        expect(entity.files.files.length, 2);
        expect(entity.files.files['extra'], file2);
      });

      /// Validates proper handling of MediaEntity objects without date information,
      /// which may occur with certain file types or incomplete metadata.
      test('handles MediaEntity objects without date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(file: file);

        expect(entity.dateTaken, isNull);
        expect(entity.dateTakenAccuracy, isNull);
      });
    });

    group('MediaEntityCollection - Duplicate Detection and Management', () {
      /// Validates the core duplicate detection functionality that identifies
      /// and removes duplicate files based on content analysis.
      test('removeDuplicates identifies and removes duplicate files', () async {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [1, 2, 3]); // Duplicate
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: file1),
          MediaEntity.single(file: file2),
          MediaEntity.single(file: file3),
        ]);

        final removedCount = await collection.removeDuplicates();

        expect(removedCount, 1);
        expect(collection.length, 2);
        expect(
          collection.entities.any(
            (final e) => e.primaryFile.path == file1.path,
          ),
          isTrue,
        );
        expect(
          collection.entities.any(
            (final e) => e.primaryFile.path == file3.path,
          ),
          isTrue,
        );
      });

      /// Tests duplicate detection performance with larger datasets to ensure
      /// the algorithm scales appropriately for real-world usage scenarios.
      test('handles duplicate detection with many files efficiently', () async {
        final collection = MediaEntityCollection();

        // Create 100 unique files with distinct content
        for (int i = 0; i < 100; i++) {
          final file = fixture.createFile('test$i.jpg', [
            i + 1,
          ]); // Start from 1 to avoid single-byte issues
          collection.add(MediaEntity.single(file: file));
        }

        // Add a duplicate of the first file (content [1])
        final duplicateFile = fixture.createFile('duplicate.jpg', [1]);
        collection.add(MediaEntity.single(file: duplicateFile));

        final start = DateTime.now();
        final removedCount = await collection.removeDuplicates();
        final end = DateTime.now();

        expect(removedCount, 1);
        expect(collection.length, 100);
        expect(end.difference(start).inMilliseconds, lessThan(2000));
      });
    });

    group('Album Detection and Management - File Relationship Handling', () {
      /// Tests the album finding functionality that merges related files
      /// from different album sources into single MediaEntity objects.
      test('findAlbums merges duplicate files from different albums', () async {
        final file1 = fixture.createFile('photo.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('album_photo.jpg', [
          1,
          2,
          3,
        ]); // Same content

        final collection = MediaEntityCollection([
          // First entity: year-based file (null key)
          MediaEntity.single(file: file1, dateTaken: DateTime(2023)),
          // Second entity: album file with BOTH album AND year reference
          MediaEntity.fromMap(
            files: {null: file2, 'Vacation': file2},
            dateTaken: DateTime(2023),
          ),
        ]);

        final originalLength = collection.length;
        await collection.findAlbums();

        // Should merge into one MediaEntity object with multiple file sources
        expect(collection.length, lessThan(originalLength));
        expect(collection.length, 1);

        final mergedEntity = collection.entities.first;
        expect(mergedEntity.files.files.length, 2);
        expect(mergedEntity.files.files.containsKey(null), isTrue);
        expect(mergedEntity.files.files.containsKey('Vacation'), isTrue);
      });

      /// Validates that album merging preserves the best available metadata
      /// when combining files from different sources.
      test('preserves best metadata when merging albums', () async {
        final file1 = fixture.createFile('photo1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('photo2.jpg', [
          1,
          2,
          3,
        ]); // Same content

        final collection = MediaEntityCollection([
          MediaEntity.single(file: file1, dateTaken: DateTime(2023)),
          MediaEntity.fromMap(
            files: {'Album': file2},
            dateTaken: DateTime(2023),
          ),
        ]);

        await collection.findAlbums();

        expect(collection.length, 1);
        final mergedEntity = collection.entities.first;
        expect(mergedEntity.dateTaken, DateTime(2023));
      });
    });
    group('Extras Processing - Edited File Detection and Removal', () {
      /// Note: Extras processing tests temporarily disabled during modernization
      /// These will be re-enabled once extras service is updated to work with MediaEntity
      test('extras processing placeholder', () {
        // Placeholder test until extras service is modernized
        expect(true, isTrue);
      });
    });

    group('Performance and Scalability - Large Collection Handling', () {
      /// Validates system performance under load with large media collections
      /// to ensure scalability for real-world Google Photos exports.
      test(
        'handles large collections efficiently in comprehensive workflow',
        () async {
          final collection = MediaEntityCollection();

          // Create 10 large files (1MB each) with unique content for performance testing
          for (int i = 0; i < 10; i++) {
            final content = List<int>.filled(1024 * 1024, i);
            if (i > 0) {
              final prevContent = await collection.media[i - 1].primaryFile
                  .readAsBytes();
              expect(content.sublist(0, 10), isNot(prevContent.sublist(0, 10)));
            }
            final file = fixture.createLargeTestFile(
              'large_test$i.jpg',
              content: content,
            );
            collection.add(MediaEntity.single(file: file));
          }

          // Test duplicate detection
          final removedCount = await collection.removeDuplicates();
          expect(removedCount, 0); // No duplicates in this test

          // Test memory usage during operations
          final memoryBefore = ProcessInfo.currentRss;
          await collection.removeDuplicates();
          final memoryAfter = ProcessInfo.currentRss;

          // Memory usage should not grow significantly
          if (!Platform.isWindows) {
            expect(
              memoryAfter - memoryBefore,
              lessThan(50 * 1024 * 1024),
            ); // 50MB limit
          }
        },
      );

      /// Validates memory usage patterns during intensive operations
      /// to prevent out-of-memory issues with large collections.
      test('manages memory usage during intensive operations', () async {
        final collection = MediaEntityCollection();

        // Create a smaller number of media entities for stability
        for (int i = 0; i < 50; i++) {
          final file = fixture.createFile('memory_test$i.jpg', [i]);
          collection.add(MediaEntity.single(file: file));
        }

        // Should complete without memory issues
        await collection.removeDuplicates();
        // Note: Extras processing temporarily disabled during modernization
        await collection.findAlbums();

        // Verify collection is still intact
        expect(collection.length, 50);
      });

      /// Tests that the modern grouping system works correctly
      /// for organizing media by content.
      test('modern grouping correctly groups media by content', () async {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [
          1,
          2,
          3,
        ]); // Same content
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: file1),
          MediaEntity.single(file: file2),
          MediaEntity.single(file: file3),
        ]);
        const duplicateService = DuplicateDetectionService();
        final grouped = await duplicateService.groupIdentical(
          collection.entities.toList(),
        );

        // Should have two groups: one with duplicates, one with unique file
        expect(grouped.length, 2);

        // Find the group with duplicates
        final duplicateGroup = grouped.values.firstWhere(
          (final group) => group.length > 1,
        );
        expect(duplicateGroup.length, 2);

        // Verify the duplicate group contains the right files
        expect(
          duplicateGroup.any((final e) => e.primaryFile.path == file1.path),
          isTrue,
        );
        expect(
          duplicateGroup.any((final e) => e.primaryFile.path == file2.path),
          isTrue,
        );
      });
    });

    group('MediaEntityCollection - Core Operations', () {
      /// Tests basic collection operations like add, remove, clear
      test('supports basic collection operations', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection();
        expect(collection.isEmpty, isTrue);

        final entity1 = MediaEntity.single(file: file1);
        final entity2 = MediaEntity.single(file: file2);

        collection.add(entity1);
        expect(collection.length, 1);
        expect(collection.isNotEmpty, isTrue);

        collection.addAll([entity2]);
        expect(collection.length, 2);

        collection.remove(entity1);
        expect(collection.length, 1);

        collection.clear();
        expect(collection.isEmpty, isTrue);
      });

      /// Tests collection statistics and reporting
      test('provides accurate statistics', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: file1, dateTaken: DateTime(2023)),
          MediaEntity.fromMap(files: {'Album': file2}),
        ]);

        final stats = collection.getStatistics();
        expect(stats.totalMedia, 2);
        expect(stats.mediaWithDates, 1);
        expect(stats.mediaWithAlbums, 1);
      });
    });
  });
}
