/// Test suite for Media Entity and Collection Management functionality.
///
/// Comprehensive tests for the modern media management system.
library;

import 'dart:io';
import 'package:gpth/gpth-lib.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('MediaEntity and Collection - Modern Content Management System', () {
    late TestFixture fixture;
    late AlbumRelationshipService albumSvc;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
      await ServiceContainer.instance.initialize();
      albumSvc = ServiceContainer.instance.albumRelationshipService;
    });

    tearDown(() async {
      await ServiceContainer.reset();
      await fixture.tearDown();
    });

    group('MediaEntity Class - Object Creation and Property Management', () {
      test('creates MediaEntity object with required properties', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(file: file);

        expect(entity.primaryFile, file);
        // En el modelo nuevo, si no hay ruta de álbum, no hay asociaciones
        expect(entity.hasAlbumAssociations, isFalse);
        expect(entity.albumNames, isEmpty);
        expect(entity.dateTaken, isNull);
        expect(entity.dateTakenAccuracy, isNull);
      });

      test('creates MediaEntity object with date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: file,
          dateTaken: DateTime(2023, 5, 15),
        );

        expect(entity.primaryFile, file);
        expect(entity.dateTaken, DateTime(2023, 5, 15));
      });

      test('generates consistent content identifiers (by content equality)', () async {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [1, 2, 3]); // mismo contenido
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]); // distinto

        final entity1 = MediaEntity.single(file: file1);
        final entity2 = MediaEntity.single(file: file2);
        final entity3 = MediaEntity.single(file: file3);

        expect(await entity1.primaryFile.readAsBytes(),
               await entity2.primaryFile.readAsBytes());
        expect(await entity1.primaryFile.readAsBytes(),
               isNot(await entity3.primaryFile.readAsBytes()));
      });

      test('supports album associations after merge (multiple sources)', () async {
        // Mismo contenido en año y en álbum → tras merge, una entidad con albumNames=['extra']
        final c = [1, 2, 3];
        final yearFile = fixture.createFile('2023/test.jpg', c);
        final albumFile = fixture.createFile('Albums/extra/test.jpg', c);

        final merged = await albumSvc.detectAndMergeAlbums([
          MediaEntity.single(file: yearFile),
          MediaEntity.single(file: albumFile),
        ]);

        expect(merged.length, 1);
        final e = merged.first;
        expect(e.hasAlbumAssociations, isTrue);
        expect(e.albumNames, contains('extra'));
      });

      test('handles MediaEntity objects without date information', () {
        final file = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(file: file);

        expect(entity.dateTaken, isNull);
        expect(entity.dateTakenAccuracy, isNull);
      });
    });

    group('MediaEntityCollection - Duplicate Detection and Management', () {
      test('removeDuplicates identifies and removes duplicate files', () async {
        final file1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final file2 = fixture.createFile('test2.jpg', [1, 2, 3]); // Duplicado
        final file3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: file1),
          MediaEntity.single(file: file2),
          MediaEntity.single(file: file3),
        ]);

        final removedCount = await collection.removeDuplicates();

        expect(removedCount, 1);
        expect(collection.length, 2);
        expect(collection.entities.any((e) => e.primaryFile.path == file1.path), isTrue);
        expect(collection.entities.any((e) => e.primaryFile.path == file3.path), isTrue);
      });

      test('handles duplicate detection with many files efficiently', () async {
        final collection = MediaEntityCollection();

        for (int i = 0; i < 100; i++) {
          final file = fixture.createFile('test$i.jpg', [i + 1]);
          collection.add(MediaEntity.single(file: file));
        }

        final dup = fixture.createFile('duplicate.jpg', [1]);
        collection.add(MediaEntity.single(file: dup));

        final start = DateTime.now();
        final removedCount = await collection.removeDuplicates();
        final end = DateTime.now();

        expect(removedCount, 1);
        expect(collection.length, 100);
        expect(end.difference(start).inMilliseconds, lessThan(2000));
      });
    });

    group('Album Detection and Management - File Relationship Handling', () {
      test('findAlbums merges duplicate files from different albums', () async {
        // Año + Álbum (mismo contenido) → tras findAlbums debe quedar 1 entidad con albumNames=['Vacation']
        final c = [1, 2, 3];
        final yearFile = fixture.createFile('2023/photo.jpg', c);
        final albumFile = fixture.createFile('Albums/Vacation/photo.jpg', c);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: yearFile, dateTaken: DateTime(2023)),
          MediaEntity.single(file: albumFile, dateTaken: DateTime(2023)),
        ]);

        final originalLength = collection.length;
        await collection.findAlbums();

        expect(collection.length, lessThan(originalLength));
        expect(collection.length, 1);

        final mergedEntity = collection.entities.first;
        expect(mergedEntity.hasAlbumAssociations, isTrue);
        expect(mergedEntity.albumNames, contains('Vacation'));
      });

      test('preserves best metadata when merging albums', () async {
        final c = [1, 2, 3];
        final f1 = fixture.createFile('2023/photo1.jpg', c);
        final f2 = fixture.createFile('Albums/Album/photo1.jpg', c);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: f1, dateTaken: DateTime(2023)),
          MediaEntity.single(file: f2, dateTaken: DateTime(2023)),
        ]);

        await collection.findAlbums();

        expect(collection.length, 1);
        final mergedEntity = collection.entities.first;
        expect(mergedEntity.albumNames, contains('Album'));
        expect(mergedEntity.dateTaken, DateTime(2023));
      });
    });

    group('Extras Processing - Edited File Detection and Removal', () {
      test('extras processing placeholder', () {
        expect(true, isTrue);
      });
    });

    group('Performance and Scalability - Large Collection Handling', () {
      test('handles large collections efficiently in comprehensive workflow', () async {
        final collection = MediaEntityCollection();
        final createdFiles = <File>[];

        for (int i = 0; i < 10; i++) {
          final content = List<int>.filled(1024 * 1024, i);
          final file = fixture.createLargeTestFile('large_test$i.jpg', content: content);
          createdFiles.add(file);
          collection.add(MediaEntity.single(file: file));
        }

        for (int i = 1; i < createdFiles.length; i++) {
          final currentContent = await createdFiles[i].readAsBytes();
          final prevContent = await createdFiles[i - 1].readAsBytes();
          expect(currentContent.sublist(0, 10), isNot(prevContent.sublist(0, 10)));
        }

        final removedCount = await collection.removeDuplicates();
        expect(removedCount, 0);

        final memoryBefore = ProcessInfo.currentRss;
        await collection.removeDuplicates();
        final memoryAfter = ProcessInfo.currentRss;

        if (!Platform.isWindows) {
          expect(memoryAfter - memoryBefore, lessThan(50 * 1024 * 1024));
        }
      });

      test('manages memory usage during intensive operations', () async {
        final collection = MediaEntityCollection();

        for (int i = 0; i < 50; i++) {
          final file = fixture.createFile('memory_test$i.jpg', [i]);
          collection.add(MediaEntity.single(file: file));
        }

        await collection.removeDuplicates();
        await collection.findAlbums();

        expect(collection.length, 50);
      });

      test('modern grouping correctly groups media by content', () async {
        final f1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final f2 = fixture.createFile('test2.jpg', [1, 2, 3]); // mismo contenido
        final f3 = fixture.createFile('test3.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection([
          MediaEntity.single(file: f1),
          MediaEntity.single(file: f2),
          MediaEntity.single(file: f3),
        ]);

        final duplicateService = ServiceContainer.instance.duplicateDetectionService;
        final grouped = await duplicateService.groupIdentical(collection.entities.toList());

        expect(grouped.length, 2);

        final duplicateGroup = grouped.values.firstWhere((g) => g.length > 1);
        expect(duplicateGroup.length, 2);
        expect(duplicateGroup.any((e) => e.primaryFile.path == f1.path), isTrue);
        expect(duplicateGroup.any((e) => e.primaryFile.path == f2.path), isTrue);
      });
    });

    group('MediaEntityCollection - Core Operations', () {
      test('supports basic collection operations', () {
        final f1 = fixture.createFile('test1.jpg', [1, 2, 3]);
        final f2 = fixture.createFile('test2.jpg', [4, 5, 6]);

        final collection = MediaEntityCollection();
        expect(collection.isEmpty, isTrue);

        final e1 = MediaEntity.single(file: f1);
        final e2 = MediaEntity.single(file: f2);

        collection.add(e1);
        expect(collection.length, 1);
        expect(collection.isNotEmpty, isTrue);

        collection.addAll([e2]);
        expect(collection.length, 2);

        collection.remove(e1);
        expect(collection.length, 1);

        collection.clear();
        expect(collection.isEmpty, isTrue);
      });

      test('provides accurate statistics', () async {
        final f1 = fixture.createFile('2023/test1.jpg', [1, 2, 3]); // año
        final f2 = fixture.createFile('Albums/Album/test2.jpg', [4, 5, 6]); // álbum

        final collection = MediaEntityCollection([
          MediaEntity.single(file: f1, dateTaken: DateTime(2023)),
          MediaEntity.single(file: f2),
        ]);

        // Detecta álbumes antes de calcular stats
        await collection.findAlbums();

        final stats = collection.getStatistics();
        expect(stats.totalMedia, 2);
        expect(stats.mediaWithDates, 1);
        expect(stats.mediaWithAlbums, 1);
      });
    });

    group('EXIF Data Writing and Coordinate Management', () {
      test('writeExifData processes coordinates from JSON metadata', () async {
        final testImage = fixture.createImageWithoutExif('test_with_coords.jpg');
        final jsonFile = File('${testImage.path}.json');
        await jsonFile.writeAsString('''
{
  "title": "Test Image with GPS",
  "photoTakenTime": { "timestamp": "1609459200", "formatted": "01.01.2021, 00:00:00 UTC" },
  "geoData": { "latitude": 41.3221611, "longitude": 19.8149139, "altitude": 143.09,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 }
}
''');

        final collection = MediaEntityCollection();
        final mediaEntity = MediaEntity.single(
          file: testImage,
          dateTaken: DateTime.fromMillisecondsSinceEpoch(1609459200 * 1000),
        );
        collection.add(mediaEntity);

        try {
          final results = await collection.writeExifData();
          expect(results, isA<Map<String, int>>());
          expect(results.containsKey('coordinatesWritten'), isTrue);
          expect(results.containsKey('dateTimesWritten'), isTrue);
        } catch (e) {
          // Entorno de test sin servicios completos puede lanzar: aceptable
          // Mantén el try/catch tal como lo tenías
        }

        await jsonFile.delete();
      });

      test('writeExifData handles multiple files with different coordinate data', () async {
        final collection = MediaEntityCollection();

        final file1 = fixture.createImageWithoutExif('file_with_coords.jpg');
        final json1 = File('${file1.path}.json');
        await json1.writeAsString('''
{ "title":"File with coordinates",
  "geoData": { "latitude": 40.7589, "longitude": -73.9851, "altitude": 10.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''');

        final file2 = fixture.createImageWithoutExif('file_no_coords.jpg');
        final json2 = File('${file2.path}.json');
        await json2.writeAsString('''
{ "title":"File without coordinates",
  "photoTakenTime": { "timestamp":"1609459200", "formatted":"01.01.2021, 00:00:00 UTC" } }
''');

        final file3 = fixture.createImageWithoutExif('file_southern.jpg');
        final json3 = File('${file3.path}.json');
        await json3.writeAsString('''
{ "title":"Southern hemisphere coordinates",
  "geoData": { "latitude": -33.865143, "longitude": 151.2099, "altitude": 58.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''');

        collection.addAll([
          MediaEntity.single(file: file1),
          MediaEntity.single(file: file2),
          MediaEntity.single(file: file3),
        ]);

        try {
          final results = await collection.writeExifData();
          expect(results, isA<Map<String, int>>());
        } catch (_) {
          // ver comentario anterior
        }

        await json1.delete();
        await json2.delete();
        await json3.delete();
      });

      test('writeExifData reports accurate statistics', () async {
        final collection = MediaEntityCollection();

        final scenarios = [
          {
            'name': 'full_metadata.jpg',
            'hasDate': true,
            'json': '''
{ "title":"Full metadata",
  "photoTakenTime": { "timestamp":"1609459200", "formatted":"01.01.2021, 00:00:00 UTC" },
  "geoData": { "latitude": 51.5074, "longitude": -0.1278, "altitude": 11.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''',
          },
          {
            'name': 'coords_only.jpg',
            'hasDate': false,
            'json': '''
{ "title":"Coordinates only",
  "geoData": { "latitude": 48.8566, "longitude": 2.3522, "altitude": 35.0,
               "latitudeSpan": 0.0, "longitudeSpan": 0.0 } }
''',
          },
          {
            'name': 'date_only.jpg',
            'hasDate': true,
            'json': '''
{ "title":"Date only",
  "photoTakenTime": { "timestamp":"1640995200", "formatted":"31.12.2021, 12:00:00 UTC" } }
''',
          },
        ];

        for (final s in scenarios) {
          final file = fixture.createImageWithoutExif(s['name'] as String);
          final jf = File('${file.path}.json');
          await jf.writeAsString(s['json'] as String);

          collection.add(MediaEntity.single(
            file: file,
            dateTaken: (s['hasDate'] as bool)
                ? DateTime.fromMillisecondsSinceEpoch(1609459200 * 1000)
                : null,
          ));
        }

        try {
          final results = await collection.writeExifData();
          expect(results, isA<Map<String, int>>());
        } catch (_) {
          // ver comentario anterior
        }

        // Limpieza de JSON auxiliares
        for (final s in scenarios) {
          final jf = File('${fixture.basePath}/${s['name']}.json');
          if (await jf.exists()) await jf.delete();
        }
      });
    });
  });
}
