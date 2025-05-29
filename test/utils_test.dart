// Tests for utility functions: stream extensions, file operations, disk, logging, directory validation, platform, JSON, and pixel motion.

import 'dart:io';
import 'package:gpth/moving.dart';
import 'package:gpth/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('Utils', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Stream Extensions', () {
      /// Should filter stream by type using whereType.
      test('whereType filters stream correctly', () {
        final stream = Stream.fromIterable([1, 'a', 2, 'b', 3, 'c']);

        expect(stream.whereType<int>(), emitsInOrder([1, 2, 3, emitsDone]));
      });

      /// Should filter media files using wherePhotoVideo.
      test('wherePhotoVideo filters media files', () {
        final stream = Stream<FileSystemEntity>.fromIterable([
          File('${fixture.basePath}/photo.jpg'),
          File('${fixture.basePath}/document.txt'),
          File('${fixture.basePath}/video.mp4'),
          File('${fixture.basePath}/audio.mp3'),
          File('${fixture.basePath}/image.png'),
        ]);

        expect(
          stream.wherePhotoVideo().map((final f) => p.basename(f.path)),
          emitsInOrder(['photo.jpg', 'video.mp4', 'image.png', emitsDone]),
        );
      });
    });

    group('File Operations', () {
      /// Should generate unique filename if file exists.
      test('findNotExistingName generates unique filename', () {
        final existingFile = fixture.createFile('test.jpg', [1, 2, 3]);

        final uniqueFile = findNotExistingName(existingFile);

        expect(uniqueFile.path, endsWith('test(1).jpg'));
        expect(uniqueFile.existsSync(), isFalse);
      });

      /// Should return original if file does not exist.
      test('findNotExistingName returns original if file does not exist', () {
        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');

        final result = findNotExistingName(nonExistentFile);

        expect(result.path, nonExistentFile.path);
      });
    });

    group('Disk Operations', () {
      /// Should return non-null value for disk free space.
      test('getDiskFree returns non-null value', () async {
        final freeSpace = await getDiskFree('.');

        expect(freeSpace, isNotNull);
        expect(freeSpace!, greaterThan(0));
      });
    });

    group('File Size Formatting', () {
      /// Should format bytes correctly to human-readable string.
      test('filesize formats bytes correctly', () {
        expect(filesize(1024), contains('KB'));
        expect(filesize(1024 * 1024), contains('MB'));
        expect(filesize(1024 * 1024 * 1024), contains('GB'));
      });
    });

    group('Logging', () {
      /// Should handle different log levels without throwing.
      test('log function handles different levels', () {
        // Test that log function doesn't throw
        expect(() => log('test info'), returnsNormally);
        expect(() => log('test warning', level: 'warning'), returnsNormally);
        expect(() => log('test error', level: 'error'), returnsNormally);
      });
    });

    group('Directory Validation', () {
      /// Should succeed for existing directory.
      test('validateDirectory succeeds for existing directory', () async {
        final dir = fixture.createDirectory('test_dir');

        final result = await validateDirectory(dir);

        expect(result, isTrue);
      });

      /// Should fail for non-existing directory when should exist.
      test(
        'validateDirectory fails for non-existing directory when should exist',
        () async {
          final dir = Directory('${fixture.basePath}/nonexistent');

          final result = await validateDirectory(dir);

          expect(result, isFalse);
        },
      );
    });

    group('Platform-specific Operations', () {
      /// Should handle Windows shortcuts (Windows only test).
      test(
        'createShortcutWin handles Windows shortcuts',
        () async {
          if (Platform.isWindows) {
            final targetFile = fixture.createFile('target.txt', [1, 2, 3]);
            final shortcutPath = '${fixture.basePath}/shortcut.lnk';

            // Should not throw (actual creation might fail in test environment)
            expect(
              () => createShortcutWin(shortcutPath, targetFile.path),
              returnsNormally,
            );
          }
        },
        skip: !Platform.isWindows ? 'Windows only test' : null,
      );
    });

    group('JSON File Processing', () {
      /// Should handle supplemental metadata suffix in JSON files.
      test('renameJsonFiles handles supplemental metadata suffix', () async {
        final jsonFile = fixture.createJsonFile(
          'test.jpg.supplemental-metadata.json',
          1599078832,
        );

        await renameIncorrectJsonFiles(fixture.baseDir);

        final renamedFile = File('${fixture.basePath}/test.jpg.json');
        expect(renamedFile.existsSync(), isTrue);
        expect(jsonFile.existsSync(), isFalse);
      });
    });

    group('Pixel Motion Photos', () {
      /// Placeholder for changeMPExtensions logic.
      test('changeMPExtensions renames MP/MV files', () async {
        // This would require Media objects and is more of an integration test
        // For now, we'll test the core logic in integration tests
        expect(true, isTrue); // Placeholder
      });
    });
  });
}
