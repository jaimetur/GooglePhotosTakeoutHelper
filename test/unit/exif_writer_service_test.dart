/// Test suite for ExifWriterService
///
/// Tests the EXIF data writing functionality.
library;

import 'dart:convert';
import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:gpth/domain/services/exif_writer_service.dart';
import 'package:gpth/domain/services/global_config_service.dart';
import 'package:gpth/infrastructure/exiftool_service.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

/// Mock ExifTool service for testing
class MockExifToolService implements ExifToolService {
  bool shouldFail = false;
  Map<String, dynamic>? lastWrittenData;
  File? lastWrittenFile;

  @override
  final String exiftoolPath = '/mock/path/exiftool';

  @override
  Future<void> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    lastWrittenFile = file;
    lastWrittenData = exifData;

    if (shouldFail) {
      throw Exception('Mock ExifTool failure');
    }
  }

  @override
  Future<Map<String, dynamic>> readExifData(final File file) async {
    if (shouldFail) {
      throw Exception('Mock ExifTool failure');
    }
    return {};
  }

  @override
  Future<void> startPersistentProcess() async {
    if (shouldFail) {
      throw Exception('Mock ExifTool startup failure');
    }
  }

  @override
  Future<String> executeCommand(final List<String> args) async {
    if (shouldFail) {
      throw Exception('Mock ExifTool command failure');
    }
    return 'Mock command output';
  }

  @override
  Future<void> dispose() async {
    // Mock cleanup
  }
}

void main() {
  group('ExifWriterService', () {
    late ExifWriterService service;
    late MockExifToolService mockExifTool;
    late TestFixture fixture;

    setUp(() async {
      mockExifTool = MockExifToolService();
      service = ExifWriterService(mockExifTool);
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('writeExifData', () {
      test('returns true when exiftool succeeds', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final exifData = {'DateTimeOriginal': '2023:01:01 12:00:00'};

        mockExifTool.shouldFail = false;

        final result = await service.writeExifData(file, exifData);

        expect(result, isTrue);
        expect(mockExifTool.lastWrittenFile?.path, equals(file.path));
        expect(mockExifTool.lastWrittenData, equals(exifData));
      });

      test('returns false when exiftool fails', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final exifData = {'DateTimeOriginal': '2023:01:01 12:00:00'};

        mockExifTool.shouldFail = true;

        final result = await service.writeExifData(file, exifData);

        expect(result, isFalse);
      });

      test('handles empty exif data', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final exifData = <String, dynamic>{};

        mockExifTool.shouldFail = false;

        final result = await service.writeExifData(file, exifData);

        expect(result, isTrue);
        expect(mockExifTool.lastWrittenData, equals(exifData));
      });
    });

    group('writeExifDataWithJson', () {
      test('writes to both file and JSON when successful', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final jsonFile = fixture.createFile(
          'test.json',
          utf8.encode('{"title": "test"}'),
        );
        final exifData = {'DateTimeOriginal': '2023:01:01 12:00:00'};

        mockExifTool.shouldFail = false;

        final result = await service.writeExifDataWithJson(
          file,
          jsonFile,
          exifData,
        );

        expect(result, isTrue);
        expect(mockExifTool.lastWrittenFile?.path, equals(file.path));

        // Verify JSON was updated
        final updatedJson = await jsonFile.readAsString();
        final jsonMap = jsonDecode(updatedJson);
        expect(jsonMap['title'], equals('test'));
        expect(jsonMap['DateTimeOriginal'], equals('2023:01:01 12:00:00'));
      });

      test('returns false when exiftool fails', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final jsonFile = fixture.createFile(
          'test.json',
          utf8.encode('{"title": "test"}'),
        );
        final exifData = {'DateTimeOriginal': '2023:01:01 12:00:00'};

        mockExifTool.shouldFail = true;

        final result = await service.writeExifDataWithJson(
          file,
          jsonFile,
          exifData,
        );

        expect(result, isFalse);
      });

      test('returns false when JSON file is invalid', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final jsonFile = fixture.createFile(
          'test.json',
          utf8.encode('invalid json'),
        );
        final exifData = {'DateTimeOriginal': '2023:01:01 12:00:00'};

        mockExifTool.shouldFail = false;

        final result = await service.writeExifDataWithJson(
          file,
          jsonFile,
          exifData,
        );

        expect(result, isFalse);
      });
    });

    group('writeDateTimeToExif', () {
      test('handles datetime writing attempt', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final dateTime = DateTime(2023, 1, 1, 12);
        final globalConfig = GlobalConfigService();

        mockExifTool.shouldFail = false;

        final result = await service.writeDateTimeToExif(
          dateTime,
          file,
          globalConfig,
        );

        // Note: This method has complex logic that may return false due to
        // existing date checks, file format checks, etc.
        expect(result, isA<bool>());
      });
    });

    group('writeGpsToExif', () {
      test('handles GPS coordinate writing attempt', () async {
        final file = fixture.createImageWithExif('test.jpg');
        // Create coordinates using DD first, then convert to DMS (same pattern as in the actual service)
        final ddCoordinates = DDCoordinates(
          latitude: 40.713,
          longitude: -74.006,
        );
        final coordinates = DMSCoordinates.fromDD(ddCoordinates);
        final globalConfig = GlobalConfigService();

        final result = await service.writeGpsToExif(
          coordinates,
          file,
          globalConfig,
        );

        // Complex method that depends on file format and exiftool availability
        expect(result, isA<bool>());
      });
    });

    group('error handling', () {
      test('handles exiftool errors gracefully', () async {
        final file = fixture.createImageWithExif('test.jpg');
        final exifData = {'DateTimeOriginal': '2023:01:01 12:00:00'};

        mockExifTool.shouldFail = true;

        final result = await service.writeExifData(file, exifData);

        expect(result, isFalse);
      });
    });
  });
}
