import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:exif/exif.dart';
import 'package:gpth/date_extractors/date_extractor.dart';
import 'package:gpth/exif_writer.dart';
import 'package:gpth/extras.dart';
import 'package:gpth/folder_classify.dart';
import 'package:gpth/grouping.dart';
import 'package:gpth/media.dart';
import 'package:gpth/moving.dart';
import 'package:gpth/utils.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart';
import 'package:test/test.dart';

void main() {
  /// this is 1x1 green jg image, with exif:
  /// DateTime Original: 2022:12:16 16:06:47
  const greenImgBase64 = """
/9j/4AAQSkZJRgABAQAAAQABAAD/4QC4RXhpZgAATU0AKgAAAAgABQEaAAUAAAABAAAASgEbAAUA
AAABAAAAUgEoAAMAAAABAAEAAAITAAMAAAABAAEAAIdpAAQAAAABAAAAWgAAAAAAAAABAAAAAQAA
AAEAAAABAAWQAAAHAAAABDAyMzKQAwACAAAAFAAAAJyRAQAHAAAABAECAwCgAAAHAAAABDAxMDCg
AQADAAAAAf//AAAAAAAAMjAyMjoxMjoxNiAxNjowNjo0NwD/2wBDAAMCAgICAgMCAgIDAwMDBAYE
BAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQD
BAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ
EBD/wAARCAABAAEDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAA//EABQQAQAAAAAAAAAA
AAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAI/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwD
AQACEQMRAD8AIcgXf//Z""";
  final String basepath = "/test/"; //Where the test files are created

  final albumDir = Directory('${basepath}Vacation');
  final imgFileGreen = File('${basepath}green.jpg');
  final imgFile1 = File('${basepath}image-edited.jpg');
  final jsonFile1 = File('${basepath}image-edited.jpg.json');
  // these names are from good old #8 issue...
  final imgFile2 =
      File('${basepath}Urlaub in Knaufspesch in der Schneifel (38).JPG');
  final jsonFile2 =
      File('${basepath}Urlaub in Knaufspesch in der Schneifel (38).JP.json');
  final imgFile3 =
      File('${basepath}Screenshot_2022-10-28-09-31-43-118_com.snapchat.jpg');
  final jsonFile3 =
      File('${basepath}Screenshot_2022-10-28-09-31-43-118_com.snapcha.json');
  final imgFile4 = File('${basepath}simple_file_20200101-edited.jpg');
  final imgFile4_1 = File('${basepath}simple_file_20200101-edited(1).jpg');
  final jsonFile4 = File('${basepath}simple_file_20200101.jpg.json');
  final imgFile5 = File('${basepath}img_(87).(vacation stuff).lol(87).jpg');
  final jsonFile5 =
      File('${basepath}img_(87).(vacation stuff).lol.jpg(87).json');
  final imgFile6 = File('${basepath}IMG-20150125-WA0003-modifié.jpg');
  final imgFile6_1 = File('${basepath}IMG-20150125-WA0003-modifié(1).jpg');
  final jsonFile6 = File('${basepath}IMG-20150125-WA0003.jpg.json');
  final media = [
    Media({null: imgFile1},
        dateTaken: DateTime(2020, 9, 1), dateTakenAccuracy: 1),
    Media(
      {albumName(albumDir): imgFile1},
      dateTaken: DateTime(2022, 9, 1),
      dateTakenAccuracy: 2,
    ),
    Media({null: imgFile2}, dateTaken: DateTime(2020), dateTakenAccuracy: 2),
    Media({null: imgFile3},
        dateTaken: DateTime(2022, 10, 28), dateTakenAccuracy: 1),
    Media({null: imgFile4}), // these two...
    // ...are duplicates
    Media({null: imgFile4_1}, dateTaken: DateTime(2019), dateTakenAccuracy: 3),
    Media({null: imgFile5}, dateTaken: DateTime(2020), dateTakenAccuracy: 1),
    Media({null: imgFile6}, dateTaken: DateTime(2015), dateTakenAccuracy: 1),
    Media({null: imgFile6_1}, dateTaken: DateTime(2015), dateTakenAccuracy: 1),
  ];

  /// Set up test stuff - create test shitty files in wherever pwd is
  /// We don't worry because we'll delete them later
  setUpAll(() {
    albumDir.createSync(recursive: true);
    imgFileGreen.createSync();
    imgFileGreen.writeAsBytesSync(
      base64.decode(greenImgBase64.replaceAll('\n', '')),
    );
    // apparently you don't need to .create() before writing 👍
    imgFile1.writeAsBytesSync([0, 1, 2]);
    imgFile1.copySync('${albumDir.path}/${basename(imgFile1.path)}');
    imgFile2.writeAsBytesSync([3, 4, 5]);
    imgFile3.writeAsBytesSync([6, 7, 8]);
    imgFile4.writeAsBytesSync([9, 10, 11]); // these two...
    imgFile4_1.writeAsBytesSync([9, 10, 11]); // ...are duplicates
    imgFile5.writeAsBytesSync([12, 13, 14]);
    imgFile6.writeAsBytesSync([15, 16, 17]);
    imgFile6_1.writeAsBytesSync([18, 19, 20]);
    writeJson(File file, int time) {
      file.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode({
        "title": "test.jpg",
        "description": "",
        "imageViews": "1",
        "creationTime": {
          "timestamp": "1702198242",
          "formatted": "10.12.2023, 08:50:42 UTC"
        },
        "photoTakenTime": {
          "timestamp": "$time",
          "formatted": "01.05.2023, 14:32:37 UTC"
        },
        "geoData": {
          "latitude": 41.3221611,
          "longitude": 19.8149139,
          "altitude": 143.09,
          "latitudeSpan": 0.0,
          "longitudeSpan": 0.0
        },
        "geoDataExif": {
          "latitude": 41.3221611,
          "longitude": 19.8149139,
          "altitude": 143.09,
          "latitudeSpan": 0.0,
          "longitudeSpan": 0.0
        },
        "archived": true,
        "url": "https://photos.google.com/photo/xyz",
        "googlePhotosOrigin": {
          "mobileUpload": {"deviceType": "IOS_PHONE"}
        }
      }));
    }

    writeJson(jsonFile1, 1599078832);
    writeJson(jsonFile2, 1683078832);
    writeJson(jsonFile3, 1666942303);
    writeJson(jsonFile4, 1683074444);
    writeJson(jsonFile5, 1680289442);
    writeJson(jsonFile6, 1422183600);
  });

  group('DateTime extractors', () {
    test('json', () async {
      expect((await jsonDateTimeExtractor(imgFile1))?.millisecondsSinceEpoch,
          1599078832 * 1000);
      expect((await jsonDateTimeExtractor(imgFile2))?.millisecondsSinceEpoch,
          1683078832 * 1000);
      expect((await jsonDateTimeExtractor(imgFile3))?.millisecondsSinceEpoch,
          1666942303 * 1000);
      // They *should* fail without tryhard
      // See b38efb5d / #175
      expect(
        (await jsonDateTimeExtractor(imgFile4))?.millisecondsSinceEpoch,
        1683074444 * 1000,
      );
      expect((await jsonDateTimeExtractor(imgFile4_1))?.millisecondsSinceEpoch,
          null);
      // Should work *with* tryhard
      expect(
        (await jsonDateTimeExtractor(imgFile4, tryhard: true))
            ?.millisecondsSinceEpoch,
        1683074444 * 1000,
      );
      expect(
        (await jsonDateTimeExtractor(imgFile4_1, tryhard: true))
            ?.millisecondsSinceEpoch,
        1683074444 * 1000,
      );
      expect(
        (await jsonDateTimeExtractor(imgFile5, tryhard: false))
            ?.millisecondsSinceEpoch,
        1680289442 * 1000,
      );
      expect(
        (await jsonDateTimeExtractor(imgFile6, tryhard: false))
            ?.millisecondsSinceEpoch,
        1422183600 * 1000,
      );
      expect(
        (await jsonDateTimeExtractor(imgFile6_1, tryhard: false))
            ?.millisecondsSinceEpoch,
        null,
      );
      expect(
        (await jsonDateTimeExtractor(imgFile6_1, tryhard: true))
            ?.millisecondsSinceEpoch,
        1422183600 * 1000,
      );
    });
    test('exif', () async {
      expect(
        (await exifDateTimeExtractor(imgFileGreen)),
        DateTime.parse('2022-12-16 16:06:47'),
      );
    });
    test('guess', () async {
      final files = [
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
      for (final f in files) {
        expect((await guessExtractor(File(f.first))), DateTime.parse(f.last));
      }
    });
  });
  test('Duplicate removal', () {
    expect(removeDuplicates(media, 40), 1);
    expect(media.length, 8);
    expect(media.firstWhereOrNull((e) => e.firstFile == imgFile4), null);
  });
  test('Extras removal', () {
    final m = [
      Media({null: imgFile1}),
      Media({null: imgFile2}),
    ];
    expect(removeExtras(m), 1);
    expect(m.length, 1);
  });
  test('Album finding', () {
    // sadly, this will still modify [media] some, but won't delete anything
    final copy = media.toList();
    removeDuplicates(copy, 40);

    final countBefore = copy.length;
    findAlbums(copy);
    expect(countBefore - copy.length, 1);

    final albumed = copy.firstWhere((e) => e.files.length > 1);
    expect(albumed.files.keys, [null, 'Vacation']);
    expect(albumed.dateTaken, media[0].dateTaken);
    expect(albumed.dateTaken == media[1].dateTaken, false); // be sure
    expect(copy.where((e) => e.files.length > 1).length, 1);
    // fails because Dart is no Rust :/
    // expect(media.where((e) => e.albums != null).length, 1);
  });
  group('Utils', () {
    test('Stream.whereType()', () {
      final stream = Stream.fromIterable([1, 'a', 2, 'b', 3, 'c']);
      expect(stream.whereType<int>(), emitsInOrder([1, 2, 3, emitsDone]));
    });
    test('Stream<FileSystemEntity>.wherePhotoVideo()', () {
      //    check if stream with random list of files is emitting only photos and videos
      //   use standard formats as jpg and mp4 but also rare ones like 3gp and eps
      final stream = Stream.fromIterable(<FileSystemEntity>[
        File('a.jpg'),
        File('lol.json'),
        File('b.mp4'),
        File('c.3gp'),
        File('e.png'),
        File('f.txt'),
      ]);
      expect(
        // looked like File()'s couldn't compare correctly :/
        stream.wherePhotoVideo().map((event) => event.path),
        emitsInOrder(['a.jpg', 'b.mp4', 'c.3gp', 'e.png', emitsDone]),
      );
    });
    test('findNotExistingName()', () {
      expect(findNotExistingName(imgFileGreen).path, '${basepath}green(1).jpg');
      expect(findNotExistingName(File('${basepath}not-here.jpg')).path,
          '${basepath}not-here.jpg');
    });
    test('getDiskFree()', () async {
      expect(await getDiskFree('.'), isNotNull);
    });
  });
  group('folder_classify', () {
    List<Directory> tmpdirs;
    if (Platform.isWindows) {
      tmpdirs = [
        Directory('./Photos from 2025'),
        Directory('./Photos from 1969'),
        Directory('./Photos from vacation'),
        Directory('C:/Windows/Temp/very-random-omg'),
      ];
    } else {
      tmpdirs = [
        Directory('./Photos from 2025'),
        Directory('./Photos from 1969'),
        Directory('./Photos from vacation'),
        Directory('/tmp/very-random-omg'),
      ];
    }
    final dirs = tmpdirs;
    setUpAll(() async {
      for (var d in dirs) {
        await d.create();
      }
    });
    test('is year/album folder', () async {
      expect(isYearFolder(dirs[0]), true);
      expect(isYearFolder(dirs[1]), true);
      expect(isYearFolder(dirs[2]), false);
      expect(await isAlbumFolder(dirs[2]), true);
      expect(await isAlbumFolder(dirs[3]), false);
    });
    tearDownAll(() async {
      for (var d in dirs) {
        await d.delete();
      }
    });
  });

  /// This is complicated, thus those test are not bullet-proof
  group('Moving logic', () {
    final output =
        Directory(join(Directory.systemTemp.path, '${basepath}testy-output'));
    setUp(() async {
      await output.create();
      removeDuplicates(media, 40);
      findAlbums(media);
    });
    test('shortcut', () async {
      await moveFiles(
        media,
        output,
        copy: true,
        divideToDates: 0,
        albumBehavior: 'shortcut',
      ).toList();
      final outputted =
          await output.list(recursive: true, followLinks: false).toSet();
      // 2 folders + media + 1 album-ed shortcut
      expect(outputted.length, 2 + media.length + 1);
      if (Platform.isWindows) {
        expect(
          outputted
              .whereType<File>()
              .where((file) => file.path.endsWith('.lnk'))
              .length,
          1,
        );
      } else {
        expect(outputted.whereType<Link>().length, 1);
      }

      expect(
        outputted.whereType<Directory>().map((e) => basename(e.path)).toSet(),
        {'ALL_PHOTOS', 'Vacation'},
      );
    });
    test('nothing', () async {
      await moveFiles(
        media,
        output,
        copy: true,
        divideToDates: 0,
        albumBehavior: 'nothing',
      ).toList();
      final outputted =
          await output.list(recursive: true, followLinks: false).toSet();
      // 1 folder + media
      expect(outputted.length, 1 + media.length);
      expect(outputted.whereType<Link>().length, 0);
      expect(outputted.whereType<Directory>().length, 1);
      expect(
        outputted.whereType<Directory>().map((e) => basename(e.path)).toSet(),
        {'ALL_PHOTOS'},
      );
    });
    test('duplicate-copy', () async {
      await moveFiles(
        media,
        output,
        copy: true,
        divideToDates: 0,
        albumBehavior: 'duplicate-copy',
      ).toList();
      final outputted =
          await output.list(recursive: true, followLinks: false).toSet();
      // 2 folders + media + 1 album-ed copy
      expect(outputted.length, 2 + media.length + 1);
      expect(outputted.whereType<Link>().length, 0);
      expect(outputted.whereType<Directory>().length, 2);
      expect(outputted.whereType<File>().length, media.length + 1);
      expect(
        UnorderedIterableEquality<String>().equals(
          outputted.whereType<File>().map((e) => basename(e.path)),
          [
            "image-edited.jpg",
            "image-edited.jpg", // two times
            "Screenshot_2022-10-28-09-31-43-118_com.snapchat.jpg",
            "simple_file_20200101-edited(1).jpg",
            "Urlaub in Knaufspesch in der Schneifel (38).JPG",
            "img_(87).(vacation stuff).lol(87).jpg",
            "IMG-20150125-WA0003-modifié.jpg",
            "IMG-20150125-WA0003-modifié(1).jpg",
          ],
        ),
        true,
      );
      expect(
        outputted.whereType<Directory>().map((e) => basename(e.path)).toSet(),
        {'ALL_PHOTOS', 'Vacation'},
      );
    });

    test('json', () async {
      await moveFiles(
        media,
        output,
        copy: true,
        divideToDates: 0,
        albumBehavior: 'json',
      ).toList();
      final outputted =
          await output.list(recursive: true, followLinks: false).toSet();
      // 1 folder + media + 1 json
      expect(outputted.length, 1 + media.length + 1);
      expect(outputted.whereType<Link>().length, 0);
      expect(outputted.whereType<Directory>().length, 1);
      expect(outputted.whereType<File>().length, media.length + 1);
      expect(
        UnorderedIterableEquality<String>().equals(
          outputted.whereType<File>().map((e) => basename(e.path)),
          [
            "image-edited.jpg",
            "Screenshot_2022-10-28-09-31-43-118_com.snapchat.jpg",
            "simple_file_20200101-edited(1).jpg",
            "Urlaub in Knaufspesch in der Schneifel (38).JPG",
            "albums-info.json",
            "img_(87).(vacation stuff).lol(87).jpg",
            "IMG-20150125-WA0003-modifié.jpg",
            "IMG-20150125-WA0003-modifié(1).jpg",
          ],
        ),
        true,
      );
      expect(
        outputted.whereType<Directory>().map((e) => basename(e.path)).toSet(),
        {'ALL_PHOTOS'},
      );
    });
    tearDown(() async => await output.delete(recursive: true));
  });

  group('writeGpsToExif', () {
    late File testImage;
    late DMSCoordinates testCoordinates;

    setUp(() {
      // Create a temporary test image file
      testImage = File('${basepath}test_image.jpg');
      testImage.writeAsBytesSync(encodeJpg(
          Image(width: 100, height: 100))); // Create a blank JPG image

      // Define test GPS coordinates
      testCoordinates = DMSCoordinates(
          latDegrees: 41,
          latMinutes: 19,
          latSeconds: 22.1611,
          longDegrees: 19,
          longMinutes: 48,
          longSeconds: 14.9139,
          latDirection: DirectionY.north,
          longDirection: DirectionX.east);
    });

    tearDown(() {
      // Clean up the test image file
      if (testImage.existsSync()) {
        testImage.deleteSync();
      }
    });

    test('writes GPS coordinates to EXIF metadata', () async {
      final result = await writeGpsToExif(testCoordinates, testImage);

      // Verify that the function returns true
      expect(result, isTrue);

      // Verify that the GPS coordinates were written to the EXIF metadata
      final tags = await readExifFromFile(testImage);

      expect(tags['GPS GPSLatitude'], isNotNull);
      expect(tags['GPS GPSLongitude'], isNotNull);
      expect(tags['GPS GPSLatitudeRef']!.printable, 'N');
      expect(tags['GPS GPSLongitudeRef']!.printable, 'E');
    });

    test('returns false for unsupported file formats', () async {
      // Create a non-supported file format (e.g., a text file)
      final unsupportedFile = File('${basepath}test_file.txt');
      unsupportedFile.writeAsStringSync('This is a test file.');

      final result = await writeGpsToExif(testCoordinates, unsupportedFile);

      // Verify that the function returns false
      expect(result, isFalse);

      // Clean up the unsupported file
      unsupportedFile.deleteSync();
    });

    test('returns false for files with existing GPS EXIF data', () async {
      // Simulate a file with existing GPS EXIF data
      final image = decodeJpg(testImage.readAsBytesSync());
      image!.exif.gpsIfd.gpsLatitude = testCoordinates.latSeconds;
      image.exif.gpsIfd.gpsLongitude = testCoordinates.longSeconds;
      final newBytes = encodeJpg(image);
      testImage.writeAsBytesSync(newBytes);

      final result = await writeGpsToExif(testCoordinates, testImage);

      // Verify that the function returns false
      expect(result, isFalse);
    });

    test('returns false for invalid image files', () async {
      // Create a corrupted image file
      testImage.writeAsBytesSync([0, 1, 2, 3, 4]);

      final result = await writeGpsToExif(testCoordinates, testImage);

      // Verify that the function returns false
      expect(result, isFalse);
    });
  });

  group('writeDateTimeToExif', () {
    late File testImage;
    late DateTime testDateTime;

    setUp(() {
      // Create a temporary test image file
      testImage = File('${basepath}test_image.jpg');
      testImage.writeAsBytesSync(encodeJpg(
          Image(width: 100, height: 100))); // Create a blank JPG image

      // Define a test DateTime
      testDateTime =
          DateTime(2023, 12, 25, 15, 30, 45); // Christmas Day, 3:30:45 PM
    });

    tearDown(() {
      // Clean up the test image file
      if (testImage.existsSync()) {
        testImage.deleteSync();
      }
    });

    test('writes DateTime to EXIF metadata', () async {
      final result = await writeDateTimeToExif(testDateTime, testImage);

      // Verify that the function returns true
      expect(result, isTrue);

      // Verify that the DateTime was written to the EXIF metadata
      final bytes = await testImage.readAsBytes();
      final tags = await readExifFromBytes(bytes);

      final exifFormat = DateFormat("yyyy:MM:dd HH:mm:ss");
      final expectedDateTime = exifFormat.format(testDateTime);

      expect(tags['Image DateTime']!.printable, expectedDateTime);
      expect(tags['EXIF DateTimeOriginal']!.printable, expectedDateTime);
      expect(tags['EXIF DateTimeDigitized']!.printable, expectedDateTime);
    });

    test('returns false for unsupported file formats', () async {
      // Create a non-supported file format (e.g., a text file)
      final unsupportedFile = File('test_file.txt');
      unsupportedFile.writeAsStringSync('This is a test file.');

      final result = await writeDateTimeToExif(testDateTime, unsupportedFile);

      // Verify that the function returns false
      expect(result, isFalse);

      // Clean up the unsupported file
      unsupportedFile.deleteSync();
    });

    test('returns false for files with existing DateTime EXIF data', () async {
      // Simulate a file with existing DateTime EXIF data
      final image = decodeJpg(testImage.readAsBytesSync());
      final exifFormat = DateFormat("yyyy:MM:dd HH:mm:ss");
      final existingDateTime =
          exifFormat.format(DateTime(2020, 1, 1, 12, 0, 0));
      image!.exif.imageIfd['DateTime'] = existingDateTime;
      image.exif.exifIfd['DateTimeOriginal'] = existingDateTime;
      image.exif.exifIfd['DateTimeDigitized'] = existingDateTime;
      final newBytes = encodeJpg(image);
      testImage.writeAsBytesSync(newBytes);

      final result = await writeDateTimeToExif(testDateTime, testImage);

      // Verify that the function returns false
      expect(result, isFalse);
    });

    test('returns false for invalid image files', () async {
      // Create a corrupted image file
      testImage.writeAsBytesSync([0, 1, 2, 3, 4]);

      final result = await writeDateTimeToExif(testDateTime, testImage);

      // Verify that the function returns false
      expect(result, isFalse);
    });
  });

  /// Delete all shitty files as we promised
  tearDownAll(() {
    albumDir.deleteSync(recursive: true);
    imgFileGreen.deleteSync();
    imgFile1.deleteSync();
    imgFile2.deleteSync();
    imgFile3.deleteSync();
    imgFile4.deleteSync();
    imgFile4_1.deleteSync();
    imgFile5.deleteSync();
    imgFile6.deleteSync();
    imgFile6_1.deleteSync();
    jsonFile1.deleteSync();
    jsonFile2.deleteSync();
    jsonFile3.deleteSync();
    jsonFile4.deleteSync();
    jsonFile5.deleteSync();
    jsonFile6.deleteSync();
  });
}
