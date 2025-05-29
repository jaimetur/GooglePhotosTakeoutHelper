/// Test setup utilities for GPTH tests
/// This file contains common test data, fixtures, and helper functions
/// to make test initialization and maintenance easier.
library;

import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

/// Base64 encoded 1x1 green JPEG image with EXIF data
/// DateTime Original: 2022:12:16 16:06:47
const String greenImgBase64 = '''
/9j/4AAQSkZJRgABAQAAAQABAAD/4QC4RXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAAASgEbAAUA
AAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIdpAAQAAAABAAAAWgAAAAAAAAABAAAAAQAA
AAEAAAABAAWQAAAHAAAABDAyMzKQAwACAAAAFAAAAJyRAQAHAAAABAECAwCgAAAHAAAABDAxMDCg
AQADAAAAAf//AAAAAAAAMjAyMjoxMjoxNiAxNjowNjo0NwD/2wBDAAMCAgICAgMCAgIDAwMDBAYE
BAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQD
BAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ
EBD/wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAA
AAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAI/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwD
AQACEQMRAD8AIcgXf//Z''';

/// Base64 encoded 1x1 green JPEG image without EXIF metadata
const String greenImgNoMetaDataBase64 = '''
/9j/4AAQSkZJRgABAQAAAQABAAD/4QCYRXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAA
ASgEbAAUAAAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIdpAAQAAAABAAAAWgAAA
AAAAAABAAAAAQAAAAEAAAABAASQAAAHAAAABDAyMzKRAQAHAAAABAECAwCgAAAHAAAABDA
xMDCgAQADAAAAAf//AAAAAAAA/9sAQwADAgICAgIDAgICAwMDAwQGBAQEBAQIBgYFBgkIC
goJCAkJCgwPDAoLDgsJCQ0RDQ4PEBAREAoMEhMSEBMPEBAQ/9sAQwEDAwMEAwQIBAQIEAs
JCxAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ/
8AAEQgAAQABAwERAAIRAQMRAf/EABQAAQAAAAAAAAAAAAAAAAAAAAP/xAAUEAEAAAAAAAA
AAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAACP/EABQRAQAAAAAAAAAAAAAAAAAAA
AD/2gAMAwEAAhEDEQA/ACHIF3//2Q==''';

/// Test fixture class to manage test file creation and cleanup
class TestFixture {
  late String basePath;
  late Directory baseDir;
  final Set<FileSystemEntity> _createdEntities = {};

  /// Initialize the test fixture with a unique temporary directory
  Future<void> setUp() async {
    final String current = Directory.current.path;
    final String timestamp = DateTime.now().microsecondsSinceEpoch.toString();
    final String randomSuffix = DateTime.now().millisecondsSinceEpoch
        .toRadixString(36);
    basePath = p.join(
      current,
      'test',
      'generated',
      'fixture_${timestamp}_$randomSuffix',
    );
    baseDir = Directory(basePath);
    await baseDir.create(recursive: true);
    _createdEntities.add(baseDir);
  }

  /// Clean up all created files and directories
  Future<void> tearDown() async {
    // First, try to force-close any file handles
    await Future.delayed(const Duration(milliseconds: 100));

    // Reverse order to delete files before directories
    final entities = _createdEntities.toList().reversed.toList();

    for (final entity in entities) {
      await _safeDelete(entity);
    }
    _createdEntities.clear();
  }

  /// Safely delete a file system entity with retry logic
  Future<void> _safeDelete(final FileSystemEntity entity) async {
    const maxRetries = 3;
    for (int retry = 0; retry < maxRetries; retry++) {
      try {
        if (await entity.exists()) {
          if (entity is File) {
            await entity.delete();
          } else if (entity is Directory) {
            await _deleteDirectoryRecursively(entity);
          } else if (entity is Link) {
            await entity.delete();
          }
        }
        return; // Success, exit retry loop
      } catch (e) {
        if (retry == maxRetries - 1) {
          // Last retry, log but don't fail
          print(
            'Warning: Failed to delete ${entity.path} after $maxRetries attempts: $e',
          );
        } else {
          // Wait before retry
          await Future.delayed(Duration(milliseconds: 100 * (retry + 1)));
        }
      }
    }
  }

  /// Recursively delete directory contents and the directory itself
  Future<void> _deleteDirectoryRecursively(final Directory dir) async {
    try {
      // First, try to list and delete all contents
      final contents = await dir.list().toList();

      // Delete files first, then directories
      final files = contents.whereType<File>().toList();
      final links = contents.whereType<Link>().toList();
      final subdirs = contents.whereType<Directory>().toList();

      // Delete files and links
      for (final file in files) {
        await _safeDelete(file);
      }
      for (final link in links) {
        await _safeDelete(link);
      }

      // Delete subdirectories recursively
      for (final subdir in subdirs) {
        await _safeDelete(subdir);
      }

      // Finally delete the directory itself
      await dir.delete();
    } catch (e) {
      // If listing fails, try force deletion
      try {
        await dir.delete(recursive: true);
      } catch (e2) {
        // As last resort, try using platform-specific commands
        await _forceDeleteDirectory(dir);
      }
    }
  }

  /// Force delete directory using platform-specific commands
  Future<void> _forceDeleteDirectory(final Directory dir) async {
    try {
      if (Platform.isWindows) {
        await Process.run('rmdir', ['/s', '/q', dir.path]);
      } else {
        await Process.run('rm', ['-rf', dir.path]);
      }
    } catch (e) {
      // Final fallback - log the error but don't fail
      print('Warning: Could not force delete ${dir.path}: $e');
    }
  }

  /// Create a test image file with EXIF data
  File createImageWithExif(final String name) {
    final file = File(p.join(basePath, name));
    file.createSync(recursive: true);
    file.writeAsBytesSync(base64.decode(greenImgBase64.replaceAll('\n', '')));
    _createdEntities.add(file);
    return file;
  }

  /// Create a test image file without EXIF data
  File createImageWithoutExif(final String name) {
    final file = File(p.join(basePath, name));
    file.createSync(recursive: true);
    file.writeAsBytesSync(
      base64.decode(greenImgNoMetaDataBase64.replaceAll('\n', '')),
    );
    _createdEntities.add(file);
    return file;
  }

  /// Create a test file with custom content
  File createFile(final String name, final List<int> content) {
    final file = File(p.join(basePath, name));
    file.createSync(recursive: true);
    file.writeAsBytesSync(content);
    _createdEntities.add(file);
    return file;
  }

  /// Create a test directory
  Directory createDirectory(final String name) {
    final dir = Directory(p.join(basePath, name));
    dir.createSync(recursive: true);
    _createdEntities.add(dir);
    return dir;
  }

  /// Create a JSON file with test metadata
  File createJsonFile(final String name, final int timestamp) {
    final file = File(p.join(basePath, name));
    file.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'title': 'test.jpg',
        'description': '',
        'imageViews': '1',
        'creationTime': {
          'timestamp': '1702198242',
          'formatted': '10.12.2023, 08:50:42 UTC',
        },
        'photoTakenTime': {
          'timestamp': timestamp.toString(),
          'formatted': '01.05.2023, 14:32:37 UTC',
        },
        'geoData': {
          'latitude': 41.3221611,
          'longitude': 19.8149139,
          'altitude': 143.09,
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'geoDataExif': {
          'latitude': 41.3221611,
          'longitude': 19.8149139,
          'altitude': 143.09,
          'latitudeSpan': 0.0,
          'longitudeSpan': 0.0,
        },
        'archived': true,
        'url': 'https://photos.google.com/photo/xyz',
        'googlePhotosOrigin': {
          'mobileUpload': {'deviceType': 'IOS_PHONE'},
        },
      }),
    );
    _createdEntities.add(file);
    return file;
  }

  /// Create a test image file with EXIF data in a specific directory
  File createImageWithExifInDir(final String dirPath, final String name) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
      _createdEntities.add(dir);
    }

    final file = File(p.join(dirPath, name));
    file.createSync(recursive: true);
    file.writeAsBytesSync(base64.decode(greenImgBase64.replaceAll('\n', '')));
    _createdEntities.add(file);
    return file;
  }
}

/// Test data patterns for filename-based date extraction
final List<List<String>> testDatePatterns = [
  ['Screenshot_20190919-053857_Camera-edited.jpg', '2019-09-19 05:38:57'],
  ['MVIMG_20190215_193501.MP4', '2019-02-15 19:35:01'],
  ['Screenshot_2019-04-16-11-19-37-232_com.jpg', '2019-04-16 11:19:37'],
  ['signal-2020-10-26-163832.jpg', '2020-10-26 16:38:32'],
  ['VID_20220107_113306.mp4', '2022-01-07 11:33:06'],
  ['00004XTR_00004_BURST20190216172030.jpg', '2019-02-16 17:20:30'],
  ['00055IMG_00055_BURST20190216172030_COVER.jpg', '2019-02-16 17:20:30'],
  ['2016_01_30_11_49_15.mp4', '2016-01-30 11:49:15'],
  ['201801261147521000.jpg', '2018-01-26 11:47:52'],
  ['IMG_1_BURST20160623205107_COVER.jpg', '2016-06-23 20:51:07'],
  ['IMG_1_BURST20160520195318.jpg', '2016-05-20 19:53:18'],
  ['1990_06_16_07_30_00.jpg', '1990-06-16 07:30:00'],
  ['1869_12_30_16_59_57.jpg', '1869-12-30 16:59:57'],
];
