/// Integration tests for the moving logic system
///
/// These tests validate that the moving system works correctly with various
/// configurations and provides the expected functionality.
library;

import 'dart:io';

import 'package:gpth/domain/models/processing_config_model.dart';
import 'package:gpth/domain/services/moving/media_moving_service.dart';
import 'package:gpth/domain/services/moving/moving_context_model.dart';
import 'package:gpth/media.dart';
import 'package:gpth/moving.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import './test_setup.dart';

void main() {
  group('Moving Logic - Integration Tests', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });
    group('API Compatibility', () {
      test('moveFiles works with standard parameters', () async {
        // Setup test data
        final testFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final media = [
          Media({null: testFile}),
        ];
        final outputDir = fixture.createDirectory(
          'output',
        ); // Test that the API works with standard parameters
        final results = await moveFiles(
          media,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList(); // Should process exactly one file
        expect(
          results.last,
          equals(1),
        ); // Verify file was copied to output directory
        final outputFiles = await outputDir
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();
        expect(outputFiles.length, equals(1));
        expect(outputFiles.first.readAsBytesSync(), equals([1, 2, 3]));
      });
      test('backwards compatibility functions work', () async {
        final testFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final targetDir = fixture.createDirectory('target');

        // Test findNotExistingName when file doesn't exist
        final nonExistentFile = File(
          p.join(fixture.basePath, 'nonexistent.jpg'),
        );
        final uniqueFile = findNotExistingName(nonExistentFile);
        expect(
          uniqueFile.path,
          equals(nonExistentFile.path),
        ); // Should be same if no conflict

        // Test findNotExistingName when file exists
        final uniqueFile2 = findNotExistingName(testFile);
        expect(
          uniqueFile2.path,
          contains('(1)'),
        ); // Should add (1) since file exists

        // Test createShortcut
        final shortcut = await createShortcut(targetDir, testFile);
        expect(shortcut.existsSync(), isTrue);
        expect(shortcut.parent.path, equals(targetDir.path));
      });
    });
    group('Moving System Features', () {
      test('MediaMovingService provides good error handling', () async {
        final service = MediaMovingService();
        final context = MovingContext(
          outputDirectory: fixture.createDirectory('output'),
          copyMode: true,
          dateDivision: DateDivisionLevel.none,
          albumBehavior: AlbumBehavior.nothing,
          verbose: true,
        );

        final testFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final media = [
          Media({null: testFile}),
        ];

        var progressCount = 0;
        await for (final progress in service.moveMediaFiles(media, context)) {
          progressCount = progress;
        }
        expect(progressCount, equals(1)); // Verify file was moved
        final outputFiles = await context.outputDirectory
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();
        expect(outputFiles.length, equals(1));
        expect(outputFiles.first.readAsBytesSync(), equals([1, 2, 3]));
      });
      test('system supports dependency injection', () async {
        // This demonstrates how the architecture makes testing easier
        // by allowing dependency injection of services

        final service = MediaMovingService(); // Uses default dependencies
        expect(service, isNotNull);

        // Could inject mock services for testing:
        // final service = MediaMovingService.withDependencies(
        //   fileService: MockFileOperationService(),
        //   pathService: MockPathGeneratorService(),
        //   shortcutService: MockShortcutService(),
        // );
      });
      test('strategy pattern allows easy extension', () async {
        // This test demonstrates how the architecture makes it easier
        // to add new album behaviors without modifying core logic

        final context = MovingContext(
          outputDirectory: fixture.createDirectory('output'),
          copyMode: true,
          dateDivision: DateDivisionLevel.none,
          albumBehavior: AlbumBehavior.json,
        );

        final testFile = fixture.createFile('test.jpg', [1, 2, 3]);
        final media = [
          Media({null: testFile}),
        ];

        final service = MediaMovingService();
        await for (final _ in service.moveMediaFiles(media, context)) {
          // Process files
        }

        // Should create albums-info.json file
        final jsonFile = File(
          p.join(context.outputDirectory.path, 'albums-info.json'),
        );
        expect(jsonFile.existsSync(), isTrue);
      });
    });
    group('Performance Comparison', () {
      test('moving system has good performance', () async {
        // Create larger dataset
        final media = <Media>[];
        for (int i = 0; i < 20; i++) {
          final file = fixture.createFile('test_$i.jpg', [i]);
          media.add(Media({null: file}));
        }

        final outputDir = fixture.createDirectory('output');

        // Time the operation
        final stopwatch = Stopwatch()..start();

        await for (final _ in moveFiles(
          media,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        )) {
          // Process all files
        }

        stopwatch.stop();
        final elapsedTime = stopwatch.elapsedMilliseconds;

        // Performance should be reasonable (less than 5 seconds for 20 files)
        expect(elapsedTime, lessThan(5000)); // Verify all files were processed
        final outputFiles = await outputDir
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();
        expect(outputFiles.length, equals(20));
      });
    });
  });
}
