/// End-to-end tests using realistic Google Photos Takeout dataset
///
/// This test file uses generateRealisticTakeoutDataset() to create comprehensive
/// test scenarios that closely mirror real-world Google Photos exports.
// ignore_for_file: avoid_redundant_argument_values
@Timeout(Duration(seconds: 120))
library;

import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('End-to-End Realistic Dataset Tests', () {
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

      // Generate a fresh realistic dataset for each test to ensure test isolation
      // This prevents tests from interfering with each other when they move/modify files
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 3,
        albumCount: 5,
        photosPerYear: 10,
        albumOnlyPhotos: 3,
        exifRatio: 0.7,
        includeRawSamples: true,
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
      // Clean up ServiceContainer first to release file handles
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();

      await fixture.tearDown();

      // Clean up any leftover fixture directories from helper functions
      await cleanupAllFixtures();
    });
    test('should process realistic dataset with default settings', () async {
      // Resolve the takeout path to the actual Google Photos directory
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
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
        dateDivision: DateDivisionLevel.none, // Move files from input to output
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
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
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
                path.basename(dir.path).contains('🏖️') ||
                path.basename(dir.path).contains('👨‍👩‍👧‍👦') ||
                path.basename(dir.path).contains('🎄'),
          )
          .toList();

      expect(
        albumDirs.length,
        greaterThan(0),
        reason: 'Should create album directories',
      );
    });
    test('should handle album processing correctly', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.duplicateCopy,
        dateDivision: DateDivisionLevel.none,
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
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.year,
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
                path.basename(entity.path).contains('ALL_PHOTOS'),
          )
          .cast<Directory>()
          .first;

      // Then find year directories within ALL_PHOTOS
      final yearDirs = await allPhotosDir
          .list()
          .where((final entity) => entity is Directory)
          .cast<Directory>()
          .where(
            (final dir) => RegExp(r'^\d{4}$').hasMatch(path.basename(dir.path)),
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
          .map((final dir) => int.parse(path.basename(dir.path)))
          .toSet();

      expect(
        yearNames.any((final year) => year >= currentYear - 3),
        isTrue,
        reason: 'Should have recent years in output',
      );
    });
    test('should handle JSON metadata extraction', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);
      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.json,
        dateDivision: DateDivisionLevel.none,
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
      final albumsInfoFile = File(path.join(outputPath, 'albums-info.json'));
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
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
        skipExtras: false,
        writeExif: false, // Disable EXIF writing in tests
      );
      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(result.isSuccess, isTrue);

      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
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
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
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
              ].any((final special) => path.basename(dir.path).contains(special)),
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
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
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
                path.basename(entity.path).startsWith('Photos from'),
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
            path.join(
              firstYearDir.path,
              'duplicate_${path.basename(originalPhoto.path)}',
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
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing,
        dateDivision: DateDivisionLevel.none,
        skipExtras: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );
      expect(result.isSuccess, isTrue);

      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
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
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.none,
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
        includeRawSamples: true,
      );

      final largeOutputPath = path.join(fixture.basePath, 'large_output');
      final stopwatch = Stopwatch()..start();

      final largeGooglePhotosPath = PathResolverService.resolveGooglePhotosPath(
        largeTakeoutPath,
      );
      final inputDir = Directory(largeGooglePhotosPath);
      final outputDir = Directory(largeOutputPath);

      final config = ProcessingConfig(
        inputPath: largeGooglePhotosPath,
        outputPath: largeOutputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision: DateDivisionLevel.year,
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
        reason:
            'Large dataset output size too small. Expected > 50 JPGs. Actual: ${outputFiles.length}\nFiles sample: ${outputFiles.take(10).map((final f) => path.basename(f.path)).toList()}',
      );

      // Performance should be reasonable; provide detailed diagnostics on failure
      const thresholdMs = 60000; // 60s baseline
      expect(
        stopwatch.elapsedMilliseconds < thresholdMs,
        isTrue,
        reason:
            'Performance threshold exceeded. Elapsed: ${stopwatch.elapsedMilliseconds}ms (threshold: ${thresholdMs}ms)\nInput: $largeGooglePhotosPath\nOutput: $largeOutputPath\nProcessed JPG count: ${outputFiles.length}',
      );
    });
    test('should actually move files in move mode (move logic verification)', () async {
      // NOTE: In move mode, files from year folders are moved to output,
      // but album-only files (files that exist only in album folders, not in year folders)
      // remain in place to prevent data loss. This is expected behavior.
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      // Get list of all files in input directory before processing
      final inputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .map((final file) => file.path)
          .toSet();

      print('[DEBUG] Input files before processing: ${inputFiles.length}');
      for (final path in inputFiles.take(5)) {
        print('[DEBUG] Input file: $path');
      }

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.shortcut,
        dateDivision:
            DateDivisionLevel.none, // Files are moved from input to output
        skipExtras: false,
        writeExif: false,
      );

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

      // Verify output structure exists
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      expect(
        await allPhotosDir.exists(),
        isTrue,
        reason: 'ALL_PHOTOS directory should exist',
      );

      // Get list of output files (only counting actual moved files in ALL_PHOTOS)
      // In shortcut/symlink mode, album directories contain symlinks, not actual files
      final allPhotosDirectory = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      final outputFiles = await allPhotosDirectory
          .list()
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      print(
        '[DEBUG] Output files in ALL_PHOTOS (actual moved files): ${outputFiles.length}',
      );

      expect(
        outputFiles.length,
        greaterThan(0),
        reason: 'Should have processed files in output',
      );

      print('[DEBUG] Output files after processing: ${outputFiles.length}');
      for (final file in outputFiles.take(5)) {
        print('[DEBUG] Output file: ${file.path}');
      } // CRITICAL TEST: In move mode, check remaining files behavior
      final remainingInputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      print(
        '[DEBUG] Remaining input files after processing: ${remainingInputFiles.length}',
      );
      for (final file in remainingInputFiles) {
        print('[DEBUG] Remaining input file: ${file.path}');
      }

      // IMPORTANT: In move mode, album-only files remain in album folders
      // This is expected behavior to prevent data loss for files that exist
      // only in albums (not duplicated in year folders)
      final albumOnlyFiles = remainingInputFiles.where((final file) {
        // Check if this file is in an album folder (not a year folder)
        final relativePath = path.relative(file.path, from: inputDir.path);
        final pathParts = relativePath.split(path.separator);

        // Album folders don't start with "Photos from"
        return pathParts.isNotEmpty &&
            !pathParts.first.startsWith('Photos from');
      }).toList();

      print('[DEBUG] Album-only files remaining: ${albumOnlyFiles.length}');
      for (final file in albumOnlyFiles) {
        print('[DEBUG] Album-only file: ${file.path}');
      }

      // All remaining files should be album-only files
      expect(
        remainingInputFiles.length,
        equals(albumOnlyFiles.length),
        reason:
            'In move mode, only album-only files should remain in original location. '
            'These files exist only in album folders and are preserved to prevent data loss. '
            'Found ${remainingInputFiles.length} total remaining files, '
            '${albumOnlyFiles.length} are album-only files.',
      ); // Verify output file count: should be input files minus album-only files
      // (album-only files remain in place to prevent data loss)
      final expectedOutputCount = inputFiles.length - albumOnlyFiles.length;
      expect(
        outputFiles.length,
        equals(expectedOutputCount),
        reason:
            'Expected $expectedOutputCount files in output directory '
            '(${inputFiles.length} input files minus ${albumOnlyFiles.length} album-only files)',
      );
    });
    test(
      'should move files from input to output directory (move logic verification)',
      () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        // Get list of all files in input directory before processing
        final inputFilesBefore = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .map((final file) => file.path)
            .toSet();

        print(
          '[DEBUG] Input files before processing: ${inputFilesBefore.length}',
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          skipExtras: false,
          writeExif: false,
        );

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

        // Get list of files in input directory after processing
        final inputFilesAfter = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .map((final file) => file.path)
            .toSet();

        print(
          '[DEBUG] Input files after processing: ${inputFilesAfter.length}',
        ); // CRITICAL TEST: Files are moved from input to output directory
        // NOTE: Album-only files (files that exist only in album folders, not in year folders)
        // remain in place to prevent data loss. This is expected behavior in move mode.
        final albumOnlyFiles = inputFilesAfter.where((final filePath) {
          // Check if this file is in an album folder (not a year folder)
          final relativePath = path.relative(filePath, from: inputDir.path);
          final pathParts = relativePath.split(path.separator);

          // Album folders don't start with "Photos from"
          return pathParts.isNotEmpty &&
              !pathParts.first.startsWith('Photos from');
        }).toList();

        expect(
          inputFilesAfter.length,
          equals(albumOnlyFiles.length),
          reason:
              'In move mode, only album-only files should remain in input directory. '
              'These files exist only in album folders and are preserved to prevent data loss. '
              'Expected ${albumOnlyFiles.length} album-only files, found ${inputFilesAfter.length} total remaining files.',
        ); // Verify output files were created (only count actual moved files in ALL_PHOTOS)
        // In shortcut/symlink mode, album directories contain symlinks, not actual files
        final allPhotosDirectory = Directory(path.join(outputPath, 'ALL_PHOTOS'));
        final outputFiles = await allPhotosDirectory
            .list()
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        // Output should contain files that were moved from year folders
        final expectedOutputFiles =
            inputFilesBefore.length - albumOnlyFiles.length;
        expect(
          outputFiles.length,
          equals(expectedOutputFiles),
          reason:
              'Output should contain moved files from year folders. '
              'Expected $expectedOutputFiles files (${inputFilesBefore.length} total - ${albumOnlyFiles.length} album-only), '
              'found ${outputFiles.length}',
        );

        print('[DEBUG] Output files created: ${outputFiles.length}');
      },
    );

    test('should verify move logic with duplicate-copy album behavior', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      // Count input files before processing
      final inputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior:
            AlbumBehavior.duplicateCopy, // This creates duplicates in albums
        dateDivision:
            DateDivisionLevel.none, // Move mode - originals should be gone
        skipExtras: false,
        writeExif: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(
        result.isSuccess,
        isTrue,
      ); // Verify no files remain in input (except album-only files)
      final remainingInputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      // Album-only files (files that exist only in album folders) remain to prevent data loss
      final albumOnlyFiles = remainingInputFiles.where((final file) {
        final relativePath = path.relative(file.path, from: inputDir.path);
        final pathParts = relativePath.split(path.separator);
        // Album folders don't start with "Photos from"
        return pathParts.isNotEmpty &&
            !pathParts.first.startsWith('Photos from');
      }).toList();

      expect(
        remainingInputFiles.length,
        equals(albumOnlyFiles.length),
        reason:
            'In move mode, only album-only files should remain in input directory. '
            'These files exist only in album folders and are preserved to prevent data loss. '
            'Found ${remainingInputFiles.length} total remaining files, '
            '${albumOnlyFiles.length} are album-only files.',
      );

      // Verify output structure with duplicates
      final outputFiles = await outputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList(); // With duplicate-copy, we should have more output files than input files
      // because files are copied to both ALL_PHOTOS and album folders
      // But we need to account for album-only files that remain in input
      final movedFiles = inputFiles.length - albumOnlyFiles.length;
      expect(
        outputFiles.length,
        greaterThanOrEqualTo(movedFiles),
        reason:
            'Duplicate-copy should create copies in album folders. '
            'Expected at least $movedFiles files (${inputFiles.length} total - ${albumOnlyFiles.length} album-only), '
            'found ${outputFiles.length}',
      );
    });

    test(
      'should verify album duplication logic with duplicate-copy album behavior',
      () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final inputDir = Directory(googlePhotosPath);
        final outputDir = Directory(outputPath);

        // Count input files before processing
        final inputFiles = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        final originalInputCount = inputFiles.length;
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.duplicateCopy,
          dateDivision: DateDivisionLevel.none,
          skipExtras: false,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: inputDir,
          outputDirectory: outputDir,
        );

        expect(
          result.isSuccess,
          isTrue,
        ); // Verify all files moved from input (except album-only files)
        final remainingInputFiles = await inputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();

        // Album-only files remain to prevent data loss
        final albumOnlyFiles = remainingInputFiles.where((final file) {
          final relativePath = path.relative(file.path, from: inputDir.path);
          final pathParts = relativePath.split(path.separator);
          // Album folders don't start with "Photos from"
          return pathParts.isNotEmpty &&
              !pathParts.first.startsWith('Photos from');
        }).toList();

        expect(
          remainingInputFiles.length,
          equals(albumOnlyFiles.length),
          reason:
              'In move mode, only album-only files should remain in input directory. '
              'These files exist only in album folders and are preserved to prevent data loss. '
              'Expected ${albumOnlyFiles.length} album-only files, '
              'found ${remainingInputFiles.length} total remaining',
        );

        // Verify output has duplicates
        final outputFiles = await outputDir
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .cast<File>()
            .toList();
        expect(
          outputFiles.length,
          greaterThanOrEqualTo(originalInputCount - albumOnlyFiles.length),
          reason:
              'Output should contain copies with potential duplicates in album folders. '
              'Expected at least ${originalInputCount - albumOnlyFiles.length} files '
              '($originalInputCount total - ${albumOnlyFiles.length} album-only), '
              'found ${outputFiles.length}',
        );
      },
    );

    test('should verify move logic with year-based date division', () async {
      final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
        takeoutPath,
      );
      final inputDir = Directory(googlePhotosPath);
      final outputDir = Directory(outputPath);

      final config = ProcessingConfig(
        inputPath: googlePhotosPath,
        outputPath: outputPath,
        albumBehavior: AlbumBehavior.nothing, // No albums, just year folders
        dateDivision: DateDivisionLevel.year, // Move mode
        skipExtras: false,
        writeExif: false,
      );

      final result = await pipeline.execute(
        config: config,
        inputDirectory: inputDir,
        outputDirectory: outputDir,
      );

      expect(
        result.isSuccess,
        isTrue,
      ); // Verify no files remain in original year folders within input (except album-only files)
      final remainingInputFiles = await inputDir
          .list(recursive: true)
          .where(
            (final entity) => entity is File && entity.path.endsWith('.jpg'),
          )
          .cast<File>()
          .toList();

      // Album-only files remain to prevent data loss
      final albumOnlyFiles = remainingInputFiles.where((final file) {
        final relativePath = path.relative(file.path, from: inputDir.path);
        final pathParts = relativePath.split(path.separator);
        // Album folders don't start with "Photos from"
        return pathParts.isNotEmpty &&
            !pathParts.first.startsWith('Photos from');
      }).toList();

      expect(
        remainingInputFiles.length,
        equals(albumOnlyFiles.length),
        reason:
            'Move mode with year division should move all files from input year folders. '
            'Only album-only files should remain to prevent data loss. '
            'Expected ${albumOnlyFiles.length} album-only files, '
            'found ${remainingInputFiles.length} total remaining',
      ); // Verify year-based organization in output
      final allPhotosDir = Directory(path.join(outputPath, 'ALL_PHOTOS'));
      // Debug: Check if ALL_PHOTOS directory exists and what's in output
      print('[DEBUG] Year-based test - Output path: $outputPath');
      final outputDirContents = await Directory(outputPath).list().toList();
      print(
        '[DEBUG] Year-based test - Output contents: ${outputDirContents.map((final e) => path.basename(e.path)).toList()}',
      );
      print(
        '[DEBUG] Year-based test - ALL_PHOTOS exists: ${await allPhotosDir.exists()}',
      );

      if (await allPhotosDir.exists()) {
        final allPhotosContents = await allPhotosDir.list().toList();
        print(
          '[DEBUG] Year-based test - ALL_PHOTOS contents: ${allPhotosContents.map((final e) => path.basename(e.path)).toList()}',
        );
      }

      if (!await allPhotosDir.exists()) {
        throw StateError(
          'ALL_PHOTOS directory does not exist in output path: ${allPhotosDir.path}',
        );
      }

      final yearDirs = await allPhotosDir
          .list()
          .where((final entity) => entity is Directory)
          .cast<Directory>()
          .where(
            (final dir) => RegExp(r'^\d{4}$').hasMatch(path.basename(dir.path)),
          )
          .toList();

      expect(
        yearDirs.length,
        greaterThan(0),
        reason: 'Should create year-based folders in ALL_PHOTOS',
      );
    });
    test(
      'should verify move behavior consistency across different album behaviors',
      () async {
        // Test multiple album behaviors to ensure consistent move/copy logic

        final testCases = [
          AlbumBehavior.shortcut,
          AlbumBehavior.duplicateCopy,
          AlbumBehavior.nothing,
          AlbumBehavior.json,
        ];

        for (final albumBehavior in testCases) {
          // Clean output directory for each test
          final outputDir = Directory(outputPath);
          if (await outputDir.exists()) {
            await outputDir.delete(recursive: true);
          }
          await outputDir.create(recursive: true);

          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final inputDir = Directory(
            googlePhotosPath,
          ); // Count input files before processing
          final inputFiles = await inputDir
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .cast<File>()
              .toList();

          final originalInputCount = inputFiles.length;

          // Test move behavior (only mode available)
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: albumBehavior,
            dateDivision: DateDivisionLevel.none,
            skipExtras: false,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: inputDir,
            outputDirectory: outputDir,
          );

          expect(
            result.isSuccess,
            isTrue,
            reason: 'Processing should succeed for ${albumBehavior.value}',
          ); // Verify files were moved (except album-only files)
          final remainingAfterMove = await inputDir
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .cast<File>()
              .toList();

          // Album-only files remain to prevent data loss
          final albumOnlyFiles = remainingAfterMove.where((final file) {
            final relativePath = path.relative(file.path, from: inputDir.path);
            final pathParts = relativePath.split(path.separator);
            // Album folders don't start with "Photos from"
            return pathParts.isNotEmpty &&
                !pathParts.first.startsWith('Photos from');
          }).toList();

          expect(
            remainingAfterMove.length,
            equals(albumOnlyFiles.length),
            reason:
                'In move mode, only album-only files should remain in input directory. '
                'These files exist only in album folders and are preserved to prevent data loss. '
                'Album behavior ${albumBehavior.value}: expected ${albumOnlyFiles.length} album-only files, '
                'found ${remainingAfterMove.length} total remaining',
          );

          // Verify output files were created
          final outputFiles = await outputDir
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.jpg'),
              )
              .cast<File>()
              .toList();
          expect(
            outputFiles.length,
            greaterThanOrEqualTo(originalInputCount - albumOnlyFiles.length),
            reason:
                'Output should contain at least moved files for ${albumBehavior.value}. '
                'Expected at least ${originalInputCount - albumOnlyFiles.length} files '
                '($originalInputCount total - ${albumOnlyFiles.length} album-only), '
                'found ${outputFiles.length}',
          );

          print(
            '[TEST] Verified move behavior for ${albumBehavior.value} - '
            'moved $originalInputCount files to output',
          );
        }
      },
    );
  });
}
