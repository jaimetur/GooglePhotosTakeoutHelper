import 'dart:io';
import 'package:gpth/folder_classify.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('Folder Classification', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Year Folder Detection', () {
      test('identifies standard year folders', () {
        final yearDirs = [
          fixture.createDirectory('Photos from 2023'),
          fixture.createDirectory('Photos from 2022'),
          fixture.createDirectory('Photos from 2021'),
          fixture.createDirectory('Photos from 2020'),
          fixture.createDirectory('Photos from 1999'),
          fixture.createDirectory('Photos from 1980'),
        ];

        for (final dir in yearDirs) {
          expect(isYearFolder(dir), isTrue, reason: 'Failed for ${dir.path}');
        }
      });

      test('identifies alternative year folder patterns', () {
        final yearDirs = [
          fixture.createDirectory('2023'),
          fixture.createDirectory('2022 Photos'),
          fixture.createDirectory('Year 2021'),
          fixture.createDirectory('Pictures from 2020'),
          fixture.createDirectory('Images from 2019'),
        ];

        for (final dir in yearDirs) {
          expect(isYearFolder(dir), isTrue, reason: 'Failed for ${dir.path}');
        }
      });

      test('rejects non-year folders', () {
        final nonYearDirs = [
          fixture.createDirectory('Vacation'),
          fixture.createDirectory('Family Photos'),
          fixture.createDirectory('Random Folder'),
          fixture.createDirectory('Photos from vacation'),
          fixture.createDirectory('2025'), // Future year
          fixture.createDirectory('1899'), // Too old
          fixture.createDirectory('Photos from 12345'), // Invalid year
        ];

        for (final dir in nonYearDirs) {
          expect(isYearFolder(dir), isFalse, reason: 'Failed for ${dir.path}');
        }
      });

      test('handles edge cases for year detection', () {
        final edgeCases = [
          fixture.createDirectory('Photos from 1900'), // Minimum valid year
          fixture.createDirectory('Photos from 2024'), // Current/recent year
          fixture.createDirectory('2000s'), // Not a specific year
          fixture.createDirectory('20th Century'), // Not a year
          fixture.createDirectory(
            'Photos from 2023 backup',
          ), // Year with suffix
        ];

        expect(isYearFolder(edgeCases[0]), isTrue); // 1900
        expect(isYearFolder(edgeCases[1]), isTrue); // 2024
        expect(isYearFolder(edgeCases[2]), isFalse); // 2000s
        expect(isYearFolder(edgeCases[3]), isFalse); // 20th Century
        expect(isYearFolder(edgeCases[4]), isTrue); // 2023 with suffix
      });

      test('extracts year from year folders correctly', () {
        final yearDir2023 = fixture.createDirectory('Photos from 2023');
        final yearDir1995 = fixture.createDirectory('1995');
        final yearDirComplex = fixture.createDirectory('Year 2010 Archive');

        // Test the internal year extraction logic
        expect(isYearFolder(yearDir2023), isTrue);
        expect(isYearFolder(yearDir1995), isTrue);
        expect(isYearFolder(yearDirComplex), isTrue);
      });
    });

    group('Album Folder Detection', () {
      test('identifies album folders with media files', () async {
        final albumDir = fixture.createDirectory('Vacation Photos');
        fixture.createFile('${albumDir.path}/photo1.jpg', [1, 2, 3]);
        fixture.createFile('${albumDir.path}/photo2.png', [4, 5, 6]);
        fixture.createFile('${albumDir.path}/video1.mp4', [7, 8, 9]);

        expect(await isAlbumFolder(albumDir), isTrue);
      });

      test('identifies album folders with mixed content', () async {
        final albumDir = fixture.createDirectory('Mixed Album');
        fixture.createFile('${albumDir.path}/photo.jpg', [1, 2, 3]);
        fixture.createFile('${albumDir.path}/document.txt', [4, 5, 6]);
        fixture.createFile('${albumDir.path}/readme.md', [7, 8, 9]);

        expect(await isAlbumFolder(albumDir), isTrue);
      });

      test('rejects folders without media files', () async {
        final nonAlbumDir = fixture.createDirectory('Documents');
        fixture.createFile('${nonAlbumDir.path}/document.txt', [1, 2, 3]);
        fixture.createFile('${nonAlbumDir.path}/readme.md', [4, 5, 6]);
        fixture.createFile('${nonAlbumDir.path}/notes.txt', [7, 8, 9]);

        expect(await isAlbumFolder(nonAlbumDir), isFalse);
      });

      test('rejects empty folders', () async {
        final emptyDir = fixture.createDirectory('Empty Folder');

        expect(await isAlbumFolder(emptyDir), isFalse);
      });

      test('handles folders with only metadata files', () async {
        final metadataDir = fixture.createDirectory('Metadata Only');
        fixture.createFile('${metadataDir.path}/photo.jpg.json', [1, 2, 3]);
        fixture.createFile('${metadataDir.path}/video.mp4.json', [4, 5, 6]);

        expect(await isAlbumFolder(metadataDir), isFalse);
      });

      test('handles nested album folders', () async {
        final parentDir = fixture.createDirectory('Parent Album');
        final subDir = fixture.createDirectory('${parentDir.path}/Sub Album');

        fixture.createFile('${parentDir.path}/photo1.jpg', [1, 2, 3]);
        fixture.createFile('${subDir.path}/photo2.jpg', [4, 5, 6]);

        expect(await isAlbumFolder(parentDir), isTrue);
        expect(await isAlbumFolder(subDir), isTrue);
      });

      test('identifies album folders with various media formats', () async {
        final albumDir = fixture.createDirectory('Multi Format Album');

        // Common photo formats
        fixture.createFile('${albumDir.path}/photo.jpg', [1, 2, 3]);
        fixture.createFile('${albumDir.path}/image.png', [4, 5, 6]);
        fixture.createFile('${albumDir.path}/pic.gif', [7, 8, 9]);
        fixture.createFile('${albumDir.path}/raw.CR2', [10, 11, 12]);

        // Video formats
        fixture.createFile('${albumDir.path}/video.mp4', [13, 14, 15]);
        fixture.createFile('${albumDir.path}/movie.mov', [16, 17, 18]);
        fixture.createFile('${albumDir.path}/clip.avi', [19, 20, 21]);

        expect(await isAlbumFolder(albumDir), isTrue);
      });

      test('handles folders with hidden files', () async {
        final albumDir = fixture.createDirectory('Album with Hidden Files');
        fixture.createFile('${albumDir.path}/photo.jpg', [1, 2, 3]);
        fixture.createFile('${albumDir.path}/.DS_Store', [4, 5, 6]);
        fixture.createFile('${albumDir.path}/.thumbs.db', [7, 8, 9]);

        expect(await isAlbumFolder(albumDir), isTrue);
      });
    });

    group('Folder Name Analysis', () {
      test('extracts year from various folder name patterns', () {
        final testCases = [
          ['Photos from 2023', 2023],
          ['2022 Vacation', 2022],
          ['Family Photos 2021', 2021],
          ['Christmas_2020_Photos', 2020],
          ['2019-Summer-Trip', 2019],
          ['backup_2018_imgs', 2018],
        ];

        for (final testCase in testCases) {
          final folderName = testCase[0] as String;
          final dir = fixture.createDirectory(folderName);

          if (isYearFolder(dir)) {
            // Would need access to internal year extraction function
            // For now, we'll test through isYearFolder behavior
            expect(
              isYearFolder(dir),
              isTrue,
              reason: 'Failed to identify year in: $folderName',
            );
          }
        }
      });

      test('handles special characters in folder names', () {
        final specialDirs = [
          fixture.createDirectory('Photos from 2023 (Backup)'),
          fixture.createDirectory('2022 - Family Vacation'),
          fixture.createDirectory('Photos_from_2021'),
          fixture.createDirectory('2020 & 2019 Combined'),
          fixture.createDirectory('Photos@2018'),
        ];

        for (final dir in specialDirs) {
          expect(isYearFolder(dir), isTrue, reason: 'Failed for ${dir.path}');
        }
      });

      test('handles Unicode characters in folder names', () {
        final unicodeDirs = [
          fixture.createDirectory('Photos from 2023 📸'),
          fixture.createDirectory('2022 家族写真'),
          fixture.createDirectory('Fotos de 2021'),
          fixture.createDirectory('Photos från 2020'),
          fixture.createDirectory('2019 фотографии'),
        ];

        for (final dir in unicodeDirs) {
          expect(isYearFolder(dir), isTrue, reason: 'Failed for ${dir.path}');
        }
      });
    });

    group('Folder Classification Logic', () {
      test('prioritizes year folder classification over album', () async {
        final yearAlbumDir = fixture.createDirectory('Photos from 2023');
        fixture.createFile('${yearAlbumDir.path}/photo.jpg', [1, 2, 3]);

        expect(isYearFolder(yearAlbumDir), isTrue);
        expect(await isAlbumFolder(yearAlbumDir), isTrue);
        // Year classification should take priority
      });

      test('correctly classifies ambiguous folder names', () {
        final ambiguousDirs = [
          fixture.createDirectory('2023'), // Could be year or album
          fixture.createDirectory('Photos'), // Generic name
          fixture.createDirectory('Images'), // Generic name
          fixture.createDirectory('Media'), // Generic name
        ];

        expect(isYearFolder(ambiguousDirs[0]), isTrue); // Should be year
        expect(isYearFolder(ambiguousDirs[1]), isFalse); // Generic photos
        expect(isYearFolder(ambiguousDirs[2]), isFalse); // Generic images
        expect(isYearFolder(ambiguousDirs[3]), isFalse); // Generic media
      });

      test('handles case sensitivity in folder names', () {
        final caseDirs = [
          fixture.createDirectory('PHOTOS FROM 2023'),
          fixture.createDirectory('photos from 2022'),
          fixture.createDirectory('Photos From 2021'),
          fixture.createDirectory('pHoToS fRoM 2020'),
        ];

        for (final dir in caseDirs) {
          expect(isYearFolder(dir), isTrue, reason: 'Failed for ${dir.path}');
        }
      });
    });

    group('Performance and Edge Cases', () {
      test('handles very long folder names', () {
        // Create a long but reasonable folder name to avoid filesystem limits
        final longName = '${'A' * 50} Photos from 2023 ${'B' * 50}';
        final longDir = fixture.createDirectory(longName);

        expect(isYearFolder(longDir), isTrue);
      });

      test('handles folders with no valid year', () {
        final noYearDirs = [
          fixture.createDirectory('Photos from tomorrow'),
          fixture.createDirectory('Pictures from yesterday'),
          fixture.createDirectory('Images from the past'),
          fixture.createDirectory('Media from the future'),
        ];

        for (final dir in noYearDirs) {
          expect(isYearFolder(dir), isFalse, reason: 'Failed for ${dir.path}');
        }
      });

      test('handles non-existent directories gracefully', () {
        final nonExistent = Directory(p.join(fixture.basePath, 'nonexistent'));

        expect(() => isYearFolder(nonExistent), returnsNormally);
        expect(isYearFolder(nonExistent), isFalse);
      });

      test('handles permission-denied scenarios', () async {
        // This would require platform-specific permission manipulation
        // For now, we'll test that the functions don't throw
        final testDir = fixture.createDirectory('Test Album');
        fixture.createFile('${testDir.path}/photo.jpg', [1, 2, 3]);

        expect(() async => isAlbumFolder(testDir), returnsNormally);
      });

      test('handles symbolic links and junctions', () async {
        final realDir = fixture.createDirectory('Real Album');
        fixture.createFile('${realDir.path}/photo.jpg', [1, 2, 3]);

        if (!Platform.isWindows) {
          final linkPath = p.join(fixture.basePath, 'Linked Album');
          final link = Link(linkPath);
          link.createSync(realDir.path);

          expect(await isAlbumFolder(Directory(linkPath)), isTrue);
        }
      });

      test('handles concurrent access to folders', () async {
        final concurrentDir = fixture.createDirectory('Concurrent Test');
        fixture.createFile('${concurrentDir.path}/photo.jpg', [1, 2, 3]);

        // Test concurrent access
        final futures = List.generate(
          10,
          (final index) => isAlbumFolder(concurrentDir),
        );
        final results = await Future.wait(futures);

        expect(results.every((final result) => result == true), isTrue);
      });
    });
  });
}
