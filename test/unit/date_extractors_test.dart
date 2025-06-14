/// # Date Extractors Test Suite
///
/// Comprehensive tests for date extraction functionality that recovers timestamp
/// information from various sources in Google Photos Takeout exports, ensuring
/// accurate chronological organization of media files.
library;

import 'dart:io';

import 'package:gpth/domain/services/date_extraction/date_extractor_service.dart';
import 'package:gpth/domain/services/global_config_service.dart';
import 'package:gpth/domain/services/service_container.dart';
import 'package:gpth/infrastructure/exiftool_service.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  late ExifToolService exifTool;

  setUpAll(() async {
    exifTool = (await ExifToolService.find())!;
    await exifTool.startPersistentProcess();
    ServiceContainer.instance.exifTool = exifTool;
  });

  tearDownAll(() async {
    await exifTool.dispose();
  });

  group('Date Extractors', () {
    late TestFixture fixture;
    late GlobalConfigService globalConfig;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      globalConfig = GlobalConfigService();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('JSON Date Extractor', () {
      test('extracts date from valid JSON metadata', () async {
        final jsonFile = fixture.createJsonWithDate('test.json', '1640960007');
        final result = await jsonDateTimeExtractor(jsonFile);

        expect(result, DateTime.parse('2021-12-31 15:13:27.000'));
      });

      test('returns null for invalid JSON', () async {
        final jsonFile = fixture.createFile('invalid.json', [1, 2, 3]);

        final result = await jsonDateTimeExtractor(jsonFile);

        expect(result, isNull);
      });

      test('returns null for missing timestamp', () async {
        final jsonFile = fixture.createJsonWithoutDate('test.json');

        final result = await jsonDateTimeExtractor(jsonFile);

        expect(result, isNull);
      });
    });

    group('EXIF Date Extractor', () {
      test('extracts date from EXIF data', () async {
        final imgFile = fixture.createImageWithExif('test.jpg');

        final result = await ExifDateExtractor(
          ServiceContainer.instance.exifTool!,
        ).exifDateTimeExtractor(imgFile, globalConfig: globalConfig);

        expect(result, DateTime.parse('2022-12-16 16:06:47'));
      });

      test('returns null for image without EXIF data', () async {
        final imgFile = fixture.createImageWithoutExif('test.jpg');

        final result = await ExifDateExtractor(
          ServiceContainer.instance.exifTool!,
        ).exifDateTimeExtractor(imgFile, globalConfig: globalConfig);

        expect(result, isNull);
      });

      test('returns null for non-image files', () async {
        final txtFile = fixture.createFile('test.txt', [1, 2, 3]);

        final result = await ExifDateExtractor(
          ServiceContainer.instance.exifTool!,
        ).exifDateTimeExtractor(txtFile, globalConfig: globalConfig);

        expect(result, isNull);
      });
    });
    group('Guess Date Extractor', () {
      group('IMG filename patterns', () {
        test('extracts date from IMG_20220101_123456.jpg', () async {
          final file = File('${fixture.basePath}/IMG_20220101_123456.jpg');

          final result = await guessExtractor(file);

          expect(result, isNotNull);
          expect(result!.year, 2022);
        });

        test('extracts date from IMG_20220131_235959.png', () async {
          final file = File('${fixture.basePath}/IMG_20220131_235959.png');

          final result = await guessExtractor(file);

          expect(result, isNotNull);
          expect(result!.year, 2022);
        });

        test(
          'extracts date from IMG_20200229_000000.gif (leap year)',
          () async {
            final file = File('${fixture.basePath}/IMG_20200229_000000.gif');

            final result = await guessExtractor(file);

            expect(result, isNotNull);
            expect(result!.year, 2020);
          },
        );
      });

      test('returns null for unrecognizable filename patterns', () async {
        final file = File('${fixture.basePath}/random_name.jpg');

        final result = await guessExtractor(file);

        expect(result, isNull);
      });
    });
  });
}
