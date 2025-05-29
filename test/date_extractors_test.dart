// Tests for date extraction from JSON, EXIF, and filename guessing.

import 'dart:io';
import 'package:gpth/date_extractors/date_extractor.dart';
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('Date Extractors', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('JSON Date Extractor', () {
      /// Should extract date from a valid JSON metadata file.
      test('extracts date from valid JSON file', () async {
        final imgFile = fixture.createFile('test.jpg', [1, 2, 3]);
        fixture.createJsonFile('test.jpg.json', 1599078832);

        final result = await jsonDateTimeExtractor(imgFile);

        expect(result?.millisecondsSinceEpoch, 1599078832 * 1000);
      });

      /// Should return null if the JSON metadata file does not exist.
      test('returns null when JSON file does not exist', () async {
        final imgFile = fixture.createFile('test.jpg', [1, 2, 3]);

        final result = await jsonDateTimeExtractor(imgFile);

        expect(result, isNull);
      });

      /// Should extract date using tryhard option for edited filenames.
      test('extracts date with tryhard option', () async {
        final imgFile = fixture.createFile('test-edited.jpg', [1, 2, 3]);
        fixture.createJsonFile('test.jpg.json', 1599078832);

        final DateTime? resultWithoutTryhard = await jsonDateTimeExtractor(
          imgFile,
        );
        final resultWithTryhard = await jsonDateTimeExtractor(
          imgFile,
          tryhard: true,
        );

        expect(resultWithoutTryhard, isNotNull);
        expect(resultWithTryhard?.millisecondsSinceEpoch, 1599078832 * 1000);
      });

      /// Should handle malformed JSON files gracefully and return null.
      test('handles malformed JSON gracefully', () async {
        final imgFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final jsonFile = File('${fixture.basePath}/test.jpg.json');
        jsonFile.createSync();
        jsonFile.writeAsStringSync('invalid json content');

        final result = await jsonDateTimeExtractor(imgFile);

        expect(result, isNull);
      });
    });

    group('EXIF Date Extractor', () {
      /// Should extract date from EXIF metadata in an image.
      test('extracts date from EXIF data', () async {
        final imgFile = fixture.createImageWithExif('test.jpg');

        final result = await exifDateTimeExtractor(imgFile);

        expect(result, DateTime.parse('2022-12-16 16:06:47'));
      });

      /// Should return null for images without EXIF metadata.
      test('returns null for image without EXIF data', () async {
        final imgFile = fixture.createImageWithoutExif('test.jpg');

        final result = await exifDateTimeExtractor(imgFile);

        expect(result, isNull);
      });

      /// Should return null for non-image files.
      test('returns null for non-image files', () async {
        final txtFile = fixture.createFile('test.txt', [1, 2, 3]);

        final result = await exifDateTimeExtractor(txtFile);

        expect(result, isNull);
      });
    });

    group('Guess Date Extractor', () {
      /// Should extract dates from various filename patterns.
      test('extracts dates from various filename patterns', () async {
        for (final pattern in testDatePatterns) {
          final filename = pattern[0];
          final expectedDate = DateTime.parse(pattern[1]);
          final file = File('${fixture.basePath}/$filename');

          final result = await guessExtractor(file);

          expect(
            result,
            expectedDate,
            reason: 'Failed for filename: $filename',
          );
        }
      });

      /// Should return null for filenames that do not match known patterns.
      test('returns null for unrecognizable filename patterns', () async {
        final file = File('${fixture.basePath}/random_name.jpg');

        final result = await guessExtractor(file);

        expect(result, isNull);
      });
    });
  });
}
