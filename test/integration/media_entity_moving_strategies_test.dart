/// Test suite for MediaEntity moving strategies
///
/// Tests the complete implementation of all album behavior strategies including
/// shortcut, duplicate-copy, reverse-shortcut, json, and nothing modes.
// ignore_for_file: prefer_foreach

library;

import 'dart:convert';
import 'dart:io';
import 'package:gpth/gpth-lib.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('MediaEntity Moving Strategies', () {
    late TestFixture fixture;
    late FileOperationService fileService;
    late PathGeneratorService pathService;
    late SymlinkService symlinkService;
    late Directory outputDir;
    late MovingContext context;
    late AlbumRelationshipService albumSvc;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      // Initialize ServiceContainer
      await ServiceContainer.instance.initialize();
      albumSvc = ServiceContainer.instance.albumRelationshipService;

      fileService = FileOperationService();
      pathService = PathGeneratorService();
      symlinkService = SymlinkService();

      outputDir = fixture.createDirectory('output');
      context = MovingContext(
        outputDirectory: outputDir,
        dateDivision: DateDivisionLevel.year,
        albumBehavior: AlbumBehavior.shortcut,
      );
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    group('MediaEntityMovingStrategyFactory', () {
      late MediaEntityMovingStrategyFactory factory;

      setUp(() {
        factory = MediaEntityMovingStrategyFactory(
          fileService,
          pathService,
          symlinkService,
        );
      });

      test('creates shortcut strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.shortcut);
        expect(strategy, isA<ShortcutMovingStrategy>());
        expect(strategy.name, equals('Shortcut'));
        expect(strategy.createsShortcuts, isTrue);
        expect(strategy.createsDuplicates, isFalse);
      });

      test('creates duplicate-copy strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.duplicateCopy);
        expect(strategy, isA<DuplicateCopyMovingStrategy>());
        expect(strategy.name, equals('Duplicate Copy'));
        expect(strategy.createsShortcuts, isFalse);
        expect(strategy.createsDuplicates, isTrue);
      });

      test('creates reverse-shortcut strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.reverseShortcut);
        expect(strategy, isA<ReverseShortcutMovingStrategy>());
        expect(strategy.name, equals('Reverse Shortcut'));
        expect(strategy.createsShortcuts, isTrue);
        expect(strategy.createsDuplicates, isFalse);
      });

      test('creates json strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.json);
        expect(strategy, isA<JsonMovingStrategy>());
        expect(strategy.name, equals('JSON'));
        expect(strategy.createsShortcuts, isFalse);
        expect(strategy.createsDuplicates, isFalse);
      });

      test('creates nothing strategy', () {
        final strategy = factory.createStrategy(AlbumBehavior.nothing);
        expect(strategy, isA<NothingMovingStrategy>());
        expect(strategy.name, equals('Nothing'));
        expect(strategy.createsShortcuts, isFalse);
        expect(strategy.createsDuplicates, isFalse);
      });
    });

    group('ShortcutMovingStrategy', () {
      late ShortcutMovingStrategy strategy;

      setUp(() {
        strategy = ShortcutMovingStrategy(
          fileService,
          pathService,
          symlinkService,
        );
      });

      test('moves file to ALL_PHOTOS and creates album shortcuts', () async {
        // Mismo contenido en año y en álbum → tras merge habrá 1 entidad con albumNames=['Vacation']
        final content = [1, 2, 3];
        final yearFile = fixture.createFile('2023/test.jpg', content);
        final albumFile = fixture.createFile('Albums/Vacation/test.jpg', content);

        final merged = await albumSvc.detectAndMergeAlbums([
          MediaEntity.single(file: yearFile, dateTaken: DateTime(2023, 6, 15)),
          MediaEntity.single(file: albumFile, dateTaken: DateTime(2023, 6, 15)),
        ]);
        final entity = merged.single;

        final results = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(2)); // Move + symlink
        expect(results[0].success, isTrue);
        expect(results[0].operation.operationType, equals(MediaEntityOperationType.move));
        expect(results[1].success, isTrue);
        expect(results[1].operation.operationType, equals(MediaEntityOperationType.createSymlink));

        final allPhotosPath = p.join(outputDir.path, 'ALL_PHOTOS', '2023');
        expect(Directory(allPhotosPath).existsSync(), isTrue);
      });

      test('handles entity without album associations', () async {
        final sourceFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: sourceFile,
          dateTaken: DateTime(2023, 6, 15),
        );

        final results = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1)); // Only move
        expect(results[0].success, isTrue);
        expect(results[0].operation.operationType, equals(MediaEntityOperationType.move));
      });
    });

    group('DuplicateCopyMovingStrategy', () {
      late DuplicateCopyMovingStrategy strategy;

      setUp(() {
        strategy = DuplicateCopyMovingStrategy(fileService, pathService);
      });

      test('moves file to ALL_PHOTOS and copies to album folders', () async {
        final content = [1, 2, 3];
        final yearFile = fixture.createFile('2023/test.jpg', content);
        final albumFile = fixture.createFile('Albums/Vacation/test.jpg', content);

        final merged = await albumSvc.detectAndMergeAlbums([
          MediaEntity.single(file: yearFile, dateTaken: DateTime(2023, 6, 15)),
          MediaEntity.single(file: albumFile, dateTaken: DateTime(2023, 6, 15)),
        ]);
        final entity = merged.single;

        final results = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(2)); // Move + copy
        expect(results[0].success, isTrue);
        expect(results[0].operation.operationType, equals(MediaEntityOperationType.move));
        expect(results[1].success, isTrue);
        expect(results[1].operation.operationType, equals(MediaEntityOperationType.copy));

        final allPhotosPath = p.join(outputDir.path, 'ALL_PHOTOS', '2023');
        final albumPath = p.join(outputDir.path, 'Vacation');
        expect(Directory(allPhotosPath).existsSync(), isTrue);
        expect(Directory(albumPath).existsSync(), isTrue);
      });
    });

    group('JsonMovingStrategy', () {
      late JsonMovingStrategy strategy;

      setUp(() {
        strategy = JsonMovingStrategy(fileService, pathService);
      });

      test('moves files to ALL_PHOTOS and creates albums-info.json', () async {
        // Entidad 1: año + álbum Vacation
        final c1 = [1, 2, 3];
        final y1 = fixture.createFile('2023/test1.jpg', c1);
        final a1 = fixture.createFile('Albums/Vacation/test1.jpg', c1);

        // Entidad 2: año + álbum Family
        final c2 = [4, 5, 6];
        final y2 = fixture.createFile('2023/test2.jpg', c2);
        final a2 = fixture.createFile('Albums/Family/test2.jpg', c2);

        final merged = await albumSvc.detectAndMergeAlbums([
          MediaEntity.single(file: y1, dateTaken: DateTime(2023, 6, 15)),
          MediaEntity.single(file: a1, dateTaken: DateTime(2023, 6, 15)),
          MediaEntity.single(file: y2, dateTaken: DateTime(2023, 7, 20)),
          MediaEntity.single(file: a2, dateTaken: DateTime(2023, 7, 20)),
        ]);

        // Procesa ambas entidades fusionadas
        final results1 = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(merged[0], context)) {
          results1.add(r);
        }
        final results2 = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(merged[1], context)) {
          results2.add(r);
        }

        expect(results1.length, equals(1));
        expect(results2.length, equals(1));
        expect(results1[0].success, isTrue);
        expect(results2[0].success, isTrue);

        // Finaliza para crear el JSON
        final finalizationResults = await strategy.finalize(context, merged);
        expect(finalizationResults.length, equals(1));
        expect(finalizationResults[0].success, isTrue);

        final jsonFile = File(p.join(outputDir.path, 'albums-info.json'));
        expect(jsonFile.existsSync(), isTrue);

        final jsonContent = await jsonFile.readAsString();
        final albumData = jsonDecode(jsonContent) as Map<String, dynamic>;
        expect(albumData['albums'], isA<Map<String, dynamic>>());
        expect(albumData['metadata']['total_albums'], equals(2));
      });
    });

    group('NothingMovingStrategy', () {
      late NothingMovingStrategy strategy;

      setUp(() {
        strategy = NothingMovingStrategy(fileService, pathService);
      });

      test('moves only year-based files to ALL_PHOTOS', () async {
        final sourceFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: sourceFile,
          dateTaken: DateTime(2023, 6, 15),
        );

        final results = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1));
        expect(results[0].success, isTrue);
        expect(results[0].operation.operationType, equals(MediaEntityOperationType.move));
      });

      test('processes album-only files (fixed behavior)', () async {
        // Solo existe en álbum → debe procesarlo igualmente (move)
        final albumOnly = fixture.createFile('Albums/Vacation/test.jpg', [1, 2, 3]);
        final entity = MediaEntity.single(
          file: albumOnly,
          dateTaken: DateTime(2023, 6, 15),
        );

        final results = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1));
        expect(results[0].success, isTrue);
        expect(results[0].operation.operationType, equals(MediaEntityOperationType.move));
      });
    });

    group('Integration Tests', () {
      test('all strategies can be created and validate context', () {
        final factory = MediaEntityMovingStrategyFactory(
          fileService,
          pathService,
          symlinkService,
        );

        for (final behavior in AlbumBehavior.values) {
          final strategy = factory.createStrategy(behavior);
          expect(strategy, isA<MediaEntityMovingStrategy>());
          expect(() => strategy.validateContext(context), returnsNormally);
        }
      });

      test('strategies handle file operation errors gracefully', () async {
        final strategy = ShortcutMovingStrategy(
          fileService,
          pathService,
          symlinkService,
        );

        final nonExistentFile = File('${fixture.basePath}/nonexistent.jpg');
        final entity = MediaEntity.single(
          file: nonExistentFile,
          dateTaken: DateTime(2023, 6, 15),
        );

        final results = <MediaEntityMovingResult>[];
        await for (final r in strategy.processMediaEntity(entity, context)) {
          results.add(r);
        }

        expect(results.length, equals(1));
        expect(results[0].success, isFalse);
        expect(results[0].errorMessage, contains('Failed to move primary file'));
      });
    });
  });
}
