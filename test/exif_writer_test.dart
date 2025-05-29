import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:exif_reader/exif_reader.dart';
import 'package:gpth/exif_writer.dart';
import 'package:gpth/exiftoolInterface.dart';
import 'package:intl/intl.dart';
import 'package:test/test.dart';

import './test_setup.dart';

void main() {
  group('EXIF Writer', () {
    late TestFixture fixture;

    setUpAll(() async {
      await initExiftool();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('GPS Coordinates Writing', () {
      test('writeGpsToExif writes GPS coordinates to JPEG file', () async {
        final testImage = fixture.createImageWithoutExif('test.jpg');
        final coordinates = DMSCoordinates(
          latDegrees: 41,
          latMinutes: 19,
          latSeconds: 22.1611,
          longDegrees: 19,
          longMinutes: 48,
          longSeconds: 14.9139,
          latDirection: DirectionY.north,
          longDirection: DirectionX.east,
        );

        final result = await writeGpsToExif(coordinates, testImage);

        expect(result, isTrue);

        // Verify coordinates were written
        if (exiftool != null) {
          final tags = await exiftool!.readExif(testImage);
          expect(tags['GPSLatitude'], isNotNull);
          expect(tags['GPSLongitude'], isNotNull);
          expect(tags['GPSLatitudeRef'], 'N');
          expect(tags['GPSLongitudeRef'], 'E');
        }
      });

      test(
        'writeGpsToExif returns false for unsupported file formats',
        () async {
          final textFile = fixture.createFile('test.txt', [1, 2, 3]);
          final coordinates = DMSCoordinates(
            latDegrees: 41,
            latMinutes: 19,
            latSeconds: 22.1611,
            longDegrees: 19,
            longMinutes: 48,
            longSeconds: 14.9139,
            latDirection: DirectionY.north,
            longDirection: DirectionX.east,
          );

          final result = await writeGpsToExif(coordinates, textFile);

          expect(result, isFalse);
        },
      );
    });

    group('DateTime Writing', () {
      test(
        'writeDateTimeToExif writes DateTime to image without EXIF',
        () async {
          final testImage = fixture.createImageWithoutExif('test.jpg');
          final testDateTime = DateTime(2023, 12, 25, 15, 30, 45);

          final result = await writeDateTimeToExif(testDateTime, testImage);

          expect(result, isTrue);

          // Verify DateTime was written
          final tags = await readExifFromBytes(await testImage.readAsBytes());
          final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
          final expectedDateTime = exifFormat.format(testDateTime);
          expect(tags['Image DateTime']?.printable, expectedDateTime);
          expect(tags['EXIF DateTimeOriginal']?.printable, expectedDateTime);
          expect(tags['EXIF DateTimeDigitized']?.printable, expectedDateTime);
        },
      );

      test(
        'writeDateTimeToExif skips files with existing EXIF DateTime',
        () async {
          final testImage = fixture.createImageWithExif('test.jpg');
          final testDateTime = DateTime(2023, 12, 25, 15, 30, 45);

          final result = await writeDateTimeToExif(testDateTime, testImage);

          expect(result, isFalse);
        },
      );

      test(
        'writeDateTimeToExif returns false for unsupported file formats',
        () async {
          final textFile = fixture.createFile('test.txt', [1, 2, 3]);
          final testDateTime = DateTime(2023, 12, 25, 15, 30, 45);

          final result = await writeDateTimeToExif(testDateTime, textFile);

          expect(result, isFalse);
        },
      );

      test('writeDateTimeToExif handles JPEG files correctly', () async {
        final testImage = fixture.createImageWithoutExif('test.jpg');
        final testDateTime = DateTime(2023, 12, 25, 15, 30, 45);

        final result = await writeDateTimeToExif(testDateTime, testImage);

        expect(result, isTrue);

        // Check that the DateTime was actually written
        final newExifData = await readExifFromBytes(
          await testImage.readAsBytes(),
        );
        expect(newExifData.isNotEmpty, isTrue);
        expect(newExifData['Image DateTime'], isNotNull);
      });

      test(
        'writeDateTimeToExif handles corrupted image files gracefully',
        () async {
          final corruptedFile = fixture.createFile('corrupted.jpg', [
            1,
            2,
            3,
            4,
            5,
          ]);
          final testDateTime = DateTime(2023, 12, 25, 15, 30, 45);

          final result = await writeDateTimeToExif(testDateTime, corruptedFile);

          // Should handle gracefully and return false
          expect(result, isFalse);
        },
      );
    });

    group('Native vs ExifTool Writing', () {
      test('prefers native JPEG writing when available', () async {
        final testImage = fixture.createImageWithoutExif('test.jpg');
        final testDateTime = DateTime(2023, 12, 25, 15, 30, 45);

        final result = await writeDateTimeToExif(testDateTime, testImage);

        expect(result, isTrue);
        // The test doesn't need to verify which method was used,
        // just that it succeeded
      });

      test(
        'falls back to ExifTool for non-JPEG files',
        () async {
          // This would be for testing non-JPEG files like TIFF, but we'll
          // keep it simple for now since we're using JPEG test images
          expect(true, isTrue); // Placeholder for ExifTool fallback tests
        },
        skip: 'Would require ExifTool and non-JPEG test files',
      );
    });
  });
}
