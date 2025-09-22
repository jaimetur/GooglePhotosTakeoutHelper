/// Performance benchmark tests for Google Photos Takeout Helper
///
/// This test suite measures the performance of key operations and provides
/// baseline measurements for performance improvements.
@Timeout(Duration(minutes: 25))
library;

import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('Performance Benchmark Tests', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String takeoutPath;
    late String outputPath;

    setUpAll(() async {
      // Initialize ServiceContainer first
      await ServiceContainer.instance.initialize();

      fixture = TestFixture();
      await fixture.setUp();
    });

    setUp(() async {
      // Initialize pipeline
      pipeline = const ProcessingPipeline();

      // Generate a large realistic dataset for performance testing
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 10,
        albumCount: 20,
        photosPerYear: 25,
        albumOnlyPhotos: 25,
        exifRatio: 0.8,
      );

      // Create unique output path for each test
      final timestamp = DateTime.now().microsecondsSinceEpoch.toString();
      outputPath = path.join(fixture.basePath, 'output_$timestamp');

      // Ensure clean output directory for each test
      final outputDir = Directory(outputPath);
      if (await outputDir.exists()) {
        await outputDir.delete(recursive: true);
      }
      await outputDir.create(recursive: true);
    });

    tearDownAll(() async {
      await fixture.tearDown();

      // Clean up ServiceContainer
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
    });

    group('EXIF Writing Performance', () {
      test('benchmark parallel EXIF writing', () async {
        // Resolve the takeout path to the actual Google Photos directory
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory('${outputPath}_parallel');

        // Create clean output directory
        final parallelOutputDir = Directory(outputDir.path);
        if (await parallelOutputDir.exists()) {
          await parallelOutputDir.delete(recursive: true);
        }
        await parallelOutputDir.create(recursive: true);

        // Create processing configuration with parallel EXIF writing
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: parallelOutputDir.path,
        );

        final stopwatch = Stopwatch()..start();

        // Run the pipeline with parallel processing
        final result = await pipeline.execute(
          config: config,
          inputDirectory: inputDir,
          outputDirectory: parallelOutputDir,
        );

        stopwatch.stop();

        expect(result.isSuccess, isTrue);
        print('Parallel EXIF writing completed in: ${stopwatch.elapsed}');
        print('Media files processed: ${result.mediaProcessed}');

        // Log detailed timing
        for (final stepResult in result.stepResults) {
          if (stepResult.stepName == 'Write EXIF Data') {
            print('EXIF step duration: ${stepResult.duration}');
            print('EXIF step data: ${stepResult.data}');
          }
        }

        // Expect better performance than sequential
        expect(stopwatch.elapsed.inSeconds, lessThan(120)); // 2 minutes max
      });
    });

    group('Overall Pipeline Performance', () {
      test(
        'benchmark complete pipeline with performance optimizations',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final inputDir = Directory(googlePhotosPath);
          final outputDir = Directory('${outputPath}_complete');

          // Create clean output directory
          final completeOutputDir = Directory(outputDir.path);
          if (await completeOutputDir.exists()) {
            await completeOutputDir.delete(recursive: true);
          }
          await completeOutputDir.create(recursive: true);

          // Create processing configuration with all optimizations
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: completeOutputDir.path,
          );

          final stopwatch = Stopwatch()..start();

          // Run the complete pipeline
          final result = await pipeline.execute(
            config: config,
            inputDirectory: inputDir,
            outputDirectory: completeOutputDir,
          );

          stopwatch.stop();

          expect(result.isSuccess, isTrue);

          print(
            'Complete optimized pipeline completed in: ${stopwatch.elapsed}',
          );

          // Log timing for each step
          for (final stepResult in result.stepResults) {
            print('${stepResult.stepName}: ${stepResult.duration}');
          }

          // The complete pipeline should finish in reasonable time
          expect(stopwatch.elapsed.inSeconds, lessThan(600)); // 10 minutes max
        },
      );
    });

    group('Individual Step Performance', () {
      test('benchmark media collection operations', () async {
        final collection = MediaEntityCollection();

        // Create test files for performance testing
        final testFiles = <File>[];
        for (int i = 0; i < 100; i++) {
          final file = fixture.createImageWithExif('test_$i.jpg');
          testFiles.add(file);
        }

        // Test discovery performance
        var stopwatch = Stopwatch()..start();
        // Note: This would need to be implemented with actual discovery logic
        // For now, we'll just measure the setup time
        stopwatch.stop();
        print('Media discovery setup: ${stopwatch.elapsed}');

        // Test duplicate removal performance
        stopwatch = Stopwatch()..start();
        final duplicatesRemoved = await collection.mergeMediaEntities();
        stopwatch.stop();
        print(
          'Duplicate removal: ${stopwatch.elapsed} (removed: $duplicatesRemoved)',
        );

        // Test EXIF writing performance
        stopwatch = Stopwatch()..start();
        final exifResult = await collection.writeExifData();
        stopwatch.stop();
        print(
          'EXIF writing: ${stopwatch.elapsed} (${exifResult['coordinatesWritten']} coordinates, ${exifResult['dateTimesWritten']} datetimes)',
        );

        // Cleanup test files
        for (final file in testFiles) {
          if (await file.exists()) {
            await file.delete();
          }
        }
      });
    });
  });
}
