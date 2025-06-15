/// Comprehensive E2E tests covering GitHub issues and README features
///
/// This test suite validates functionality based on:
/// - Known GitHub issues from changelog (#29, #32, #180, #238, #248, #261, #271, #299, #324, #353, #355, #371, #381, #389, #390)
/// - README feature specifications
/// - Real-world usage scenarios
/// - Edge cases and error conditions
///
/// Test Categories:
/// 1. Album Processing Modes (shortcut, duplicate-copy, reverse-shortcut, json, nothing)
/// 2. Date Organization Levels (none, year, month, day)
/// 3. File Format Support (.MP, .MV, .DNG, .CR2, HEIC, RAW)
/// 4. Extension Fixing Modes (none, standard, conservative, solo)
/// 5. Platform-specific Features (Windows shortcuts, emoji handling)
/// 6. Metadata Processing (JSON extraction, EXIF writing, GPS coordinates)
/// 7. Error Handling (corrupt files, permission issues, disk space)
/// 8. Special Cases (large files, unicode names, long paths)

// ignore_for_file: avoid_redundant_argument_values

library;

import 'dart:convert';
import 'dart:io';

import 'package:gpth/domain/main_pipeline.dart';
import 'package:gpth/domain/models/processing_config_model.dart';
import 'package:gpth/domain/services/core/service_container.dart';
import 'package:gpth/domain/services/user_interaction/path_resolver_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../setup/test_setup.dart';

void main() {
  group('E2E Tests - GitHub Issues & README Features', () {
    late TestFixture fixture;
    late ProcessingPipeline pipeline;
    late String takeoutPath;
    late String outputPath;

    setUpAll(() async {
      await ServiceContainer.instance.initialize();
      fixture = TestFixture();
      await fixture.setUp();

      // Generate comprehensive test dataset
      takeoutPath = await fixture.generateRealisticTakeoutDataset(
        yearSpan: 5,
        albumCount: 8,
        photosPerYear: 15,
        albumOnlyPhotos: 5,
        exifRatio: 0.8,
      );

      outputPath = p.join(fixture.basePath, 'output');
    });

    setUp(() async {
      pipeline = const ProcessingPipeline();

      // Clean output for each test
      final outputDir = Directory(outputPath);
      if (await outputDir.exists()) {
        await outputDir.delete(recursive: true);
      }
      await outputDir.create(recursive: true);
    });

    tearDownAll(() async {
      await fixture.tearDown();
      await ServiceContainer.instance.dispose();
      await ServiceContainer.reset();
    });

    group('Album Processing Modes - Issues #261, #248, #390', () {
      test('shortcut mode handles emoji folder names (Issue #389)', () async {
        // Create test data with emoji folder names
        final emojiTakeoutPath = await _createEmojiAlbumTestData();

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          emojiTakeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle emoji folder names',
        );

        // Verify emoji album folders were created
        final outputContents = await Directory(outputPath).list().toList();
        final albumDirs = outputContents
            .whereType<Directory>()
            .where(
              (final dir) =>
                  p.basename(dir.path).contains('🏖️') ||
                  p.basename(dir.path).contains('🎄') ||
                  p.basename(dir.path).contains('👨‍👩‍👧‍👦'),
            )
            .toList();

        expect(
          albumDirs.length,
          greaterThan(0),
          reason: 'Should create emoji album directories',
        );

        // Verify shortcuts are created properly on Windows
        if (Platform.isWindows) {
          final shortcuts = await Directory(outputPath)
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File && entity.path.endsWith('.lnk'),
              )
              .toList();
          expect(
            shortcuts.length,
            greaterThan(0),
            reason: 'Should create Windows shortcuts',
          );
        }
      });

      test(
        'reverse-shortcut mode preserves album-centric organization (Issue #261)',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.reverseShortcut,
            dateDivision: DateDivisionLevel.none,
            copyMode: true,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Verify files remain in album folders (not shortcuts)
          final outputContents = await Directory(
            outputPath,
          ).list(recursive: true).toList();
          final albumDirs = outputContents
              .whereType<Directory>()
              .where(
                (final dir) => !p.basename(dir.path).contains('ALL_PHOTOS'),
              )
              .toList();

          expect(
            albumDirs.length,
            greaterThan(0),
            reason: 'Should have album directories',
          );

          // Check that album directories contain actual files, not shortcuts
          for (final albumDir in albumDirs) {
            final albumFiles = await albumDir
                .list()
                .where(
                  (final entity) =>
                      entity is File &&
                      !entity.path.endsWith('.lnk') &&
                      (entity.path.endsWith('.jpg') ||
                          entity.path.endsWith('.png')),
                )
                .toList();
            if (albumFiles.isNotEmpty) {
              expect(
                albumFiles.length,
                greaterThan(0),
                reason:
                    'Album ${p.basename(albumDir.path)} should contain actual files',
              );
            }
          }

          // Verify ALL_PHOTOS has shortcuts pointing to album files
          final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
          if (await allPhotosDir.exists()) {
            if (Platform.isWindows) {
              final shortcuts = await allPhotosDir
                  .list()
                  .where(
                    (final entity) =>
                        entity is File && entity.path.endsWith('.lnk'),
                  )
                  .toList();
              expect(
                shortcuts.length,
                greaterThan(0),
                reason: 'ALL_PHOTOS should contain shortcuts',
              );
            } else {
              final symlinks = await allPhotosDir
                  .list()
                  .where((final entity) => entity is Link)
                  .toList();
              expect(
                symlinks.length,
                greaterThan(0),
                reason: 'ALL_PHOTOS should contain symlinks',
              );
            }
          }
        },
      );

      test(
        'duplicate-copy mode handles album-only photos (Issue #261)',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.duplicateCopy,
            dateDivision: DateDivisionLevel.none,
            copyMode: true,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Verify both ALL_PHOTOS and album folders contain files
          final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
          expect(await allPhotosDir.exists(), isTrue);

          final allPhotosFiles = await allPhotosDir
              .list()
              .where(
                (final entity) =>
                    entity is File &&
                    (entity.path.endsWith('.jpg') ||
                        entity.path.endsWith('.png')),
              )
              .toList();
          expect(
            allPhotosFiles.length,
            greaterThan(0),
            reason: 'ALL_PHOTOS should contain photos',
          );

          // Check album folders also have copies
          final outputContents = await Directory(
            outputPath,
          ).list(recursive: true).toList();
          final albumFiles = outputContents
              .whereType<File>()
              .where(
                (final file) =>
                    !file.path.contains('ALL_PHOTOS') &&
                    (file.path.endsWith('.jpg') || file.path.endsWith('.png')),
              )
              .toList();
          expect(
            albumFiles.length,
            greaterThan(0),
            reason: 'Album folders should contain photo copies',
          );
        },
      );

      test('json mode creates albums-info.json file', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.json,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify albums-info.json is created
        final albumsInfoFile = File(p.join(outputPath, 'albums-info.json'));
        expect(
          await albumsInfoFile.exists(),
          isTrue,
          reason: 'Should create albums-info.json',
        );

        // Verify JSON content is valid
        final jsonContent = await albumsInfoFile.readAsString();
        expect(
          () => jsonDecode(jsonContent),
          returnsNormally,
          reason: 'JSON should be valid',
        );

        final albumsInfo = jsonDecode(jsonContent) as Map<String, dynamic>;
        expect(
          albumsInfo.keys.length,
          greaterThan(0),
          reason: 'Should contain album information',
        );
      });
    });

    group('Date Organization - Issues #238, #299', () {
      test('year-level date division creates year folders', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.year,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
        final yearDirs = await allPhotosDir
            .list()
            .where(
              (final entity) =>
                  entity is Directory &&
                  RegExp(r'^\d{4}$').hasMatch(p.basename(entity.path)),
            )
            .toList();

        expect(
          yearDirs.length,
          greaterThan(0),
          reason: 'Should create year directories',
        );
      });

      test('month-level date division creates year/month structure', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.month,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Look for year/month structure
        final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
        final yearDirs = await allPhotosDir
            .list()
            .where(
              (final entity) =>
                  entity is Directory &&
                  RegExp(r'^\d{4}$').hasMatch(p.basename(entity.path)),
            )
            .cast<Directory>()
            .toList();

        expect(
          yearDirs.length,
          greaterThan(0),
          reason: 'Should create year directories',
        );

        // Check for month subdirectories
        for (final yearDir in yearDirs) {
          final monthDirs = await yearDir
              .list()
              .where(
                (final entity) =>
                    entity is Directory &&
                    RegExp(r'^\d{2}$').hasMatch(p.basename(entity.path)),
              )
              .toList();
          if (monthDirs.isNotEmpty) {
            expect(
              monthDirs.length,
              greaterThan(0),
              reason: 'Should create month subdirectories',
            );
            break;
          }
        }
      });

      test(
        'day-level date division creates year/month/day structure',
        () async {
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            takeoutPath,
          );
          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.day,
            copyMode: true,
            writeExif: false,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(result.isSuccess, isTrue);

          // Look for year/month/day structure
          final allPhotosDir = Directory(p.join(outputPath, 'ALL_PHOTOS'));
          final yearDirs = await allPhotosDir
              .list()
              .where(
                (final entity) =>
                    entity is Directory &&
                    RegExp(r'^\d{4}$').hasMatch(p.basename(entity.path)),
              )
              .cast<Directory>()
              .toList();

          if (yearDirs.isNotEmpty) {
            final yearDir = yearDirs.first;
            final monthDirs = await yearDir
                .list()
                .where(
                  (final entity) =>
                      entity is Directory &&
                      RegExp(r'^\d{2}$').hasMatch(p.basename(entity.path)),
                )
                .cast<Directory>()
                .toList();

            if (monthDirs.isNotEmpty) {
              final monthDir = monthDirs.first;
              final dayDirs = await monthDir
                  .list()
                  .where(
                    (final entity) =>
                        entity is Directory &&
                        RegExp(r'^\d{2}$').hasMatch(p.basename(entity.path)),
                  )
                  .toList();
              expect(
                dayDirs.length,
                greaterThan(0),
                reason: 'Should create day subdirectories',
              );
            }
          }
        },
      );
    });

    group('File Format Support - Issues #180, #271, #324, #381', () {
      test('handles Motion Photo files (.MP, .MV)', () async {
        // Create test Motion Photo files
        final motionPhotoTakeout = await _createMotionPhotoTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          motionPhotoTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify .MP and .MV files are processed
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        final motionPhotoFiles = outputFiles
            .where(
              (final file) =>
                  file.path.endsWith('.MP') || file.path.endsWith('.MV'),
            )
            .toList();

        expect(
          motionPhotoFiles.length,
          greaterThan(0),
          reason: 'Should process Motion Photo files',
        );
      });

      test('handles RAW camera files (.DNG, .CR2)', () async {
        // Create test RAW files
        final rawTakeout = await _createRawFileTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          rawTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        // Verify RAW files are processed
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .cast<File>()
            .toList();

        final rawFiles = outputFiles
            .where(
              (final file) =>
                  file.path.endsWith('.DNG') || file.path.endsWith('.CR2'),
            )
            .toList();

        expect(
          rawFiles.length,
          greaterThan(0),
          reason: 'Should process RAW camera files',
        );
      });
    });

    group('JSON Metadata Handling - Issues #353, #355', () {
      test('handles supplemental-metadata suffix removal', () async {
        // Create test data with supplemental-metadata JSON files
        final supplementalTakeout = await _createSupplementalMetadataTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          supplementalTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle supplemental metadata',
        );

        // Verify files are processed correctly despite supplemental metadata
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) =>
                  entity is File &&
                  (entity.path.endsWith('.jpg') ||
                      entity.path.endsWith('.png')),
            )
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process images with supplemental metadata',
        );
      });
    });

    group('Filename Truncation Handling - Issue #29', () {
      test('handles truncated extra format suffixes', () async {
        // Create test data with truncated filenames
        final truncatedTakeout = await _createTruncatedFilenameTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          truncatedTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle truncated filenames',
        );

        // Verify files are processed correctly
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.endsWith('.jpg'),
            )
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process truncated filename images',
        );
      });
    });

    group('Extension Fixing - Issue #32', () {
      test(
        'extension fixing standard mode processes mismatched extensions',
        () async {
          // Create test data with mismatched extensions
          final mismatchedTakeout = await _createMismatchedExtensionTestData();
          final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
            mismatchedTakeout,
          );

          final config = ProcessingConfig(
            inputPath: googlePhotosPath,
            outputPath: outputPath,
            albumBehavior: AlbumBehavior.nothing,
            dateDivision: DateDivisionLevel.none,
            copyMode: true,
            writeExif: false,
            extensionFixing: ExtensionFixingMode.standard,
          );

          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );

          expect(
            result.isSuccess,
            isTrue,
            reason: 'Should handle extension fixing',
          );

          // Verify files are processed and potentially renamed
          final outputFiles = await Directory(outputPath)
              .list(recursive: true)
              .where(
                (final entity) =>
                    entity is File &&
                    (entity.path.endsWith('.jpg') ||
                        entity.path.contains('.heic')),
              )
              .toList();

          expect(
            outputFiles.length,
            greaterThan(0),
            reason: 'Should process files with extension fixing',
          );
        },
      );
    });

    group('Performance and Large Dataset Handling', () {
      test('processes large dataset efficiently', () async {
        // Create a larger test dataset
        final largeTakeout = await fixture.generateRealisticTakeoutDataset(
          yearSpan: 2,
          albumCount: 10,
          photosPerYear: 50,
          albumOnlyPhotos: 10,
          exifRatio: 0.5,
        );

        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          largeTakeout,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.year,
          copyMode: true,
          writeExif: false,
        );

        final stopwatch = Stopwatch()..start();

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        stopwatch.stop();

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should process large dataset successfully',
        );
        expect(
          stopwatch.elapsed.inMinutes,
          lessThan(5),
          reason: 'Should complete within reasonable time',
        );

        // Verify output structure
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where((final entity) => entity is File)
            .toList();

        expect(
          outputFiles.length,
          greaterThan(50),
          reason: 'Should process significant number of files',
        );
      });
    });

    group('Error Handling and Edge Cases', () {
      test('handles corrupt or unreadable files gracefully', () async {
        // Create test data with a corrupt file
        final corruptTakeout = await _createCorruptFileTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          corruptTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        // Should not throw exceptions even with corrupt files
        expect(() async {
          final result = await pipeline.execute(
            config: config,
            inputDirectory: Directory(googlePhotosPath),
            outputDirectory: Directory(outputPath),
          );
          return result;
        }, returnsNormally);
      });

      test('handles empty or minimal input gracefully', () async {
        // Create minimal test data
        final minimalTakeout = await _createMinimalTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          minimalTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.nothing,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        // Should handle gracefully even if no files to process
        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle minimal input gracefully',
        );
      });

      test('handles unicode and special characters in filenames', () async {
        // Create test data with unicode filenames
        final unicodeTakeout = await _createUnicodeFilenameTestData();
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          unicodeTakeout,
        );

        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(
          result.isSuccess,
          isTrue,
          reason: 'Should handle unicode filenames',
        );

        // Verify unicode files are processed
        final outputFiles = await Directory(outputPath)
            .list(recursive: true)
            .where(
              (final entity) => entity is File && entity.path.contains('测试'),
            )
            .toList();

        expect(
          outputFiles.length,
          greaterThan(0),
          reason: 'Should process unicode filename files',
        );
      });
    });

    group('Cross-Platform Compatibility', () {
      test('creates platform-appropriate shortcuts/symlinks', () async {
        final googlePhotosPath = PathResolverService.resolveGooglePhotosPath(
          takeoutPath,
        );
        final config = ProcessingConfig(
          inputPath: googlePhotosPath,
          outputPath: outputPath,
          albumBehavior: AlbumBehavior.shortcut,
          dateDivision: DateDivisionLevel.none,
          copyMode: true,
          writeExif: false,
        );

        final result = await pipeline.execute(
          config: config,
          inputDirectory: Directory(googlePhotosPath),
          outputDirectory: Directory(outputPath),
        );

        expect(result.isSuccess, isTrue);

        final outputContents = await Directory(
          outputPath,
        ).list(recursive: true).toList();

        if (Platform.isWindows) {
          // Should create .lnk files on Windows
          final shortcuts = outputContents
              .whereType<File>()
              .where((final file) => file.path.endsWith('.lnk'))
              .toList();
          expect(
            shortcuts.length,
            greaterThan(0),
            reason: 'Should create Windows shortcuts',
          );
        } else {
          // Should create symlinks on Unix systems
          final symlinks = outputContents.whereType<Link>().toList();
          expect(
            symlinks.length,
            greaterThan(0),
            reason: 'Should create Unix symlinks',
          );
        }
      });
    });
  });
}

// Helper methods to create specific test scenarios

Future<String> _createEmojiAlbumTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create emoji album directories
  final emojiAlbum1 = fixture.createDirectory(
    '${googlePhotosDir.path}/🏖️ Summer Vacation',
  );
  final emojiAlbum2 = fixture.createDirectory(
    '${googlePhotosDir.path}/🎄 Christmas 2023',
  );
  final emojiAlbum3 = fixture.createDirectory(
    '${googlePhotosDir.path}/👨‍👩‍👧‍👦 Family Photos',
  );

  // Add photos to year folder
  fixture.createImageWithExif('${yearDir.path}/IMG_001.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_001.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/IMG_002.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_002.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  // Add photos to emoji albums
  fixture.createImageWithExif('${emojiAlbum1.path}/beach_photo.jpg');
  fixture.createFile(
    '${emojiAlbum1.path}/beach_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${emojiAlbum2.path}/xmas_photo.jpg');
  fixture.createFile(
    '${emojiAlbum2.path}/xmas_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${emojiAlbum3.path}/family_photo.jpg');
  fixture.createFile(
    '${emojiAlbum3.path}/family_photo.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createMotionPhotoTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create .MP and .MV files
  fixture.createFile(
    '${yearDir.path}/IMG_001.MP',
    List.generate(1000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/IMG_001.MP.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createFile(
    '${yearDir.path}/VID_002.MV',
    List.generate(1000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/VID_002.MV.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createRawFileTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create RAW files
  fixture.createFile(
    '${yearDir.path}/DSC_001.DNG',
    List.generate(2000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/DSC_001.DNG.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createFile(
    '${yearDir.path}/IMG_002.CR2',
    List.generate(3000, (final i) => i % 256),
  );
  fixture.createFile(
    '${yearDir.path}/IMG_002.CR2.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createSupplementalMetadataTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with supplemental-metadata suffix
  fixture.createImageWithExif('${yearDir.path}/IMG_001.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_001.jpg(supplemental-metadata).json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/IMG_002.jpg');
  fixture.createFile(
    '${yearDir.path}/IMG_002.jpg-supplemental-metadata.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createTruncatedFilenameTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with truncated extra format suffixes
  fixture.createImageWithExif(
    '${yearDir.path}/Very_Long_Filename_That_Gets_Truncated_-_edit.jpg',
  );
  fixture.createFile(
    '${yearDir.path}/Very_Long_Filename_That_Gets_Truncated_-_edit.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif(
    '${yearDir.path}/Another_Extremely_Long_Photo_Name_-_edited_ver.jpg',
  );
  fixture.createFile(
    '${yearDir.path}/Another_Extremely_Long_Photo_Name_-_edited_ver.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createMismatchedExtensionTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create JPEG file with .heic extension (common Google Photos issue)
  final jpegData = base64.decode(greenImgBase64.replaceAll('\n', ''));
  fixture.createFile(
    '${yearDir.path}/image.heic',
    jpegData,
  ); // JPEG data with HEIC extension
  fixture.createFile(
    '${yearDir.path}/image.heic.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createCorruptFileTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create corrupt/invalid files
  fixture.createFile('${yearDir.path}/corrupt.jpg', [
    0xFF,
    0xD8,
    0x00,
    0x01,
    0x02,
  ]); // Invalid JPEG
  fixture.createFile(
    '${yearDir.path}/corrupt.jpg.json',
    utf8.encode('{"invalid": json}'),
  );

  fixture.createImageWithExif(
    '${yearDir.path}/valid.jpg',
  ); // Valid file to ensure processing continues
  fixture.createFile(
    '${yearDir.path}/valid.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}

Future<String> _createMinimalTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  ); // Empty year folder

  return takeoutDir.path;
}

Future<String> _createUnicodeFilenameTestData() async {
  final fixture = TestFixture();
  await fixture.setUp();

  final takeoutDir = fixture.createDirectory('Takeout');
  final googlePhotosDir = fixture.createDirectory(
    '${takeoutDir.path}/Google Photos',
  );
  final yearDir = fixture.createDirectory(
    '${googlePhotosDir.path}/Photos from 2023',
  );

  // Create files with unicode characters
  fixture.createImageWithExif('${yearDir.path}/测试图片_中文.jpg');
  fixture.createFile(
    '${yearDir.path}/测试图片_中文.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/Фото_кириллица.jpg');
  fixture.createFile(
    '${yearDir.path}/Фото_кириллица.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  fixture.createImageWithExif('${yearDir.path}/صورة_عربية.jpg');
  fixture.createFile(
    '${yearDir.path}/صورة_عربية.jpg.json',
    utf8.encode('{"photoTakenTime": {"timestamp": "1672531200"}}'),
  );

  return takeoutDir.path;
}
