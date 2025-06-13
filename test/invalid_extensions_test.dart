library;

import 'dart:io';

import 'package:gpth/exiftoolInterface.dart';
import 'package:gpth/utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import './test_setup.dart';

void main() {
  group('Invalid extensions', () {
    late TestFixture fixture;

    setUpAll(() async {
      await initExiftool();
    });

    tearDownAll(() async {
      await cleanupExiftool();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });
    test('fix invalid .jpg extension', () async {
      // Create PNG file with incorrect .jpg extension
      final pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      final imgFile1 = fixture.createFile('actual-png.jpg', pngHeader);

      // Create corresponding JSON metadata file
      final jsonFile = fixture.createJsonFile(
        'actual-png.jpg.json',
        1672531237,
      );

      final albumDir = fixture.createDirectory('extensions-tests');
      final albumFile1 = File('${albumDir.path}/${p.basename(imgFile1.path)}');
      final albumJsonFile = File(
        '${albumDir.path}/${p.basename(jsonFile.path)}',
      );

      // Move both files to the test directory
      await imgFile1.rename(albumFile1.path);
      await jsonFile.rename(albumJsonFile.path);

      // Wait for filesystem operations to complete
      await Future.delayed(const Duration(milliseconds: 100));

      // Verify files exist before running extension fix
      expect(await albumFile1.exists(), isTrue);
      expect(await albumJsonFile.exists(), isTrue);

      final fixedCount = await fixIncorrectExtensions(albumDir, null);

      final fixedFile = File('${albumDir.path}/actual-png.jpg.png');
      final fixedJsonFile = File('${albumDir.path}/actual-png.jpg.png.json');

      expect(fixedCount, greaterThan(0));
      expect(await fixedFile.exists(), isTrue);
      expect(await fixedJsonFile.exists(), isTrue);
    });

    test('skip invalid JPEG files', () async {
      final jpegHeader = [0xFF, 0xD8];
      final imgFile1 = fixture.createFile('actual-jpeg.png', jpegHeader);

      final albumDir = fixture.createDirectory('extensions-tests');
      final albumFile1 = File('${albumDir.path}/${p.basename(imgFile1.path)}');
      imgFile1.renameSync(albumFile1.path);

      await fixIncorrectExtensions(albumDir, true); // non-jpeg mode

      final fixedFile = File(
        '${albumDir.path}/${p.basename(imgFile1.path)}.jpg',
      );
      expect(fixedFile.existsSync(), isFalse);
    });

    test('skip TIFF-based RAW files', () async {
      final cr2Header = [
        0x49,
        0x49,
        0x2A,
        0x00,
        0x10,
        0x00,
        0x00,
        0x00,
        0x43,
        0x52,
        0x02,
      ];
      final imgFile1 = fixture.createFile('actual-raw.CR2', cr2Header);

      final albumDir = fixture.createDirectory('extensions-tests');
      final albumFile1 = File('${albumDir.path}/${p.basename(imgFile1.path)}');
      imgFile1.renameSync(albumFile1.path);

      await fixIncorrectExtensions(albumDir, false);

      final fixedFile = File(
        '${albumDir.path}/${p.basename(imgFile1.path)}.tiff',
      );
      expect(fixedFile.existsSync(), isFalse);
    });
  });
}
