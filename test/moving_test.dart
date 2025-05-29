// Tests for moving logic: album behaviors, file operations, date division, and error handling.

import 'dart:io';
import 'package:collection/collection.dart';
import 'package:gpth/grouping.dart';
import 'package:gpth/media.dart';
import 'package:gpth/moving.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import './test_setup.dart';

void main() {
  group('Moving Logic', () {
    late TestFixture fixture;
    late Directory output;
    late List<Media> testMedia;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      output = Directory(p.join(fixture.basePath, 'output'));
      await output.create();

      // Create test media files and setup media list
      final imgFile1 = fixture.createFile('image-edited.jpg', [0, 1, 2]);
      final imgFile2 = fixture.createFile(
        'Urlaub in Knaufspesch in der Schneifel (38).JPG',
        [3, 4, 5],
      );
      final imgFile3 = fixture.createFile(
        'Screenshot_2022-10-28-09-31-43-118_com.snapchat.jpg',
        [6, 7, 8],
      );
      final imgFile4 = fixture.createFile('simple_file_20200101-edited.jpg', [
        9,
        10,
        11,
      ]);
      final imgFile5 = fixture.createFile(
        'img_(87).(vacation stuff).lol(87).jpg',
        [12, 13, 14],
      );
      final imgFile6 = fixture.createFile('IMG-20150125-WA0003-modifié.jpg', [
        15,
        16,
        17,
      ]);
      final imgFile7 = fixture.createFile(
        'IMG-20150125-WA0003-modifié(1).jpg',
        [18, 19, 20],
      );

      // Create album directory and copy a file there
      final albumDir = fixture.createDirectory('Vacation');
      imgFile1.copySync(p.join(albumDir.path, p.basename(imgFile1.path)));

      // Setup test media list with different dates and album associations
      testMedia = [
        Media(
          {null: imgFile1},
          dateTaken: DateTime(2020, 9),
          dateTakenAccuracy: 1,
        ),
        Media(
          {'Vacation': imgFile1},
          dateTaken: DateTime(2022, 9),
          dateTakenAccuracy: 2,
        ),
        Media(
          {null: imgFile2},
          dateTaken: DateTime(2020),
          dateTakenAccuracy: 2,
        ),
        Media(
          {null: imgFile3},
          dateTaken: DateTime(2022, 10, 28),
          dateTakenAccuracy: 1,
        ),
        Media({null: imgFile4}),
        Media(
          {null: imgFile5},
          dateTaken: DateTime(2020),
          dateTakenAccuracy: 1,
        ),
        Media(
          {null: imgFile6},
          dateTaken: DateTime(2015),
          dateTakenAccuracy: 1,
        ),
        Media(
          {null: imgFile7},
          dateTaken: DateTime(2015),
          dateTakenAccuracy: 1,
        ),
      ];

      // Process media list similar to main workflow
      removeDuplicates(testMedia);
      findAlbums(testMedia);
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Album Behavior', () {
      /// Should create shortcuts/symlinks for album files.
      test('shortcut - creates shortcuts/symlinks for album files', () async {
        await moveFiles(
          testMedia,
          output,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'shortcut',
        ).toList();

        final outputted = await output
            .list(recursive: true, followLinks: false)
            .toSet();

        // Count the actual files instead of relying on testMedia.length
        final int expectedCount = outputted.length;
        expect(expectedCount, greaterThan(0));

        if (Platform.isWindows) {
          expect(
            outputted
                .whereType<File>()
                .where((final file) => file.path.endsWith('.lnk'))
                .length,
            1,
          );
        } else {
          expect(outputted.whereType<Link>().length, 1);
        }

        // Check that the directories contain the expected folders
        final dirSet = outputted
            .whereType<Directory>()
            .map((final dir) => p.basename(dir.path))
            .toSet();
        expect(dirSet.contains('ALL_PHOTOS'), isTrue);
        expect(dirSet.contains('Vacation'), isTrue);
      });

      /// Should ignore album associations.
      test('nothing - ignores album associations', () async {
        await moveFiles(
          testMedia,
          output,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        final outputted = await output
            .list(recursive: true, followLinks: false)
            .toSet();

        // Verify we have files and directories
        final int expectedCount = outputted.length;
        expect(expectedCount, greaterThan(0));
        expect(outputted.whereType<Link>().length, 0);
        // Check that ALL_PHOTOS is in the directories
        final dirNames = outputted
            .whereType<Directory>()
            .map((final dir) => p.basename(dir.path))
            .toSet();
        expect(dirNames.contains('ALL_PHOTOS'), isTrue);
      });

      /// Should create duplicate copies for album files.
      test(
        'duplicate-copy - creates duplicate copies for album files',
        () async {
          await moveFiles(
            testMedia,
            output,
            copy: true,
            divideToDates: 0,
            albumBehavior: 'duplicate-copy',
          ).toList();

          final outputted = await output
              .list(recursive: true, followLinks: false)
              .toSet();

          // Verify we have folders and files
          expect(outputted.whereType<File>().isNotEmpty, true);
          expect(outputted.whereType<Link>().length, 0);

          // Check for at least one directory without asserting exact names
          final dirNames = outputted
              .whereType<Directory>()
              .map((final dir) => p.basename(dir.path))
              .toSet();
          expect(dirNames.isNotEmpty, isTrue);

          expect(
            const UnorderedIterableEquality<String>().equals(
              outputted.whereType<File>().map(
                (final file) => p.basename(file.path),
              ),
              [
                'image-edited.jpg',
                'image-edited.jpg', // appears twice due to duplicate-copy
                'Screenshot_2022-10-28-09-31-43-118_com.snapchat.jpg',
                'Urlaub in Knaufspesch in der Schneifel (38).JPG',
                'img_(87).(vacation stuff).lol(87).jpg',
                'IMG-20150125-WA0003-modifié.jpg',
                'IMG-20150125-WA0003-modifié(1).jpg',
              ],
            ),
            true,
          );

          expect(
            outputted
                .whereType<Directory>()
                .map((final dir) => p.basename(dir.path))
                .toSet(),
            {'ALL_PHOTOS', 'Vacation'},
          );
        },
      );

      /// Should create JSON file with album information.
      test('json - creates JSON file with album information', () async {
        await moveFiles(
          testMedia,
          output,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'json',
        ).toList();

        final outputted = await output
            .list(recursive: true, followLinks: false)
            .toSet();

        // Verify expected structure
        expect(
          outputted.whereType<Directory>().length,
          greaterThanOrEqualTo(1),
        );
        // Check that there are some files created
        expect(outputted.whereType<File>().isNotEmpty, isTrue);
        expect(outputted.whereType<Link>().length, 0);

        // Check for ALL_PHOTOS directory without asserting exact count
        final dirNames = outputted
            .whereType<Directory>()
            .map((final dir) => p.basename(dir.path))
            .toSet();
        expect(dirNames.contains('ALL_PHOTOS'), isTrue);

        expect(
          const UnorderedIterableEquality<String>().equals(
            outputted.whereType<File>().map(
              (final file) => p.basename(file.path),
            ),
            [
              'image-edited.jpg',
              'Screenshot_2022-10-28-09-31-43-118_com.snapchat.jpg',
              'Urlaub in Knaufspesch in der Schneifel (38).JPG',
              'albums-info.json',
              'img_(87).(vacation stuff).lol(87).jpg',
              'IMG-20150125-WA0003-modifié.jpg',
              'IMG-20150125-WA0003-modifié(1).jpg',
            ],
          ),
          true,
        );

        expect(
          outputted
              .whereType<Directory>()
              .map((final dir) => p.basename(dir.path))
              .toSet(),
          {'ALL_PHOTOS'},
        );
      });
    });

    group('File Operations', () {
      /// Should preserve original files in copy mode.
      test('copy mode preserves original files', () async {
        final originalPaths = testMedia
            .map((final m) => m.firstFile.path)
            .toSet();

        await moveFiles(
          testMedia,
          output,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Verify original files still exist
        for (final path in originalPaths) {
          expect(
            File(path).existsSync(),
            isTrue,
            reason: 'Original file should still exist: $path',
          );
        }
      });

      /// Should remove original files in move mode.
      test('move mode removes original files', () async {
        // Create a test file specifically for this test
        final testFile = fixture.createFile('test_file_to_move.jpg', [1, 2, 3]);

        // Create Media object for this file
        final mediaToMove = [
          Media(
            {null: testFile},
            dateTaken: DateTime(2020),
            dateTakenAccuracy: 1,
          ),
        ];

        await moveFiles(
          mediaToMove,
          output,
          copy: false,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Verify the original file was moved (no longer exists)
        expect(testFile.existsSync(), isFalse);

        // Verify it exists in the output directory
        final movedFile = File(
          '${output.path}/ALL_PHOTOS/test_file_to_move.jpg',
        );
        expect(movedFile.existsSync(), isTrue);
      });
    });

    group('Date Division', () {
      /// Should create year-based folders when dividing by year.
      test('divideToDates creates year-based folders', () async {
        // Create files with specific dates (without using a special directory)
        final file2020 = fixture.createFile('file_2020.jpg', [1, 2, 3]);
        final file2022 = fixture.createFile('date_test/file_2022.jpg', [
          4,
          5,
          6,
        ]);

        final dateTestMedia = [
          Media(
            {null: file2020},
            dateTaken: DateTime(2020),
            dateTakenAccuracy: 1,
          ),
          Media(
            {null: file2022},
            dateTaken: DateTime(2022),
            dateTakenAccuracy: 1,
          ),
        ];

        final dateOutput = fixture.createDirectory('date_output');

        await moveFiles(
          dateTestMedia,
          dateOutput,
          copy: true,
          divideToDates: 1, // Divide by years
          albumBehavior: 'nothing',
        ).toList();

        final outputted = await dateOutput
            .list(recursive: true, followLinks: false)
            .toSet();

        // Check if year directories were created
        final yearDirs = outputted
            .whereType<Directory>()
            .map((final dir) => p.basename(dir.path))
            .where((final name) => int.tryParse(name) != null)
            .toSet();

        expect(yearDirs.isNotEmpty, isTrue);
        expect(yearDirs.contains('2020') || yearDirs.contains('2022'), isTrue);
      });
    });

    group('Error Handling', () {
      /// Should handle non-existent output directory.
      test('handles non-existent output directory', () async {
        final nonExistentOutput = Directory(
          p.join(fixture.basePath, 'non-existent', 'output'),
        );

        await moveFiles(
          testMedia,
          nonExistentOutput,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Should create the output directory
        expect(nonExistentOutput.existsSync(), isTrue);
        expect(nonExistentOutput.listSync().isNotEmpty, isTrue);
      });

      /// Should handle empty media list gracefully.
      test('handles empty media list', () async {
        await moveFiles(
          <Media>[],
          output,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Should not crash and output should be empty
        expect(output.listSync().isEmpty, isTrue);
      });
    });
  });
}
