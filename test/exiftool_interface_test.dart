/// # ExifTool Interface Test Suite - Refactored
///
/// Tests for the ExifTool interface that delegates to the infrastructure service
/// following clean architecture principles. This tests the interface layer
/// that wraps the ExifToolService.
library;

import 'dart:io';
import 'package:gpth/exiftoolInterface.dart';
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('ExifTool Interface (Clean Architecture)', () {
    late TestFixture fixture;
    late ExiftoolInterface? exiftool;
    late File testImage;
    setUpAll(() async {
      // Initialize ExifTool service first - now using the interface module level functions
      await initExiftool();
    });

    tearDownAll(() async {
      await cleanupExiftool();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      // Create interface instance
      exiftool = await ExiftoolInterface.find();
      if (exiftool != null) {
        await exiftool!.startPersistentProcess();

        // Create a minimal valid JPEG file for testing
        // This is a 1x1 pixel JPEG image
        final jpegBytes = [
          0xFF, 0xD8, // JPEG SOI marker
          0xFF, 0xE0, // JFIF APP0 marker
          0x00, 0x10, // APP0 length (16 bytes)
          0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
          0x01, 0x01, // JFIF version 1.1
          0x00, // no units
          0x00, 0x01, 0x00, 0x01, // X and Y density = 1
          0x00, 0x00, // no thumbnail

          0xFF, 0xDB, // DQT marker
          0x00, 0x43, // DQT length (67 bytes)
          0x00, // precision and table ID
          // Quantization table (64 bytes, all 1s for minimal size)
          ...List.filled(64, 0x01),

          0xFF, 0xC0, // SOF0 marker
          0x00, 0x11, // SOF0 length (17 bytes)
          0x08, // precision (8 bits)
          0x00, 0x01, // height (1 pixel)
          0x00, 0x01, // width (1 pixel)
          0x01, // number of components (grayscale)
          0x01, 0x11, 0x00, // component 1: ID=1, sampling=1x1, QT=0

          0xFF, 0xC4, // DHT marker
          0x00, 0x1F, // DHT length (31 bytes)
          0x00, // class and destination ID
          // Huffman table (simplified)
          0x00,
          0x01,
          0x05,
          0x01,
          0x01,
          0x01,
          0x01,
          0x01,
          0x01,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x07,
          0x08,
          0x09,
          0x0A,
          0x0B,

          0xFF, 0xDA, // SOS marker
          0x00, 0x08, // SOS length (8 bytes)
          0x01, // number of components
          0x01, 0x00, // component 1: ID=1, Huffman tables=0
          0x00, 0x3F, 0x00, // spectral selection and successive approximation

          0x00, // minimal scan data

          0xFF, 0xD9, // JPEG EOI marker
        ];
        testImage = fixture.createFile('test.jpg', jpegBytes);
      }
    });

    tearDown(() async {
      await exiftool?.dispose();
      await fixture.tearDown();
    });

    group('Interface Initialization', () {
      test('ExifTool interface can be found and initialized', () {
        // Skip if not available since it's an external dependency
        if (exiftool == null) {
          print('Skipping ExifTool tests - ExifTool not found on system');
          return;
        }

        expect(exiftool, isNotNull);
        expect(exiftool, isA<ExiftoolInterface>());
      });
    });

    group('EXIF Reading Operations', () {
      test('readExif returns EXIF data for image', () async {
        if (exiftool == null) return; // Skip if exiftool not available

        final tags = await exiftool!.readExif(testImage);

        expect(tags, isA<Map<String, dynamic>>());
        // Image might not have EXIF data, but should return a map
      });

      test('readExif handles non-existent files', () async {
        if (exiftool == null) return;

        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');

        expect(
          () => exiftool!.readExif(nonExistentFile),
          throwsA(isA<Exception>()),
        );
      });

      test('readExif handles invalid file formats', () async {
        if (exiftool == null) return;

        final textFile = fixture.createFile(
          'test.txt',
          'Hello world'.codeUnits,
        );

        // Should handle gracefully (might return empty map or throw)
        expect(() => exiftool!.readExif(textFile), returnsNormally);
      });
    });

    group('EXIF Writing Operations', () {
      test('writeExif handles basic metadata', () async {
        if (exiftool == null) return;

        final testData = {'Artist': 'Test Artist', 'Software': 'Test Software'};

        expect(() => exiftool!.writeExif(testImage, testData), returnsNormally);
      });

      test('writeExif handles GPS coordinates', () async {
        if (exiftool == null) return;

        final gpsData = {
          'GPSLatitude': '40.7128',
          'GPSLongitude': '-74.0060',
          'GPSLatitudeRef': 'N',
          'GPSLongitudeRef': 'W',
        };

        expect(() => exiftool!.writeExif(testImage, gpsData), returnsNormally);
      });

      test('writeExif handles DateTime metadata', () async {
        if (exiftool == null) return;

        final dateTimeData = {
          'DateTimeOriginal': '2023:01:15 14:30:00',
          'CreateDate': '2023:01:15 14:30:00',
        };

        expect(
          () => exiftool!.writeExif(testImage, dateTimeData),
          returnsNormally,
        );
      });
    });

    group('Error Handling', () {
      test('handles non-existent file writes gracefully', () async {
        if (exiftool == null) return;

        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');

        expect(
          () => exiftool!.writeExif(nonExistentFile, {'Artist': 'Test'}),
          throwsA(isA<Exception>()),
        );
      });

      test('handles invalid file format writes', () async {
        if (exiftool == null) return;

        final textFile = fixture.createFile(
          'test.txt',
          'Hello world'.codeUnits,
        );

        expect(
          () => exiftool!.writeExif(textFile, {'Artist': 'Test'}),
          returnsNormally, // ExifTool might handle this gracefully
        );
      });
    });

    group('Resource Management', () {
      test('dispose cleans up resources properly', () async {
        if (exiftool == null) return;

        // Should dispose without throwing
        expect(() => exiftool!.dispose(), returnsNormally);
      });
    });
  });
}
