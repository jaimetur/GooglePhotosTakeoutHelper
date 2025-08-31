/// Simple test to debug the strategy issue
library;

import 'dart:io';
import 'package:gpth/gpth-lib.dart';
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Simple Strategy Test', () {
    late TestFixture fixture;
    late FileOperationService fileService;
    late PathGeneratorService pathService;
    late Directory outputDir;
    late MovingContext context;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      // Initialize ServiceContainer
      await ServiceContainer.instance.initialize();

      fileService = FileOperationService();
      pathService = PathGeneratorService();
      outputDir = fixture.createDirectory('output');

      context = MovingContext(
        outputDirectory: outputDir,
        dateDivision: DateDivisionLevel.year,
        albumBehavior: AlbumBehavior.nothing,
      );
    });

    tearDown(() async {
      await fixture.tearDown();
      await ServiceContainer.reset();
    });

    test('MediaEntity.single basic properties (no album)', () {
      final sourceFile = fixture.createFile('2023/test.jpg', [1, 2, 3]);
      final entity = MediaEntity.single(
        file: sourceFile,
        dateTaken: DateTime(2023, 6, 15),
      );

      print('Primary file: ${entity.primaryFile.path}');
      print('hasAlbumAssociations: ${entity.hasAlbumAssociations}');
      print('albumNames: ${entity.albumNames}');

      expect(entity.primaryFile, sourceFile);
      expect(entity.hasAlbumAssociations, isFalse);
      expect(entity.albumNames, isEmpty);
    });

    test('NothingMovingStrategy can process a single year-based file', () async {
      final strategy = NothingMovingStrategy(fileService, pathService);

      // Coloca el fichero bajo un año para que sea “year-based”
      final sourceFile = fixture.createFile('2023/test.jpg', [1, 2, 3]);
      final entity = MediaEntity.single(
        file: sourceFile,
        dateTaken: DateTime(2023, 6, 15),
      );

      final results = <MediaEntityMovingResult>[];
      try {
        print('About to process entity with strategy...');
        print('Entity primaryFile: ${entity.primaryFile.path}');
        print('Entity hasAlbumAssociations: ${entity.hasAlbumAssociations}');

        await for (final result in strategy.processMediaEntity(entity, context)) {
          print('Got result: success=${result.success}');
          if (!result.success) {
            print('Error message: ${result.errorMessage}');
          }
          results.add(result);
        }

        print('Processing completed with ${results.length} results');
        expect(results.length, equals(1));
        expect(results.first.success, isTrue);

        // Verifica que movió a ALL_PHOTOS/2023 (comportamiento de NothingMovingStrategy)
        final allPhotosDir = Directory('${outputDir.path}/ALL_PHOTOS/2023');
        expect(allPhotosDir.existsSync(), isTrue);
      } catch (e, stackTrace) {
        print('Exception details: $e');
        print('Stack trace: $stackTrace');
        fail('Strategy threw an exception: $e');
      }
    });
  });
}
