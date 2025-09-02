import 'dart:convert';
import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Extension Fixing and Metadata Matcher Integration Tests - Issue #32', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    /// Helper method to create a JSON metadata file
    File createJsonFile(
      final String name,
      final Map<String, dynamic> metadata,
    ) => fixture.createFile(name, utf8.encode(jsonEncode(metadata)));

    /// Helper method to create sample metadata content
    Map<String, dynamic> createSampleMetadata(final String title) => {
      'title': title,
      'description': 'Sample photo metadata',
      'photoTakenTime': {
        'timestamp': '1640995200', // Jan 1, 2022
      },
      'geoData': {'latitude': 37.7749, 'longitude': -122.4194},
    };

    group('Extension Fixing Scenarios from Issue #32', () {
      test('finds JSON after extension is fixed from HEIC to jpg', () async {
        // Scenario: Original HEIC file gets extension fixed to .jpg
        // Original: IMG_2367.HEIC with IMG_2367.HEIC.supplemental-metadata.json
        // After fixing: IMG_2367.HEIC.jpg (should still find the JSON)

        final jsonFile = createJsonFile(
          'IMG_2367.HEIC.supplemental-metadata.json',
          createSampleMetadata('Original HEIC photo'),
        );

        // Simulate the file after extension fixing (HEIC -> jpg)
        final fixedMediaFile = fixture.createImageWithExif('IMG_2367.HEIC.jpg');

        // Should find the JSON even though file extension was changed
        final result = await jsonForFile(fixedMediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test(
        'finds JSON for numbered duplicate after extension fixing',
        () async {
          // Scenario: IMG_2367(1).HEIC -> IMG_2367(1).HEIC.jpg
          // JSON: IMG_2367.HEIC.supplemental-metadata(1).json

          final jsonFile = createJsonFile(
            'IMG_2367.HEIC.supplemental-metadata(1).json',
            createSampleMetadata('Duplicate HEIC photo'),
          );

          final fixedMediaFile = fixture.createImageWithExif(
            'IMG_2367(1).HEIC.jpg',
          );

          final result = await jsonForFile(fixedMediaFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );

      test('finds JSON for MP4 files with HEIC-based JSON names', () async {
        // Scenario: MP4 file shares JSON with HEIC file
        // MP4: IMG_2367.MP4
        // JSON: IMG_2367.HEIC.supplemental-metadata.json (shared)

        final jsonFile = createJsonFile(
          'IMG_2367.HEIC.supplemental-metadata.json',
          createSampleMetadata('Shared HEIC/MP4 metadata'),
        );

        final mp4File = fixture.createFile('IMG_2367.MP4', []);

        final result = await jsonForFile(mp4File, tryhard: true);
        expect(result?.path, equals(jsonFile.path));
      });

      test('handles complex numbered duplicates with extension fixing', () async {
        // Complex scenario from issue #32:
        // Original files: IMG_2367(1).HEIC, IMG_2367(1).MP4
        // JSON: IMG_2367.HEIC.supplemental-metadata(1).json, IMG_2367.MP4.supplemental-metadata(1).json
        // After fixing: IMG_2367(1).HEIC.jpg, IMG_2367(1).MP4

        final heicJsonFile = createJsonFile(
          'IMG_2367.HEIC.supplemental-metadata(1).json',
          createSampleMetadata('HEIC duplicate metadata'),
        );

        final mp4JsonFile = createJsonFile(
          'IMG_2367.MP4.supplemental-metadata(1).json',
          createSampleMetadata('MP4 duplicate metadata'),
        );

        // Test the fixed HEIC file
        final fixedHeicFile = fixture.createImageWithExif(
          'IMG_2367(1).HEIC.jpg',
        );
        final heicResult = await jsonForFile(fixedHeicFile, tryhard: false);
        expect(heicResult?.path, equals(heicJsonFile.path));

        // Test the MP4 file (unchanged)
        final mp4File = fixture.createFile('IMG_2367(1).MP4', []);
        final mp4Result = await jsonForFile(mp4File, tryhard: false);
        expect(mp4Result?.path, equals(mp4JsonFile.path));
      });

      test(
        'handles extension fixing with PhotoMigrator-created JSON files',
        () async {
          // Scenario mentioned in issue: PhotoMigrator creates additional JSON files
          // Original: IMG_2367.HEIC, IMG_2367.MP4
          // JSONs: IMG_2367.HEIC.supplemental-metadata.json, IMG_2367.MP4.supplemental-metadata.json
          // After extension fixing: IMG_2367.HEIC.jpg

          final heicJsonFile = createJsonFile(
            'IMG_2367.HEIC.supplemental-metadata.json',
            createSampleMetadata('Original HEIC metadata'),
          );

          final mp4JsonFile = createJsonFile(
            'IMG_2367.MP4.supplemental-metadata.json',
            createSampleMetadata('PhotoMigrator-created MP4 metadata'),
          );

          // Test the fixed HEIC file should find its original JSON
          final fixedHeicFile = fixture.createImageWithExif(
            'IMG_2367.HEIC.jpg',
          );
          final heicResult = await jsonForFile(fixedHeicFile, tryhard: false);
          expect(heicResult?.path, equals(heicJsonFile.path));

          // Test the MP4 file should find its JSON
          final mp4File = fixture.createFile('IMG_2367.MP4', []);
          final mp4Result = await jsonForFile(mp4File, tryhard: false);
          expect(mp4Result?.path, equals(mp4JsonFile.path));
        },
      );
    });

    group('Strategy Order Validation Tests', () {
      test('verifies strategy order is from most to least likely', () async {
        // Test that basic strategies are ordered correctly
        final basicStrategies = JsonMetadataMatcherService.getAllStrategies(
          includeAggressive: false,
        );
        expect(basicStrategies.length, equals(6));
        expect(basicStrategies[0].name, equals('No modification'));
        expect(basicStrategies[1].name, equals('Filename shortening'));
        expect(basicStrategies[2].name, equals('Bracket number swapping'));
        expect(basicStrategies[3].name, equals('Remove file extension'));
        expect(
          basicStrategies[4].name,
          equals('Remove complete extra formats'),
        );
        expect(basicStrategies[5].name, equals('MP file JSON matching'));
      });
      test(
        'verifies aggressive strategies are appropriately ordered',
        () async {
          final allStrategies = JsonMetadataMatcherService.getAllStrategies(
            includeAggressive: true,
          );
          expect(allStrategies.length, equals(10)); // 6 basic + 4 aggressive
          expect(allStrategies[6].name, equals('Cross-extension matching'));
          expect(allStrategies[7].name, equals('Remove partial extra formats'));
          expect(
            allStrategies[8].name,
            equals('Extension restoration after partial removal'),
          );
          expect(allStrategies[9].name, equals('Edge case pattern removal'));
        },
      );

      test('tests strategy effectiveness order with real scenarios', () async {
        // Create a scenario where multiple strategies could match
        // but we want to ensure the most conservative one wins

        // Create files that would match multiple strategies
        final primaryJsonFile = createJsonFile(
          'photo.jpg.json',
          createSampleMetadata('Primary match - no modification'),
        );

        final bracketJsonFile = createJsonFile(
          'photo.jpg(1).json',
          createSampleMetadata('Bracket swap match'),
        );

        final mediaFile = fixture.createImageWithExif('photo.jpg');

        // Should find the primary match (Strategy 1: No modification)
        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(primaryJsonFile.path));
        expect(result?.path, isNot(equals(bracketJsonFile.path)));
      });

      test(
        'tests that extension removal strategy works for fixed files',
        () async {
          // Test Strategy 4: Remove file extension
          // This is crucial for extension fixing scenarios

          final jsonFile = createJsonFile(
            'IMG_2367.HEIC.supplemental-metadata.json',
            createSampleMetadata('Extension removal test'),
          );

          // Simulate extension-fixed file
          final fixedFile = fixture.createImageWithExif('IMG_2367.HEIC.jpg');

          // Should find JSON by removing the .jpg extension
          final result = await jsonForFile(fixedFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );

      test('validates that bracket swapping works with extension fixing', () async {
        // Combined test: bracket swapping + extension fixing
        // File: IMG_2367(1).HEIC.jpg (after extension fixing)
        // JSON: IMG_2367.HEIC(1).supplemental-metadata.json (bracket swapped pattern)

        final jsonFile = createJsonFile(
          'IMG_2367.HEIC(1).supplemental-metadata.json',
          createSampleMetadata('Bracket swap with extension fixing'),
        );

        final fixedFile = fixture.createImageWithExif('IMG_2367(1).HEIC.jpg');

        // Should find JSON through combination of extension removal and bracket swapping
        final result = await jsonForFile(fixedFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });
    });

    group('Edge Cases and Robustness Tests', () {
      test('handles files with multiple extensions after fixing', () async {
        // Test files like: photo.HEIC.NEF.jpg (multiple extensions after fixing)

        final jsonFile = createJsonFile(
          'photo.HEIC.NEF.supplemental-metadata.json',
          createSampleMetadata('Multiple extension test'),
        );

        final fixedFile = fixture.createImageWithExif('photo.HEIC.NEF.jpg');

        final result = await jsonForFile(fixedFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test('handles case sensitivity issues', () async {
        // Test case variations that might occur during extension fixing

        final jsonFile = createJsonFile(
          'Photo.HEIC.supplemental-metadata.json',
          createSampleMetadata('Case sensitivity test'),
        );

        final fixedFile = fixture.createImageWithExif('Photo.HEIC.jpg');

        final result = await jsonForFile(fixedFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });

      test('prioritizes supplemental-metadata over standard json', () async {
        // Test that supplemental-metadata format is preferred over standard .json

        final supplementalJsonFile = createJsonFile(
          'photo.jpg.supplemental-metadata.json',
          createSampleMetadata('Supplemental metadata'),
        );

        final standardJsonFile = createJsonFile(
          'photo.jpg.json',
          createSampleMetadata('Standard metadata'),
        );

        final mediaFile = fixture.createImageWithExif('photo.jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(supplementalJsonFile.path));
        expect(result?.path, isNot(equals(standardJsonFile.path)));
      });
      test('handles filename truncation in supplemental-metadata files', () async {
        // Test Google Photos 51-character limit handling
        // Create a filename that would result in truncation when supplemental-metadata is added
        // Base name needs to be short enough to allow meaningful truncation
        // 23 chars + .jpg (4) + . (1) + supplemental-meta (16) + .json (5) = 49 chars

        const baseName = 'filename_for_truncation'; // 23 chars
        final jsonFile = createJsonFile(
          '$baseName.jpg.supplemental-meta.json', // Truncated version
          createSampleMetadata('Truncated supplemental metadata'),
        );

        final mediaFile = fixture.createImageWithExif('$baseName.jpg');

        final result = await jsonForFile(mediaFile, tryhard: false);
        expect(result?.path, equals(jsonFile.path));
      });
    });

    group('Regression Tests for Known Issues', () {
      test(
        'ensures no false positives from overly aggressive matching',
        () async {
          // Test that we don't match unrelated JSON files

          createJsonFile(
            'different_photo.jpg.json',
            createSampleMetadata('Wrong photo metadata'),
          );

          final mediaFile = fixture.createImageWithExif('target_photo.jpg');

          final result = await jsonForFile(mediaFile, tryhard: true);
          expect(result, isNull);
        },
      );

      test(
        'handles special characters in filenames after extension fixing',
        () async {
          // Test files with special characters that might be affected by extension fixing

          final jsonFile = createJsonFile(
            'Fin de año 2023.HEIC.supplemental-metadata.json',
            createSampleMetadata('Special characters test'),
          );

          final fixedFile = fixture.createImageWithExif(
            'Fin de año 2023.HEIC.jpg',
          );

          final result = await jsonForFile(fixedFile, tryhard: false);
          expect(result?.path, equals(jsonFile.path));
        },
      );
    });
  });
}
