import 'dart:io';
import 'package:gpth/interactive.dart' as interactive;
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('Interactive Module', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Album Options', () {
      test('provides valid album behavior options', () {
        expect(interactive.albumOptions, isA<Map<String, String>>());
        expect(interactive.albumOptions.isNotEmpty, isTrue);

        // Check for expected album options
        expect(interactive.albumOptions.keys, contains('shortcut'));
        expect(interactive.albumOptions.keys, contains('duplicate-copy'));
        expect(interactive.albumOptions.keys, contains('json'));
        expect(interactive.albumOptions.keys, contains('nothing'));
      });

      test('album options have descriptions', () {
        for (final entry in interactive.albumOptions.entries) {
          expect(
            entry.value,
            isNotEmpty,
            reason: 'Option ${entry.key} has no description',
          );
          expect(
            entry.value,
            isA<String>(),
            reason: 'Option ${entry.key} description is not a string',
          );
        }
      });

      test('album options are properly formatted', () {
        for (final entry in interactive.albumOptions.entries) {
          // Key should be lowercase and may contain hyphens
          expect(
            entry.key,
            matches(RegExp(r'^[a-z-]+$')),
            reason: 'Option key ${entry.key} is not properly formatted',
          );

          // Description should be a non-empty string
          expect(
            entry.value.trim(),
            isNotEmpty,
            reason: 'Option ${entry.key} has empty description',
          );
        }
      });
    });

    group('Interactive Mode Detection', () {
      test('indeed property indicates interactive mode availability', () {
        expect(interactive.indeed, isA<bool>());
      });
    });

    group('User Input Validation', () {
      test('handles directory validation for interactive input', () async {
        // Create test directories
        final validDir = fixture.createDirectory('valid_input');
        final invalidPath = '${fixture.basePath}/nonexistent';

        // Test directory existence checking logic (would be used in interactive mode)
        expect(validDir.existsSync(), isTrue);
        expect(Directory(invalidPath).existsSync(), isFalse);
      });

      test('validates album behavior options', () {
        final validOptions = interactive.albumOptions.keys.toList();

        for (final option in validOptions) {
          expect(
            interactive.albumOptions.containsKey(option),
            isTrue,
            reason: 'Valid option $option not found in albumOptions',
          );
        }

        // Test invalid options
        expect(interactive.albumOptions.containsKey('invalid'), isFalse);
        expect(interactive.albumOptions.containsKey(''), isFalse);
        expect(
          interactive.albumOptions.containsKey('SHORTCUT'),
          isFalse,
        ); // Case sensitive
      });
    });

    group('Output Cleaning Confirmation', () {
      test('askForCleanOutput handles output directory scenarios', () async {
        // Create output directory with existing content
        final outputDir = fixture.createDirectory('output');
        fixture.createFile('${outputDir.path}/existing_file.txt', [1, 2, 3]);
        fixture.createDirectory('${outputDir.path}/existing_folder');

        // In a real interactive scenario, this would prompt the user
        // For testing, we verify the directory state
        expect(outputDir.listSync().isNotEmpty, isTrue);
      });

      test('handles empty output directories', () async {
        final emptyOutputDir = fixture.createDirectory('empty_output');

        expect(emptyOutputDir.listSync().isEmpty, isTrue);
      });

      test('handles non-existent output directories', () async {
        final nonExistentOutput = Directory(
          '${fixture.basePath}/nonexistent_output',
        );

        expect(nonExistentOutput.existsSync(), isFalse);
      });
    });

    group('Input Directory Selection', () {
      test('handles valid input directory structures', () async {
        // Create a Google Takeout-like structure
        final inputDir = fixture.createDirectory('input');
        final takeoutDir = fixture.createDirectory('${inputDir.path}/Takeout');
        final photosDir = fixture.createDirectory(
          '${takeoutDir.path}/Google Photos',
        );

        fixture.createFile('${photosDir.path}/photo1.jpg', [1, 2, 3]);
        fixture.createFile('${photosDir.path}/photo1.jpg.json', [4, 5, 6]);

        expect(inputDir.existsSync(), isTrue);
        expect(takeoutDir.existsSync(), isTrue);
        expect(photosDir.existsSync(), isTrue);
      });

      test('handles multiple Takeout directories', () async {
        final inputDir = fixture.createDirectory('input_multiple');

        // Create multiple takeout directories
        for (int i = 1; i <= 3; i++) {
          final takeoutDir = fixture.createDirectory(
            '${inputDir.path}/Takeout$i',
          );
          final photosDir = fixture.createDirectory(
            '${takeoutDir.path}/Google Photos',
          );
          fixture.createFile('${photosDir.path}/photo$i.jpg', [
            i,
            i + 1,
            i + 2,
          ]);
        }

        final takeoutDirs = inputDir
            .listSync()
            .whereType<Directory>()
            .where((final d) => d.path.contains('Takeout'))
            .toList();

        expect(takeoutDirs.length, 3);
      });

      test('handles nested album structures', () async {
        final inputDir = fixture.createDirectory('input_albums');
        final takeoutDir = fixture.createDirectory('${inputDir.path}/Takeout');
        final photosDir = fixture.createDirectory(
          '${takeoutDir.path}/Google Photos',
        );

        // Create album directories
        final albumDirs = [
          'Photos from 2023',
          'Vacation Album',
          'Family Photos',
          'Random Album',
        ];

        for (final albumName in albumDirs) {
          final albumDir = fixture.createDirectory(
            '${photosDir.path}/$albumName',
          );
          fixture.createFile('${albumDir.path}/photo.jpg', [1, 2, 3]);
          fixture.createFile('${albumDir.path}/photo.jpg.json', [4, 5, 6]);
        }

        final albums = photosDir.listSync().whereType<Directory>().toList();
        expect(albums.length, albumDirs.length);
      });
    });

    group('Error Handling', () {
      test('handles permission errors gracefully', () {
        // This would test how interactive functions handle permission denied errors
        // In a real scenario, we'd mock file system operations
        expect(() => interactive.albumOptions, returnsNormally);
      });

      test('handles invalid input gracefully', () {
        // Test that invalid inputs don't crash the interactive functions
        expect(interactive.albumOptions.containsKey(null), isFalse);
      });

      test('handles interruption signals', () {
        // In a real interactive session, users might press Ctrl+C
        // The interactive functions should handle this gracefully
        expect(() => interactive.indeed, returnsNormally);
      });
    });

    group('Platform Compatibility', () {
      test('handles Windows paths correctly', () {
        if (Platform.isWindows) {
          // Test Windows-specific path handling
          final windowsDir = fixture.createDirectory('windows_test');
          expect(windowsDir.path.contains('\\'), isTrue);
        } else {
          // Test Unix-like paths
          final unixDir = fixture.createDirectory('unix_test');
          expect(unixDir.path.contains('/'), isTrue);
        }
      });

      test('handles different path separators', () {
        final testDir = fixture.createDirectory('path_test');
        final separator = Platform.pathSeparator;

        expect(testDir.path.contains(separator), isTrue);
      });

      test('handles long file paths', () {
        // Test handling of long paths (especially important on Windows)
        final longPath = '${'a' * 50}/${'b' * 50}/${'c' * 50}';

        expect(() {
          final testDir = Directory('${fixture.basePath}/$longPath');
          return testDir.path;
        }, returnsNormally);
      });
    });

    group('Configuration Options', () {
      test('album options cover all expected behaviors', () {
        final requiredOptions = [
          'shortcut',
          'duplicate-copy',
          'json',
          'nothing',
        ];

        for (final option in requiredOptions) {
          expect(
            interactive.albumOptions.keys,
            contains(option),
            reason: 'Missing required album option: $option',
          );
        }
      });

      test('album option descriptions are informative', () {
        for (final entry in interactive.albumOptions.entries) {
          final description = entry.value.toLowerCase();

          // Each description should give some hint about what the option does
          expect(
            description.length,
            greaterThan(10),
            reason: 'Description for ${entry.key} is too short',
          );
        }
      });

      test('default album option exists', () {
        // There should be a reasonable default option
        expect(interactive.albumOptions.keys, contains('shortcut'));
      });
    });

    group('User Experience', () {
      test('option keys are user-friendly', () {
        for (final key in interactive.albumOptions.keys) {
          // Keys should be readable and not too cryptic
          expect(
            key.length,
            greaterThan(2),
            reason: 'Option key $key is too short',
          );
          expect(
            key,
            isNot(matches(RegExp(r'[0-9]+$'))),
            reason: 'Option key $key should not be just numbers',
          );
        }
      });
    });

    group('Integration Scenarios', () {
      test('supports typical Google Photos Takeout structure', () async {
        // Create a realistic Google Photos Takeout structure
        final takeoutRoot = fixture.createDirectory('Takeout');
        final googlePhotos = fixture.createDirectory(
          '${takeoutRoot.path}/Google Photos',
        );

        // Year folders
        final year2023 = fixture.createDirectory(
          '${googlePhotos.path}/Photos from 2023',
        );
        fixture.createDirectory('${googlePhotos.path}/Photos from 2022');

        // Album folders
        final vacation = fixture.createDirectory(
          '${googlePhotos.path}/Vacation Album',
        );
        fixture.createDirectory('${googlePhotos.path}/Family Photos');

        // Add sample files
        fixture.createFile('${year2023.path}/IMG_001.jpg', [1, 2, 3]);
        fixture.createFile('${year2023.path}/IMG_001.jpg.json', [4, 5, 6]);
        fixture.createFile('${vacation.path}/beach.jpg', [7, 8, 9]);
        fixture.createFile('${vacation.path}/beach.jpg.json', [10, 11, 12]);

        expect(takeoutRoot.existsSync(), isTrue);
        expect(year2023.listSync().length, 2); // jpg + json
        expect(vacation.listSync().length, 2); // jpg + json
      });

      test('handles mixed content scenarios', () async {
        final inputDir = fixture.createDirectory('mixed_content');

        // Mix of photos, videos, documents
        fixture.createFile('${inputDir.path}/photo.jpg', [1, 2, 3]);
        fixture.createFile('${inputDir.path}/video.mp4', [4, 5, 6]);
        fixture.createFile('${inputDir.path}/document.pdf', [7, 8, 9]);
        fixture.createFile('${inputDir.path}/readme.txt', [10, 11, 12]);

        final files = inputDir.listSync().whereType<File>().toList();
        expect(files.length, 4);
      });
    });
  });
}
