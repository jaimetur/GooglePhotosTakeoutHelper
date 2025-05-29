// ignore_for_file: avoid_redundant_argument_values

import 'dart:io';
import 'package:gpth/extras.dart';
import 'package:gpth/grouping.dart';
import 'package:gpth/media.dart';
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('Media and Grouping', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Media Class', () {
      test('creates Media object with required properties', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final media = Media({null: file});

        expect(media.firstFile, file);
        expect(media.files, {null: file});
        expect(media.dateTaken, isNull);
        expect(media.dateTakenAccuracy, isNull);
      });

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

      test('hash property works correctly for small files', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [1, 2, 3]);
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final media1 = Media({null: file1});
        final media2 = Media({null: file2});
        final media3 = Media({null: file3});

        expect(media1.hash, media2.hash);
        expect(media1.hash, isNot(media3.hash));
      });

      test('toString provides useful representation', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final date = DateTime(2023, 1);
        final media = Media(
          {null: file},
          dateTaken: date,
          dateTakenAccuracy: 1,
        );

        final str = media.toString();
        expect(str, contains('Media'));
        expect(str, contains('test.jpg'));
        expect(str, contains('2023-01-01'));
      });
    });

    group('Duplicate Detection', () {
      test('removes exact duplicates', () {
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

        final mediaList = [
          Media(
            {null: file1},
            dateTaken: DateTime(2023, 1),
            dateTakenAccuracy: 1,
          ),
          Media(
            {null: file2},
            dateTaken: DateTime(2023, 1, 2),
            dateTakenAccuracy: 2,
          ),
          Media(
            {null: file3},
            dateTaken: DateTime(2023, 1, 3),
            dateTakenAccuracy: 1,
          ),
        ];

        final removedCount = removeDuplicates(mediaList);

        expect(removedCount, 1);
        expect(mediaList.length, 2);
        // Should keep the one with better accuracy (lower number)
        expect(
          mediaList.any((final m) => m.firstFile.path == file1.path),
          isTrue,
        );
        expect(
          mediaList.any((final m) => m.firstFile.path == file3.path),
          isTrue,
        );
      });

      test('groupIdentical groups files by size and hash', () {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [
          1,
          2,
          3,
        ]); // Same content
        final file3 = fixture.createFile('test3.jpg', [
          4,
          5,
        ]); // Different content and size

        final mediaList = [
          Media({null: file1}),
          Media({null: file2}),
          Media({null: file3}),
        ];

        final groups = mediaList.groupIdentical();

        expect(
          groups.length,
          2,
        ); // One group for duplicates, one for unique file
        expect(
          groups.values.any((final group) => group.length == 2),
          isTrue,
        ); // Duplicate group
        expect(
          groups.values.any((final group) => group.length == 1),
          isTrue,
        ); // Unique file group
      });
    });

    group('Album Detection', () {
      test('findAlbums merges album files with main files', () {
        final albumDir = fixture.createDirectory('Vacation');
        final mainFile = fixture.createFile('photo.jpg', [1, 2, 3]);
        final albumFile = File('${albumDir.path}/photo.jpg');
        albumFile.createSync();
        albumFile.writeAsBytesSync([1, 2, 3]); // Same content

        final mediaList = [
          Media(
            {null: mainFile},
            dateTaken: DateTime(2023, 1),
            dateTakenAccuracy: 1,
          ),
          Media(
            {'Vacation': albumFile},
            dateTaken: DateTime(2023, 1, 2),
            dateTakenAccuracy: 2,
          ),
        ];

        findAlbums(mediaList);

        expect(mediaList.length, 1); // Should merge into one
        expect(mediaList.first.files.length, 2); // Should have both files
        expect(mediaList.first.files.keys, contains(null));
        expect(mediaList.first.files.keys, contains('Vacation'));
        expect(
          mediaList.first.dateTaken,
          DateTime(2023, 1),
        ); // Keep better accuracy
      });
    });

    group('Extras Detection', () {
      test('removeExtras removes edited versions', () {
        final originalFile = fixture.createFile('photo.jpg', [1, 2, 3]);
        final editedFile = fixture.createFile('photo-edited.jpg', [4, 5, 6]);

        final mediaList = [
          Media({null: originalFile}),
          Media({null: editedFile}),
        ];

        final removedCount = removeExtras(mediaList);

        expect(removedCount, 1);
        expect(mediaList.length, 1);
        expect(mediaList.first.firstFile.path, originalFile.path);
      });

      test('isExtra correctly identifies edited files', () {
        expect(isExtra('photo-edited.jpg'), isTrue);
        expect(isExtra('photo-bearbeitet.jpg'), isTrue);
        expect(isExtra('photo-modifié.jpg'), isTrue);
        expect(isExtra('photo.jpg'), isFalse);
        expect(isExtra('photo-original.jpg'), isFalse);
      });
    });
  });
}
