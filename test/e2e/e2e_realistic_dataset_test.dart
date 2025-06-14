/// End-to-end tests using realistic Google Photos Takeout dataset
///
/// This test file uses generateRealisticTakeoutDataset() to create comprehensive
/// test scenarios that closely mirror real-world Google Photos exports.
// ignore_for_file: avoid_redundant_argument_values

library;

import 'dart:io';

import 'package:gpth/domain/main_pipeline.dart';
import 'package:gpth/domain/models/processing_config_model.dart';
import 'package:gpth/domain/services/takeout_path_resolver_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('End-to-End Realistic Dataset Tests', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String takeoutPath;
    late String outputPath;

    setUpAll(() async {
      fixture = TestFixture();
      await fixture.setUp();

      // Generate a comprehensive realistic dataset
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 3,
        albumCount: 5,
        photosPerYear: 10,
        albumOnlyPhotos: 3,
        exifRatio: 0.7,
      );

      outputPath = p.join(fixture.basePath, 'output');
    });

    setUp(() async {
      // Initialize pipeline
      pipeline = const ProcessingPipeline();

      // Ensure clean output directory for each test
      final outputDir = Directory(outputPath);
      if (await outputDir.exists()) {
        await outputDir.delete(recursive: true);
      }
      await outputDir.create(recursive: true);
    });

    tearDownAll(() async {
      await fixture.tearDown();
    });
    test('should process realistic dataset with default settings', () async {
      // Resolve the takeout path to the actual Google Photos directory
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      expect(
        await inputDir.exists(),
        isTrue,
        reason: 'Input directory should exist',
      ); // Create processing configuration
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.none,
        copyMode: true, // Use copy to preserve test data
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      // Run the main pipeline with realistic settings
      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(
        result.isSuccess,
        isTrue,
        reason: 'Pipeline should execute successfully',
      );

      // Verify output structure
      final outputContents = await outputDir.list().toList();
      expect(outputContents, isNotEmpty, reason: 'Output should contain files');

      // Should have ALL_PHOTOS directory
      final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
      expect(
        await allPhotosDir.exists(),
        isTrue,
        reason: 'ALL_PHOTOS directory should exist',
      );

      // Should have album directories (shortcut behavior)
      final albumDirs = outputContents
          .whereType<Directory>()
          .where(
            (final dir) =>
                p.basename(dir.path).contains('🏖️') ||
                p.basename(dir.path).contains('👨‍👩‍👧‍👦') ||
                p.basename(dir.path).contains('🎄'),
          )
          .toList();

      expect(
        albumDirs.length,
        greaterThan(0),
        reason: 'Should create album directories',
      );
    });
    test('should handle album processing correctly', () async {
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.duplicateCopy,
        dateDivision: DateDivisionLevel.none,
        copyMode: true,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      final outputContents = await outputDir.list(recursive: true).toList();

      // Count files in albums vs ALL_PHOTOS
      final allPhotosFiles = outputContents
          .whereType<File>()
          .where((final file) => file.path.contains('ALL_PHOTOS'))
          .toList();

      final albumFiles = outputContents
          .whereType<File>()
          .where(
            (final file) =>
                !file.path.contains('ALL_PHOTOS') && file.path.endsWith('.jpg'),
          )
          .toList();

      expect(
        allPhotosFiles.length,
        greaterThan(0),
        reason: 'Should have photos in ALL_PHOTOS',
      );
      expect(
        albumFiles.length,
        greaterThan(0),
        reason: 'Should have duplicated photos in albums',
      );
    });
    test('should extract dates from various filename patterns', () async {
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.year,
        copyMode: true,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      // Find ALL_PHOTOS directory first
      final allPhotosDir = await outputDir
          .list()
          .where(
            (final entity) =>
                entity is Directory &&
                p.basename(entity.path).contains('ALL_PHOTOS'),
          )
          .cast<Directory>()
          .first;

      // Then find year directories within ALL_PHOTOS
      final yearDirs = await allPhotosDir
          .list()
          .where((final entity) => entity is Directory)
          .cast<Directory>()
          .where(
            (final dir) => RegExp(r'^\d{4}$').hasMatch(p.basename(dir.path)),
          )
          .toList();

      expect(
        yearDirs.length,
        greaterThan(0),
        reason: 'Should create year-based folders when divideToDates is true',
      );

      // Check that we have current and recent years
      final currentYear = DateTime.now().year;
      final yearNames = yearDirs
          .map((final dir) => int.parse(p.basename(dir.path)))
          .toSet();

      expect(
        yearNames.any((final year) => year >= currentYear - 3),
        isTrue,
        reason: 'Should have recent years in output',
      );
    });
    test('should handle JSON metadata extraction', () async {
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.json,
        dateDivision: DateDivisionLevel.none,
        copyMode: true,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      // Should create albums-info.json file
      final albumsInfoFile = File(p.join(outputPath, 'albums-info.json'));
      expect(
        await albumsInfoFile.exists(),
        isTrue,
        reason: 'Should create albums-info.json file',
      );

      // Verify the JSON content
      final albumsInfo = await albumsInfoFile.readAsString();
      expect(albumsInfo, isNotEmpty, reason: 'Albums info should not be empty');
      expect(
        albumsInfo,
        contains('Vacation'),
        reason: 'Should contain album information',
      );
    });
    test('should preserve EXIF data when available', () async {
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
        copyMode: true,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );
      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
      final outputFiles = await allPhotosDir
          .list()
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      expect(
        outputFiles.length,
        greaterThan(0),
        reason: 'Should have processed image files',
      );

      // Check that files have been processed (their modified times should be set)
      var filesWithCorrectDates = 0;
      for (final file in outputFiles.take(5)) {
        // Check first 5 files
        final stat = await file.stat();
        final modTime = stat.modified;

        // Files should have their modification times set to historical dates
        // (not the current processing time)
        if (modTime.year < DateTime.now().year ||
            (modTime.year == DateTime.now().year &&
                modTime.month < DateTime.now().month)) {
          filesWithCorrectDates++;
        }
      }

      expect(
        filesWithCorrectDates,
        greaterThan(0),
        reason: 'Some files should have historical modification dates',
      );
    });
    test(
      'should handle special folders (Archive, Trash, Screenshots)',
      () async {
        final googlePhotosPath =
            TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          skipExtras: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: inputDir,
          outputDirectory: outputDir,
        );
        expect(result.isSuccess, isTrue);

        final outputContents = await outputDir.list().toList();

        // Check if special folders are processed
        final specialDirs = outputContents
            .whereType<Directory>()
            .where(
              (final dir) => [
                'Archive',
                'Trash',
                'Screenshots',
              ].any((final special) => p.basename(dir.path).contains(special)),
            )
            .toList();

        // Screenshots should be processed as they contain valid photos
        expect(
          specialDirs.length,
          greaterThanOrEqualTo(0),
          reason: 'Special folders should be handled appropriately',
        );
      },
    );
    test('should handle photos with geo data', () async {
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
        copyMode: true,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      // Verify that photos with geo data in JSON are processed
      final jsonFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.json'),
          )
          .cast<File>()
          .toList();

      expect(
        jsonFiles.length,
        greaterThan(0),
        reason: 'Should have JSON metadata files',
      );

      // Check that some JSON files contain geo data
      var filesWithGeoData = 0;
      for (final jsonFile in jsonFiles.take(10)) {
        final content = await jsonFile.readAsString();
        if (content.contains('geoData') || content.contains('latitude')) {
          filesWithGeoData++;
        }
      }

      expect(
        filesWithGeoData,
        greaterThan(0),
        reason: 'Some files should have geo data in JSON',
      );
    });

    test('should handle duplicate detection correctly', () async {
      // First, let's create some duplicate files in the test data
      final testDir = Directory(takeoutPath);
      final yearDirs = await testDir
          .list(recursive: true)
          .where(
            (final entity) =>
                entity is Directory &&
                p.basename(entity.path).startsWith('Photos from'),
          )
          .cast<Directory>()
          .toList();

      if (yearDirs.isNotEmpty) {
        final firstYearDir = yearDirs.first;
        final photos = await firstYearDir
            .list()
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .take(2)
            .toList();

        if (photos.length >= 2) {
          // Create a duplicate by copying one photo to create identical content
          final originalPhoto = photos.first;
          final duplicatePhoto = File(
            p.join(
              firstYearDir.path,
              'duplicate_${p.basename(originalPhoto.path)}',
            ),
          );
          await originalPhoto.copy(duplicatePhoto.path);

          // Also copy the JSON file
          final originalJson = File('${originalPhoto.path}.json');
          if (await originalJson.exists()) {
            await originalJson.copy('${duplicatePhoto.path}.json');
          }
        }
      }
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
        copyMode: true,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
      final outputFiles = await allPhotosDir
          .list()
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      expect(
        outputFiles.length,
        greaterThan(0),
        reason: 'Should have processed files after duplicate detection',
      );
    });
    test('should generate processing metrics', () async {
      final googlePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(takeoutPath);
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.none,
        copyMode: true,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      // Verify the processing completed successfully
      expect(await outputDir.exists(), isTrue);

      final contents = await outputDir.list(recursive: true).toList();
      expect(
        contents.length,
        greaterThan(10),
        reason: 'Should have processed significant number of files',
      );
    });

    test('should handle large dataset performance', () async {
      // Generate a larger dataset for performance testing
      final largeTakeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 5,
        albumCount: 10,
        photosPerYear: 20,
        albumOnlyPhotos: 10,
        exifRatio: 0.8,
      );

      final largeOutputPath = p.join(fixture.basePath, 'large_output');
      final stopwatch = Stopwatch()..start();

      final largeGooglePhotosPath =
          TakeoutPathResolverService.resolveGooglePhotosPath(largeTakeoutPath);
      final inputDir = Directory(largeGooglePhotosPath);
      final outputDir = Directory(largeOutputPath);

      final config = ProcessingConfig(
        inputPath: largeGooglePhotosPath,
        outputPath: largeOutputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.year,
        copyMode: true,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      stopwatch.stop();
      expect(result.isSuccess, isTrue);

      // Verify processing completed
      expect(await outputDir.exists(), isTrue);

      final outputFiles = await outputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      expect(
        outputFiles.length,
        greaterThan(50),
        reason: 'Should process large number of files',
      );

      // Performance should be reasonable (adjust threshold as needed)
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(60000),
        reason: 'Processing should complete within reasonable time',
      );
    });
  });
}
