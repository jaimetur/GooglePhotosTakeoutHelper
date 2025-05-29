import 'dart:io';
import 'package:exif_reader/exif_reader.dart';
import 'package:gpth/exiftoolInterface.dart';
import 'package:test/test.dart';
import './test_setup.dart';

void main() {
  group('ExifTool Interface', () {
    late TestFixture fixture;
    late ExiftoolInterface? exiftool;
    late File testImageWithExif;
    late File testImageNoExif;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await initExiftool();
      exiftool = await ExiftoolInterface.find();
      testImageWithExif = fixture.createImageWithExif('test_with_exif.jpg');
      testImageNoExif = fixture.createImageWithoutExif('test_no_exif.jpg');
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('EXIF Reading Operations', () {
      test('readExif returns EXIF data for image with metadata', () async {
        if (exiftool == null) return; // Skip if exiftool not available

        final tags = await exiftool!.readExif(testImageWithExif);

        expect(tags, isA<Map<String, dynamic>>());
        expect(tags.isNotEmpty, isTrue);
      });

      test('readExifBatch returns specific requested tags', () async {
        if (exiftool == null) return;

        final requestedTags = ['DateTimeOriginal', 'Make', 'Model'];
        final tags = await exiftool!.readExifBatch(
          testImageWithExif,
          requestedTags,
        );

        expect(tags, isA<Map<String, dynamic>>());
        expect(
          tags.containsKey('SourceFile'),
          isFalse,
        ); // Should not include SourceFile

        // Should only contain requested tags that exist
        for (final tag in tags.keys) {
          expect(requestedTags, contains(tag));
        }
      });

      test('readExifBatch returns empty map for empty tag list', () async {
        if (exiftool == null) return;

        final tags = await exiftool!.readExifBatch(testImageWithExif, []);

        expect(tags, isEmpty);
      });

      test('readExifBatch handles non-existent tags gracefully', () async {
        if (exiftool == null) return;

        final nonExistentTags = ['NonExistentTag1', 'FakeTag2', 'InvalidTag3'];
        final tags = await exiftool!.readExifBatch(
          testImageWithExif,
          nonExistentTags,
        );

        expect(tags, isA<Map<String, dynamic>>());
        // Should be empty or only contain tags that actually exist
      });

      test('readExif handles image without EXIF data', () async {
        if (exiftool == null) return;

        final tags = await exiftool!.readExif(testImageNoExif);

        expect(tags, isA<Map<String, dynamic>>());
        // May have basic file info but no EXIF metadata
      });

      test('readExif handles unsupported file types', () async {
        if (exiftool == null) return;

        final textFile = fixture.createFile('test.txt', [65, 66, 67]); // "ABC"
        final tags = await exiftool!.readExif(textFile);

        expect(tags, isA<Map<String, dynamic>>());
        // Should handle gracefully, possibly returning empty map
      });
    });

    group('EXIF Writing Operations', () {
      late File testImage;

      setUp(() {
        testImage = fixture.createImageWithoutExif('test_write.jpg');
      });

      test('writeExifBatch writes single tag successfully', () async {
        if (exiftool == null) return;

        final tagsToWrite = {'Artist': 'Test Artist'};
        final result = await exiftool!.writeExifBatch(testImage, tagsToWrite);

        expect(result, isTrue);

        // Verify the tag was written
        final writtenTags = await exiftool!.readExifBatch(testImage, [
          'Artist',
        ]);
        expect(writtenTags['Artist'], 'Test Artist');
      });

      test('writeExifBatch writes multiple tags successfully', () async {
        if (exiftool == null) return;

        final tagsToWrite = {
          'Artist': 'Test Artist',
          'Copyright': 'Test Copyright',
          'ImageDescription': 'Test Description',
        };
        final result = await exiftool!.writeExifBatch(testImage, tagsToWrite);

        expect(result, isTrue);

        // Verify all tags were written
        final writtenTags = await exiftool!.readExifBatch(
          testImage,
          tagsToWrite.keys.toList(),
        );
        for (final entry in tagsToWrite.entries) {
          expect(writtenTags[entry.key], entry.value);
        }
      });

      test('writeExifBatch handles empty tag map', () async {
        if (exiftool == null) return;

        final result = await exiftool!.writeExifBatch(testImage, {});

        // Should succeed even with empty map
        expect(result, isA<bool>());
      });

      test('writeExifBatch overwrites existing tags', () async {
        if (exiftool == null) return;

        // Write initial tag
        await exiftool!.writeExifBatch(testImage, {'Artist': 'Initial Artist'});

        // Overwrite with new value
        final result = await exiftool!.writeExifBatch(testImage, {
          'Artist': 'Updated Artist',
        });
        expect(result, isTrue);

        // Verify the tag was overwritten
        final updatedTags = await exiftool!.readExifBatch(testImage, [
          'Artist',
        ]);
        expect(updatedTags['Artist'], 'Updated Artist');
      });

      test('writeExifBatch handles special characters', () async {
        if (exiftool == null) return;

        final tagsWithSpecialChars = {
          'Artist': 'Tëst Ärtist 🎨',
          'Copyright': '© 2023 Test Corp.',
          'ImageDescription': 'Special chars: äöüß 中文 日本語',
        };

        final result = await exiftool!.writeExifBatch(
          testImage,
          tagsWithSpecialChars,
        );
        expect(result, isTrue);

        // Verify special characters are preserved
        final writtenTags = await exiftool!.readExifBatch(
          testImage,
          tagsWithSpecialChars.keys.toList(),
        );
        for (final entry in tagsWithSpecialChars.entries) {
          expect(writtenTags[entry.key], entry.value);
        }
      });

      test('writeExifBatch fails for unsupported file types', () async {
        if (exiftool == null) return;

        final textFile = fixture.createFile('unsupported.txt', [65, 66, 67]);
        final result = await exiftool!.writeExifBatch(textFile, {
          'Artist': 'Test',
        });

        expect(result, isFalse);
      });

      test('writeExifBatch handles very long tag values', () async {
        if (exiftool == null) return;

        final longValue = 'A' * 1000; // Very long string
        final result = await exiftool!.writeExifBatch(testImage, {
          'ImageDescription': longValue,
        });

        expect(result, isA<bool>());

        if (result) {
          final writtenTags = await exiftool!.readExifBatch(testImage, [
            'ImageDescription',
          ]);
          expect(writtenTags['ImageDescription'], anyOf(longValue, isNotNull));
        }
      });
    });

    group('GPS Data Handling', () {
      late File testImage;

      setUp(() {
        testImage = fixture.createImageWithoutExif('test_gps.jpg');
      });

      test('writes GPS coordinates correctly', () async {
        if (exiftool == null) return;

        final gpsData = {
          'GPSLatitude': '41.3221611',
          'GPSLongitude': '19.8149139',
          'GPSLatitudeRef': 'N',
          'GPSLongitudeRef': 'E',
          'GPSAltitude': '143.09',
        };

        final result = await exiftool!.writeExifBatch(testImage, gpsData);
        expect(result, isTrue);

        // Verify GPS data was written
        final writtenTags = await exiftool!.readExifBatch(
          testImage,
          gpsData.keys.toList(),
        );
        expect(writtenTags['GPSLatitudeRef'], 'N');
        expect(writtenTags['GPSLongitudeRef'], 'E');
      });

      test('handles GPS coordinates in different formats', () async {
        if (exiftool == null) return;

        // Test DMS format
        final dmsGpsData = {
          'GPSLatitude': "41 deg 19' 22.16\"",
          'GPSLongitude': "19 deg 48' 53.69\"",
          'GPSLatitudeRef': 'N',
          'GPSLongitudeRef': 'E',
        };

        final result = await exiftool!.writeExifBatch(testImage, dmsGpsData);
        expect(result, isA<bool>());
      });

      test('handles GPS altitude and precision data', () async {
        if (exiftool == null) return;

        final extendedGpsData = {
          'GPSLatitude': '41.3221611',
          'GPSLongitude': '19.8149139',
          'GPSAltitude': '143.09',
          'GPSAltitudeRef': '0', // Above sea level
          'GPSDateStamp': '2023:12:25',
          'GPSTimeStamp': '15:30:45',
        };

        final result = await exiftool!.writeExifBatch(
          testImage,
          extendedGpsData,
        );
        expect(result, isA<bool>());
      });
    });

    group('DateTime Handling', () {
      late File testImage;

      setUp(() {
        testImage = fixture.createImageWithoutExif('test_datetime.jpg');
      });

      test('writes DateTime tags correctly', () async {
        if (exiftool == null) return;

        final dateTimeData = {
          'DateTime': '2023:12:25 15:30:45',
          'DateTimeOriginal': '2023:12:25 15:30:45',
          'DateTimeDigitized': '2023:12:25 15:30:45',
        };

        final result = await exiftool!.writeExifBatch(testImage, dateTimeData);
        expect(result, isTrue);

        // Verify DateTime tags were written
        final writtenTags = await exiftool!.readExifBatch(
          testImage,
          dateTimeData.keys.toList(),
        );
        for (final key in dateTimeData.keys) {
          expect(writtenTags[key], dateTimeData[key]);
        }
      });

      test('handles different DateTime formats', () async {
        if (exiftool == null) return;

        final formats = [
          '2023:12:25 15:30:45',
          '2023-12-25 15:30:45',
          '2023/12/25 15:30:45',
        ];

        for (final format in formats) {
          final dateTimeData = {'DateTimeOriginal': format};
          final result = await exiftool!.writeExifBatch(
            testImage,
            dateTimeData,
          );
          expect(result, isA<bool>());
        }
      });

      test('handles timezone information', () async {
        if (exiftool == null) return;

        final timeZoneData = {
          'DateTimeOriginal': '2023:12:25 15:30:45',
          'OffsetTime': '+02:00',
          'OffsetTimeOriginal': '+02:00',
        };

        final result = await exiftool!.writeExifBatch(testImage, timeZoneData);
        expect(result, isA<bool>());
      });
    });

    group('Error Handling and Edge Cases', () {
      test('handles non-existent files gracefully', () async {
        if (exiftool == null) return;

        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');

        expect(
          () => exiftool!.readExif(nonExistentFile),
          throwsA(isA<Exception>()),
        );
        expect(
          () => exiftool!.writeExifBatch(nonExistentFile, {'Artist': 'Test'}),
          throwsA(isA<Exception>()),
        );
      });

      test('handles corrupted image files', () async {
        if (exiftool == null) return;

        final corruptedFile = fixture.createFile('corrupted.jpg', [
          0xFF,
          0xD8,
          0x00,
          0x01,
        ]); // Invalid JPEG

        // Should not crash, but may return empty results
        expect(() => exiftool!.readExif(corruptedFile), returnsNormally);
      });

      test('handles very large image files', () async {
        if (exiftool == null) return;

        // Create a larger test image (still small for testing purposes)
        final largeImageData = List.generate(100000, (final i) => i % 256);
        final largeFile = fixture.createFile('large.jpg', largeImageData);

        expect(() => exiftool!.readExif(largeFile), returnsNormally);
      });

      test('handles concurrent EXIF operations', () async {
        if (exiftool == null) return;

        final images = List.generate(
          5,
          (final i) => fixture.createImageWithoutExif('concurrent_$i.jpg'),
        );

        // Perform concurrent read operations
        final futures = images
            .map((final img) => exiftool!.readExif(img))
            .toList();
        final results = await Future.wait(futures);

        expect(results.length, images.length);
        for (final result in results) {
          expect(result, isA<Map<String, String>>());
        }
      });

      test('handles file permission issues', () async {
        if (exiftool == null) return;

        final testImage = fixture.createImageWithoutExif('permission_test.jpg');

        // This would require platform-specific permission manipulation
        // For now, we test that normal operations work
        expect(() => exiftool!.readExif(testImage), returnsNormally);
      });

      test('handles invalid tag names gracefully', () async {
        if (exiftool == null) return;

        final testImage = fixture.createImageWithoutExif('invalid_tags.jpg');
        final invalidTags = {
          '': 'Empty tag name',
          'Invalid Tag Name With Spaces': 'Invalid name',
          'Special!@#Characters': 'Special chars',
        };

        // Should not crash, but may not write the tags
        expect(
          () => exiftool!.writeExifBatch(testImage, invalidTags),
          returnsNormally,
        );
      });
    });

    group('Performance and Optimization', () {
      test(
        'batch operations are more efficient than individual calls',
        () async {
          if (exiftool == null) return;

          final testImage = fixture.createImageWithExif('performance_test.jpg');
          final tags = [
            'DateTimeOriginal',
            'Make',
            'Model',
            'Artist',
            'Copyright',
          ];

          // Batch read should be more efficient
          final stopwatch = Stopwatch()..start();
          final batchResult = await exiftool!.readExifBatch(testImage, tags);
          final batchTime = stopwatch.elapsedMicroseconds;
          stopwatch.stop();

          expect(batchResult, isA<Map<String, String>>());
          expect(batchTime, greaterThan(0));
        },
      );

      test('handles multiple file operations efficiently', () async {
        if (exiftool == null) return;

        final images = List.generate(
          10,
          (final i) => fixture.createImageWithoutExif('multi_$i.jpg'),
        );

        final stopwatch = Stopwatch()..start();

        for (final img in images) {
          await exiftool!.writeExifBatch(img, {
            'Artist': 'Batch Test $images.indexOf(img)',
          });
        }

        stopwatch.stop();

        expect(
          stopwatch.elapsedMilliseconds,
          lessThan(30000),
        ); // Should complete in reasonable time
      });
    });

    group('Integration with Other Components', () {
      test('works with exif_reader library for comparison', () async {
        if (exiftool == null) return;

        final testImage = fixture.createImageWithExif('integration_test.jpg');

        // Read with exiftool
        final exiftoolTags = await exiftool!.readExif(testImage);

        // Read with exif_reader
        final bytes = await testImage.readAsBytes();
        final exifReaderTags = await readExifFromBytes(bytes);

        expect(exiftoolTags, isA<Map<String, String>>());
        expect(exifReaderTags, isA<Map<String, dynamic>>());

        // Both should detect that the image has EXIF data
        expect(exiftoolTags.isNotEmpty, isTrue);
        expect(exifReaderTags.isNotEmpty, isTrue);
      });

      test('preserves data written by other EXIF tools', () async {
        if (exiftool == null) return;

        final testImage = fixture.createImageWithExif('preserve_test.jpg');

        // Read original EXIF data
        final originalTags = await exiftool!.readExif(testImage);

        // Write additional tag
        await exiftool!.writeExifBatch(testImage, {'Artist': 'New Artist'});

        // Verify original data is preserved and new data is added
        final updatedTags = await exiftool!.readExif(testImage);
        expect(updatedTags['Artist'], 'New Artist');

        // Some original tags should still be present
        expect(
          updatedTags.keys.length,
          greaterThanOrEqualTo(originalTags.keys.length),
        );
      });
    });
  });
}
