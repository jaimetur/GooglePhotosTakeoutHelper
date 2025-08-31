/// Test suite for AlbumDetectionService
///
/// Tests the album detection functionality for Google Photos Takeout processing.
library;

import 'dart:io';
import 'package:gpth/gpth-lib.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('AlbumDetectionService', () {
    late AlbumRelationshipService service;
    late TestFixture fixture;

    setUp(() async {
      await ServiceContainer.reset();
      await ServiceContainer.instance.initialize();
      service = ServiceContainer.instance.albumRelationshipService;
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    group('Album Detection and Merging', () {
      test('detects and merges duplicate files from albums', () async {
        // Mismo contenido en año y en un álbum → deben fusionarse
        final yearPhoto = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3, 4, 5]);
        final albumPhoto = fixture.createFile('Albums/Vacation/IMG_001.jpg', [1, 2, 3, 4, 5]);

        final entities = [
          MediaEntity.single(file: yearPhoto, dateTaken: DateTime(2023)),
          MediaEntity.single(file: albumPhoto, dateTaken: DateTime(2023)),
        ];

        final merged = await service.detectAndMergeAlbums(entities);

        expect(merged.length, equals(1));
        expect(merged.first.hasAlbumAssociations, isTrue);
        expect(merged.first.albumNames, containsAll(['Vacation']));
        expect(merged.first.albumNames.length, equals(1));
      });

      test('keeps separate files when content is different', () async {
        final photo1 = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3]);
        final photo2 = fixture.createFile('2023/IMG_002.jpg', [4, 5, 6]);

        final entities = [
          MediaEntity.single(file: photo1, dateTaken: DateTime(2023)),
          MediaEntity.single(file: photo2, dateTaken: DateTime(2023, 1, 2)),
        ];

        final merged = await service.detectAndMergeAlbums(entities);

        expect(merged.length, equals(2));
      });

      test('handles empty list gracefully', () async {
        final merged = await service.detectAndMergeAlbums([]);

        expect(merged, isEmpty);
      });

      test('handles single file without merging', () async {
        final photo = fixture.createFile('IMG_001.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(file: photo, dateTaken: DateTime(2023));

        final merged = await service.detectAndMergeAlbums([entity]);

        expect(merged.length, equals(1));
        expect(merged.first, equals(entity));
      });

      test('merges multiple duplicates correctly', () async {
        final content = [1, 2, 3, 4, 5, 6, 7, 8];
        final yearPhoto = fixture.createFile('2023/IMG_001.jpg', content);
        final album1Photo = fixture.createFile('Albums/Vacation/IMG_001.jpg', content);
        final album2Photo = fixture.createFile('Albums/Summer/IMG_001.jpg', content);

        final entities = [
          MediaEntity.single(file: yearPhoto, dateTaken: DateTime(2023)),
          MediaEntity.single(file: album1Photo, dateTaken: DateTime(2023)),
          MediaEntity.single(file: album2Photo, dateTaken: DateTime(2023)),
        ];

        final merged = await service.detectAndMergeAlbums(entities);

        expect(merged.length, equals(1));
        expect(merged.first.hasAlbumAssociations, isTrue);
        expect(merged.first.albumNames, containsAll(['Vacation', 'Summer']));
        expect(merged.first.albumNames.length, equals(2));
      });
    });

    group('Album Media Detection', () {
      test('finds media with album associations', () {
        final yearPhoto = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3]);
        final albumPhoto = fixture.createFile('Albums/Vacation/IMG_002.jpg', [4, 5, 6]);

        final entities = [
          MediaEntity.single(file: yearPhoto, dateTaken: DateTime(2023)),
          MediaEntity.single(file: albumPhoto, dateTaken: DateTime(2023, 1, 2)),
        ];

        final albumMedia = service.findAlbumMedia(entities);

        expect(albumMedia.length, equals(1));
        expect(albumMedia.first.hasAlbumAssociations, isTrue);
        expect(albumMedia.first.albumNames, contains('Vacation'));
      });

      test('finds media without album associations (year-only)', () {
        final yearPhoto1 = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3]);
        final yearPhoto2 = fixture.createFile('2023/IMG_002.jpg', [4, 5, 6]);

        final entities = [
          MediaEntity.single(file: yearPhoto1, dateTaken: DateTime(2023)),
          MediaEntity.single(file: yearPhoto2, dateTaken: DateTime(2023, 1, 2)),
        ];

        final yearOnlyMedia = service.findYearOnlyMedia(entities);

        expect(yearOnlyMedia.length, equals(2));
      });

      test('handles mixed media types correctly', () {
        final yearPhoto = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3]);
        final albumPhoto = fixture.createFile('Albums/Vacation/IMG_002.jpg', [4, 5, 6]);

        final entities = [
          MediaEntity.single(file: yearPhoto, dateTaken: DateTime(2023)),
          MediaEntity.single(file: albumPhoto, dateTaken: DateTime(2023, 1, 2)),
        ];

        final albumMedia = service.findAlbumMedia(entities);
        final yearOnlyMedia = service.findYearOnlyMedia(entities);

        expect(albumMedia.length, equals(1));
        expect(yearOnlyMedia.length, equals(1));
      });
    });

    group('Album Statistics', () {
      test('calculates basic statistics correctly', () async {
        final yearPhoto = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3]);
        final albumPhoto1 = fixture.createFile('Albums/Vacation/IMG_002.jpg', [4, 5, 6]);
        final albumPhoto2 = fixture.createFile('Albums/Family/IMG_003.jpg', [7, 8, 9]);

        final entities = [
          MediaEntity.single(file: yearPhoto, dateTaken: DateTime(2023)),
          MediaEntity.single(file: albumPhoto1, dateTaken: DateTime(2023, 1, 2)),
          MediaEntity.single(file: albumPhoto2, dateTaken: DateTime(2023, 1, 3)),
        ];

        // Para estadísticas básicas no necesitamos merge explícito
        final stats = service.getAlbumStatistics(entities);

        expect(stats.totalFiles, equals(3));
        expect(stats.albumFiles, equals(2));
        expect(stats.yearOnlyFiles, equals(1));
        expect(stats.uniqueAlbums, equals(2));
        expect(stats.albumNames, contains('Vacation'));
        expect(stats.albumNames, contains('Family'));
      });

      test('handles files with multiple album associations', () async {
        // Dos copias del MISMO contenido en dos álbumes distintos → tras merge, 1 entidad con 2 álbumes
        final content = [1, 2, 3];
        final a1 = fixture.createFile('Albums/Vacation/IMG_001.jpg', content);
        final a2 = fixture.createFile('Albums/Summer/IMG_001.jpg', content);

        final merged = await service.detectAndMergeAlbums([
          MediaEntity.single(file: a1, dateTaken: DateTime(2023)),
          MediaEntity.single(file: a2, dateTaken: DateTime(2023)),
        ]);

        final stats = service.getAlbumStatistics(merged);

        expect(stats.totalFiles, equals(1));
        expect(stats.albumFiles, equals(1));
        expect(stats.multiAlbumFiles, equals(1));
        expect(stats.uniqueAlbums, equals(2));
      });

      test('handles empty collection', () {
        final stats = service.getAlbumStatistics([]);

        expect(stats.totalFiles, equals(0));
        expect(stats.albumFiles, equals(0));
        expect(stats.yearOnlyFiles, equals(0));
        expect(stats.uniqueAlbums, equals(0));
        expect(stats.multiAlbumFiles, equals(0));
        expect(stats.albumNames, isEmpty);
      });

      test('provides meaningful string representation', () {
        final yearPhoto = fixture.createFile('2023/IMG_001.jpg', [1, 2, 3]);
        final albumPhoto = fixture.createFile('Albums/Vacation/IMG_002.jpg', [4, 5, 6]);

        final entities = [
          MediaEntity.single(file: yearPhoto, dateTaken: DateTime(2023)),
          MediaEntity.single(file: albumPhoto, dateTaken: DateTime(2023, 1, 2)),
        ];

        final stats = service.getAlbumStatistics(entities);
        final statsString = stats.toString();

        expect(statsString, contains('total: 2'));
        expect(statsString, contains('in albums: 1'));
        expect(statsString, contains('year-only: 1'));
        expect(statsString, contains('albums: 1'));
      });
    });

    group('Error Handling', () {
      test('handles corrupt files gracefully during merging', () async {
        final corruptFile = fixture.createFile('corrupt.jpg', []);
        final entity = MediaEntity.single(file: corruptFile, dateTaken: DateTime(2023));

        final merged = await service.detectAndMergeAlbums([entity]);

        expect(merged.length, equals(1));
      });

      test('handles non-existent files gracefully', () {
        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');
        final entity = MediaEntity.single(file: nonExistentFile, dateTaken: DateTime(2023));

        final stats = service.getAlbumStatistics([entity]);
        expect(stats.totalFiles, equals(1));
      });
    });
  });
}
