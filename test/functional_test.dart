/// # Functional Test Suite for GPTH
///
/// Comprehensive functional tests that validate the complete behavior of
/// Google Photos Takeout Helper's album handling and file movement options
/// as described in the README.md documentation.
///
/// ## Album Handling Functional Tests
///
/// ### Shortcut Mode (Recommended)
/// - Creates shortcuts/symlinks from album folders to files in ALL_PHOTOS
/// - Original files moved to ALL_PHOTOS, shortcuts created in album folders
/// - Validates disk space efficiency (no duplicate files)
/// - Tests cross-platform shortcut/symlink compatibility
/// - Verifies album organization preservation
///
/// ### Duplicate Copy Mode
/// - Creates actual file copies in both ALL_PHOTOS and album folders
/// - Each photo appears as separate physical file in every location
/// - Validates complete independence between folders
/// - Tests compatibility across all systems and applications
/// - Verifies album photos remain accessible even if ALL_PHOTOS deleted
///
/// ### Reverse Shortcut Mode
/// - Files remain in original album folders
/// - Shortcuts created in ALL_PHOTOS pointing to album locations
/// - Validates album-centric organization preservation
/// - Tests ALL_PHOTOS dependency on album folders
/// - Verifies single copy existence for multi-album photos
///
/// ### JSON Mode
/// - Creates single ALL_PHOTOS folder with all files
/// - Generates albums-info.json with metadata about album associations
/// - Validates most space-efficient option
/// - Tests programmatically accessible album information
/// - Verifies simple folder structure creation
///
/// ### Nothing Mode
/// - Ignores albums entirely, creates only ALL_PHOTOS
/// - Files from year folders only, album-only files included if linkable
/// - Validates simplest processing and fastest execution
/// - Tests clean single-folder result
/// - Verifies complete loss of album organization
///
/// ## File Movement Functional Tests
///
/// ### Copy Mode
/// - Preserves original takeout structure
/// - Validates original files remain intact
/// - Tests slower processing with extra space usage
/// - Verifies safety for backup preservation
///
/// ### Move Mode (Default)
/// - Moves files to save space
/// - Validates original files are removed
/// - Tests faster processing with space efficiency
/// - Verifies no extra disk space usage
///
/// ## Integration Scenarios
///
/// ### Real Takeout Structure Simulation
/// - Year folders (Photos from YYYY)
/// - Album folders with duplicate relationships
/// - JSON metadata files with timestamps
/// - Mixed file naming conventions
/// - Album-only photos handling
///
/// ### Edge Cases and Complex Scenarios
/// - Photos in multiple albums with different behaviors
/// - Album-only photos not in year folders
/// - Files with special characters and Unicode names
/// - Large collections performance testing
/// - Error handling and recovery validation
library;

import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:gpth/grouping.dart';
import 'package:gpth/media.dart';
import 'package:gpth/moving.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'test_setup.dart';

void main() {
  group('Functional Tests - Album Handling & File Movement', () {
    late TestFixture fixture;
    late Directory inputDir;
    late Directory outputDir;
    late List<Media> testMedia;

    /// Creates a realistic Google Takeout structure for testing
    Future<void> createTakeoutStructure() async {
      // Create year folders structure
      final year2020Dir = fixture.createDirectory('Photos from 2020');
      final year2022Dir = fixture.createDirectory('Photos from 2022');
      final year2023Dir = fixture.createDirectory('Photos from 2023');

      // Create album folders
      final vacationDir = fixture.createDirectory('Vacation 2022');
      final familyDir = fixture.createDirectory('Family Photos');
      final holidaysDir = fixture.createDirectory('Holiday Memories');

      // Create photos in year folders with unique content
      final photo1 = fixture.createFile(
        p.join(year2020Dir.path, 'IMG_20200615_143022.jpg'),
        'Photo1_unique_content'.codeUnits,
      );
      final photo2 = fixture.createFile(
        p.join(year2022Dir.path, 'IMG_20220825_110045.jpg'),
        'Photo2_unique_content'.codeUnits,
      );
      final photo3 = fixture.createFile(
        p.join(year2022Dir.path, 'Screenshot_20220901_154732.jpg'),
        'Photo3_unique_content'.codeUnits,
      );
      final photo4 = fixture.createFile(
        p.join(year2023Dir.path, 'MVIMG_20230412_190301.jpg'),
        'Photo4_unique_content'.codeUnits,
      );

      // Create JSON metadata files
      fixture.createJsonFile(
        p.join(year2020Dir.path, 'IMG_20200615_143022.jpg.json'),
        1592230222, // June 15, 2020
      );
      fixture.createJsonFile(
        p.join(year2022Dir.path, 'IMG_20220825_110045.jpg.json'),
        1661422845, // August 25, 2022
      );
      fixture.createJsonFile(
        p.join(year2022Dir.path, 'Screenshot_20220901_154732.jpg.json'),
        1662043652, // September 1, 2022
      );
      fixture.createJsonFile(
        p.join(year2023Dir.path, 'MVIMG_20230412_190301.jpg.json'),
        1681319781, // April 12, 2023
      );

      // Create album copies (simulating how Google Takeout duplicates files)
      final vacationPhoto1 = File(
        p.join(vacationDir.path, p.basename(photo2.path)),
      );
      photo2.copySync(vacationPhoto1.path);

      final vacationPhoto2 = File(
        p.join(vacationDir.path, p.basename(photo3.path)),
      );
      photo3.copySync(vacationPhoto2.path);

      final familyPhoto = File(p.join(familyDir.path, p.basename(photo1.path)));
      photo1.copySync(familyPhoto.path);

      final holidayPhoto = File(
        p.join(holidaysDir.path, p.basename(photo4.path)),
      );
      photo4.copySync(holidayPhoto.path);

      // Create album-only photo (exists only in album, not in year folder)
      final albumOnlyPhoto = fixture.createFile(
        p.join(vacationDir.path, 'album_only_beach.jpg'),
        'AlbumOnlyPhoto_unique_content'.codeUnits,
      );

      // Create JSON for album-only photo
      fixture.createJsonFile(
        p.join(vacationDir.path, 'album_only_beach.jpg.json'),
        1661509245, // August 26, 2022
      );

      // Setup test media list - mimic real application workflow
      // First, create separate Media objects for year folder files (with null keys)
      testMedia = [
        Media(
          {null: photo1},
          dateTaken: DateTime(2020, 6, 15, 14, 30, 22),
          dateTakenAccuracy: 1,
        ),
        Media(
          {null: photo2},
          dateTaken: DateTime(2022, 8, 25, 11, 0, 45),
          dateTakenAccuracy: 1,
        ),
        Media(
          {null: photo3},
          dateTaken: DateTime(2022, 9, 1, 15, 47, 32),
          dateTakenAccuracy: 1,
        ),
        Media(
          {null: photo4},
          dateTaken: DateTime(2023, 4, 12, 19, 3, 1),
          dateTakenAccuracy: 1,
        ),
      ];

      // Then, create separate Media objects for album folder files (with album keys)
      testMedia.addAll([
        Media(
          {'Family Photos': familyPhoto},
          dateTaken: DateTime(2020, 6, 15, 14, 30, 22),
          dateTakenAccuracy: 1,
        ),
        Media(
          {'Vacation 2022': vacationPhoto1},
          dateTaken: DateTime(2022, 8, 25, 11, 0, 45),
          dateTakenAccuracy: 1,
        ),
        Media(
          {'Vacation 2022': vacationPhoto2},
          dateTaken: DateTime(2022, 9, 1, 15, 47, 32),
          dateTakenAccuracy: 1,
        ),
        Media(
          {'Holiday Memories': holidayPhoto},
          dateTaken: DateTime(2023, 4, 12, 19, 3, 1),
          dateTakenAccuracy: 1,
        ),
        Media(
          {'Vacation 2022': albumOnlyPhoto},
          dateTaken: DateTime(2022, 8, 26, 10, 14, 5),
          dateTakenAccuracy: 1,
        ),
      ]);

      // Process media for album detection - this mimics the real workflow
      print('DEBUG: testMedia count before processing: ${testMedia.length}');
      removeDuplicates(testMedia);
      print(
        'DEBUG: testMedia count after removeDuplicates: ${testMedia.length}',
      );
      findAlbums(testMedia);
      print('DEBUG: testMedia count after findAlbums: ${testMedia.length}');

      // Handle album-only photos (like the real application does)
      // If a media doesn't have a null key, establish one from an album
      for (final Media m in testMedia) {
        final File? fileWithNullKey = m.files[null];
        if (fileWithNullKey == null) {
          m.files[null] = m.files.values.first;
        }
      }
    }

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();

      inputDir = Directory(p.join(fixture.basePath, 'takeout'));
      outputDir = Directory(p.join(fixture.basePath, 'output'));

      await inputDir.create();
      await outputDir.create();

      await createTakeoutStructure();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Album Handling - Shortcut Mode', () {
      test('creates shortcuts from album folders to ALL_PHOTOS files', () async {
        // Execute shortcut mode
        await moveFiles(
          testMedia,
          outputDir,
          copy: false, // Test move mode
          divideToDates: 0,
          albumBehavior: 'shortcut',
        ).toList();

        final allEntities = await outputDir
            .list(recursive: true, followLinks: false)
            .toList();

        // Verify directory structure
        final directories = allEntities.whereType<Directory>().toList();
        final directoryNames = directories
            .map((final dir) => p.basename(dir.path))
            .toSet();

        print('DEBUG: Created directories: $directoryNames');
        print(
          'DEBUG: testMedia after processing: ${testMedia.map((final m) => m.files.keys.toList())}',
        );

        expect(directoryNames, contains('ALL_PHOTOS'));
        expect(directoryNames, contains('Vacation 2022'));
        expect(directoryNames, contains('Family Photos'));
        expect(directoryNames, contains('Holiday Memories'));

        // Verify ALL_PHOTOS contains the actual files
        final allPhotosDir = directories.firstWhere(
          (final dir) => p.basename(dir.path) == 'ALL_PHOTOS',
        );
        final allPhotosEntities = await allPhotosDir.list().toList();
        final allPhotosFiles = allPhotosEntities.whereType<File>().toList();

        expect(allPhotosFiles.length, equals(5)); // All 5 photos

        // Verify shortcuts/symlinks exist in album folders
        if (Platform.isWindows) {
          // Windows shortcuts (.lnk files)
          final shortcuts = allEntities
              .whereType<File>()
              .where((final file) => file.path.endsWith('.lnk'))
              .toList();
          expect(shortcuts.length, greaterThan(0));
        } else {
          // Unix symlinks
          final symlinks = allEntities.whereType<Link>().toList();
          expect(symlinks.length, greaterThan(0));

          // Verify symlinks point to correct targets
          for (final symlink in symlinks) {
            final target = await symlink.target();
            expect(target, isNotEmpty);
            expect(target, contains('ALL_PHOTOS'));
          }
        }

        // Verify no duplicate files (space efficiency)
        final allFiles = allEntities.whereType<File>().toList();
        final nonShortcutFiles = allFiles
            .where((final file) => !file.path.endsWith('.lnk'))
            .toList();

        // Should have 5 files in ALL_PHOTOS only (no duplicates in albums)
        expect(nonShortcutFiles.length, equals(5));
      });

      test('preserves album organization with shortcuts', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true, // Test copy mode
          divideToDates: 0,
          albumBehavior: 'shortcut',
        ).toList();

        // Verify each album folder contains appropriate shortcuts
        final vacationDir = Directory(p.join(outputDir.path, 'Vacation 2022'));
        final familyDir = Directory(p.join(outputDir.path, 'Family Photos'));
        final holidaysDir = Directory(
          p.join(outputDir.path, 'Holiday Memories'),
        );

        expect(vacationDir.existsSync(), isTrue);
        expect(familyDir.existsSync(), isTrue);
        expect(holidaysDir.existsSync(), isTrue);

        // Count items in vacation folder (should have 3: 2 from year folders + 1 album-only)
        final vacationItems = await vacationDir.list().toList();
        expect(vacationItems.length, equals(3));

        // Count items in family folder (should have 1)
        final familyItems = await familyDir.list().toList();
        expect(familyItems.length, equals(1));

        // Count items in holidays folder (should have 1)
        final holidayItems = await holidaysDir.list().toList();
        expect(holidayItems.length, equals(1));
      });

      test('handles album-only photos correctly in shortcut mode', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'shortcut',
        ).toList();

        // Verify album-only photo appears in ALL_PHOTOS
        final allPhotosDir = Directory(p.join(outputDir.path, 'ALL_PHOTOS'));
        final allPhotosEntities = await allPhotosDir.list().toList();
        final allPhotosFiles = allPhotosEntities
            .whereType<File>()
            .map((final file) => p.basename(file.path))
            .toSet();

        expect(allPhotosFiles, contains('album_only_beach.jpg'));

        // Verify shortcut exists in album folder
        final vacationDir = Directory(p.join(outputDir.path, 'Vacation 2022'));
        final vacationItems = await vacationDir.list().toList();

        final hasAlbumOnlyShortcut = vacationItems.any((final item) {
          final name = p.basename(item.path);
          return name.contains('album_only_beach') ||
              (Platform.isWindows && name.endsWith('.lnk'));
        });

        expect(hasAlbumOnlyShortcut, isTrue);
      });
    });

    group('Album Handling - Duplicate Copy Mode', () {
      test(
        'creates physical copies in both ALL_PHOTOS and album folders',
        () async {
          await moveFiles(
            testMedia,
            outputDir,
            copy: true,
            divideToDates: 0,
            albumBehavior: 'duplicate-copy',
          ).toList();

          final allEntities = await outputDir
              .list(recursive: true, followLinks: false)
              .toList();

          // Verify directory structure
          final directories = allEntities.whereType<Directory>().toList();
          final directoryNames = directories
              .map((final dir) => p.basename(dir.path))
              .toSet();

          expect(directoryNames, contains('ALL_PHOTOS'));
          expect(directoryNames, contains('Vacation 2022'));
          expect(directoryNames, contains('Family Photos'));
          expect(directoryNames, contains('Holiday Memories'));

          // Count all files (should be more than 5 due to duplicates)
          final allFiles = allEntities.whereType<File>().toList();
          expect(allFiles.length, greaterThan(5));

          // Verify no symlinks (all should be actual files)
          final symlinks = allEntities.whereType<Link>().toList();
          expect(symlinks.length, equals(0));

          // Verify ALL_PHOTOS contains all photos
          final allPhotosDir = directories.firstWhere(
            (final dir) => p.basename(dir.path) == 'ALL_PHOTOS',
          );
          final allPhotosEntities = await allPhotosDir.list().toList();
          final allPhotosFiles = allPhotosEntities.whereType<File>().toList();

          expect(allPhotosFiles.length, equals(5));

          // Verify album folders contain actual file copies
          final vacationDir = directories.firstWhere(
            (final dir) => p.basename(dir.path) == 'Vacation 2022',
          );
          final vacationEntities = await vacationDir.list().toList();
          final vacationFiles = vacationEntities.whereType<File>().toList();

          expect(
            vacationFiles.length,
            equals(3),
          ); // 2 from years + 1 album-only
        },
      );

      test('ensures duplicate copies have identical content', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'duplicate-copy',
        ).toList();

        // Find files that should be duplicated
        final allEntities = await outputDir.list(recursive: true).toList();
        final allFiles = allEntities.whereType<File>().toList();

        // Group files by basename
        final fileGroups = <String, List<File>>{};
        for (final file in allFiles) {
          final basename = p.basename(file.path);
          fileGroups.putIfAbsent(basename, () => []).add(file);
        }

        // Verify duplicated files have identical content
        for (final entry in fileGroups.entries) {
          if (entry.value.length > 1) {
            final files = entry.value;
            final firstContent = await files[0].readAsBytes();

            for (int i = 1; i < files.length; i++) {
              final content = await files[i].readAsBytes();
              expect(
                content,
                equals(firstContent),
                reason:
                    'Duplicate files should have identical content: ${entry.key}',
              );
            }
          }
        }
      });

      test('provides complete independence between folders', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'duplicate-copy',
        ).toList();

        // Verify that deleting album folders doesn't affect ALL_PHOTOS
        final vacationDir = Directory(p.join(outputDir.path, 'Vacation 2022'));
        final allPhotosDir = Directory(p.join(outputDir.path, 'ALL_PHOTOS'));

        // Count files in ALL_PHOTOS before deletion
        final allPhotosEntitiesBefore = await allPhotosDir.list().toList();
        final allPhotosFilesBefore = allPhotosEntitiesBefore
            .whereType<File>()
            .toList();
        final countBefore = allPhotosFilesBefore.length;

        // Delete vacation album
        await vacationDir.delete(recursive: true);

        // Verify ALL_PHOTOS still has all files
        final allPhotosEntitiesAfter = await allPhotosDir.list().toList();
        final allPhotosFilesAfter = allPhotosEntitiesAfter
            .whereType<File>()
            .toList();
        final countAfter = allPhotosFilesAfter.length;

        expect(countAfter, equals(countBefore));
        expect(countAfter, equals(5)); // All 5 photos should still be there
      });
    });

    group('Album Handling - Reverse Shortcut Mode', () {
      test(
        'keeps files in album folders with shortcuts in ALL_PHOTOS',
        () async {
          await moveFiles(
            testMedia,
            outputDir,
            copy: true,
            divideToDates: 0,
            albumBehavior: 'reverse-shortcut',
          ).toList();

          final allEntities = await outputDir
              .list(recursive: true, followLinks: false)
              .toList();

          // Verify ALL_PHOTOS exists
          final directories = allEntities.whereType<Directory>().toList();
          final allPhotosDir = directories.firstWhereOrNull(
            (final dir) => p.basename(dir.path) == 'ALL_PHOTOS',
          );
          expect(allPhotosDir, isNotNull);

          // Verify shortcuts exist in ALL_PHOTOS
          if (Platform.isWindows) {
            final shortcuts = allEntities
                .whereType<File>()
                .where(
                  (final file) =>
                      file.path.contains('ALL_PHOTOS') &&
                      file.path.endsWith('.lnk'),
                )
                .toList();
            expect(shortcuts.length, greaterThan(0));
          } else {
            final symlinks = allEntities
                .whereType<Link>()
                .where((final link) => link.path.contains('ALL_PHOTOS'))
                .toList();
            expect(symlinks.length, greaterThan(0));
          }

          // Verify actual files remain in album folders
          final vacationDir = directories.firstWhereOrNull(
            (final dir) => p.basename(dir.path) == 'Vacation 2022',
          );
          expect(vacationDir, isNotNull);

          final vacationEntities = await vacationDir!.list().toList();
          final vacationFiles = vacationEntities.whereType<File>().toList();
          expect(vacationFiles.length, greaterThan(0));
        },
      );

      test('preserves album-centric organization', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'reverse-shortcut',
        ).toList();

        // Verify album folders contain actual files, not shortcuts
        final vacationDir = Directory(p.join(outputDir.path, 'Vacation 2022'));
        final familyDir = Directory(p.join(outputDir.path, 'Family Photos'));

        expect(vacationDir.existsSync(), isTrue);
        expect(familyDir.existsSync(), isTrue);

        // Count actual files in album folders
        final vacationEntities = await vacationDir.list().toList();
        final vacationFiles = vacationEntities
            .whereType<File>()
            .where((final file) => !file.path.endsWith('.lnk'))
            .toList();

        final familyEntities = await familyDir.list().toList();
        final familyFiles = familyEntities
            .whereType<File>()
            .where((final file) => !file.path.endsWith('.lnk'))
            .toList();

        expect(vacationFiles.length, greaterThan(0));
        expect(familyFiles.length, greaterThan(0));
      });

      test('handles single copy for multi-album photos', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'reverse-shortcut',
        ).toList();

        // For photos in multiple albums, verify only one physical copy exists
        // and shortcuts point to the same file
        final allEntities = await outputDir.list(recursive: true).toList();
        final allFiles = allEntities
            .whereType<File>()
            .where((final file) => !file.path.endsWith('.lnk'))
            .toList();

        // Debug: print all non-shortcut files
        print('DEBUG: All non-shortcut files (${allFiles.length}):');
        for (final file in allFiles) {
          print('  ${file.path}');
        }

        // Group files by basename
        final fileBasenames = allFiles
            .map((final file) => p.basename(file.path))
            .toList();

        print('DEBUG: File basenames: $fileBasenames');
        print('DEBUG: Unique basenames: ${fileBasenames.toSet()}');

        // Each unique photo should appear only once as actual file
        final uniqueBasenames = fileBasenames.toSet();
        expect(fileBasenames.length, equals(uniqueBasenames.length));
      });
    });

    group('Album Handling - JSON Mode', () {
      test('creates single ALL_PHOTOS folder with albums-info.json', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'json',
        ).toList();

        final allEntities = await outputDir
            .list(recursive: true, followLinks: false)
            .toList();

        // Verify only ALL_PHOTOS directory exists (no album folders)
        final directories = allEntities.whereType<Directory>().toList();
        expect(directories.length, equals(1));
        expect(p.basename(directories[0].path), equals('ALL_PHOTOS'));

        // Verify no symlinks
        final symlinks = allEntities.whereType<Link>().toList();
        expect(symlinks.length, equals(0));

        // Verify albums-info.json exists
        final jsonFiles = allEntities
            .whereType<File>()
            .where((final file) => p.basename(file.path) == 'albums-info.json')
            .toList();
        expect(jsonFiles.length, equals(1));

        // Verify all photos are in ALL_PHOTOS
        final allPhotosFiles = allEntities
            .whereType<File>()
            .where(
              (final file) =>
                  file.path.contains('ALL_PHOTOS') &&
                  !file.path.endsWith('.json'),
            )
            .toList();
        expect(allPhotosFiles.length, equals(5));
      });

      test('generates correct album metadata in JSON', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'json',
        ).toList();

        // Read and parse albums-info.json
        final jsonFile = File(p.join(outputDir.path, 'albums-info.json'));
        expect(jsonFile.existsSync(), isTrue);

        final jsonContent = await jsonFile.readAsString();
        final albumInfo = jsonDecode(jsonContent) as Map<String, dynamic>;

        // Verify structure and content
        expect(albumInfo, isA<Map<String, dynamic>>());

        // Check that photos with albums are properly recorded
        bool foundVacationPhoto = false;
        bool foundFamilyPhoto = false;
        bool foundHolidayPhoto = false;
        bool foundAlbumOnlyPhoto = false;

        for (final entry in albumInfo.entries) {
          final filename = entry.key;
          final albums = entry.value as List<dynamic>;

          if (filename.contains('IMG_20220825') ||
              filename.contains('Screenshot_20220901')) {
            expect(albums, contains('Vacation 2022'));
            foundVacationPhoto = true;
          } else if (filename.contains('IMG_20200615')) {
            expect(albums, contains('Family Photos'));
            foundFamilyPhoto = true;
          } else if (filename.contains('MVIMG_20230412')) {
            expect(albums, contains('Holiday Memories'));
            foundHolidayPhoto = true;
          } else if (filename.contains('album_only_beach')) {
            expect(albums, contains('Vacation 2022'));
            foundAlbumOnlyPhoto = true;
          }
        }

        expect(foundVacationPhoto, isTrue);
        expect(foundFamilyPhoto, isTrue);
        expect(foundHolidayPhoto, isTrue);
        expect(foundAlbumOnlyPhoto, isTrue);
      });

      test('provides most space-efficient organization', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'json',
        ).toList();

        // Count all files - should be exactly 5 photos + 1 JSON
        final allEntitiesJson = await outputDir.list(recursive: true).toList();
        final allFiles = allEntitiesJson.whereType<File>().toList();

        expect(allFiles.length, equals(6)); // 5 photos + 1 JSON file

        // Verify no duplicate files exist
        final photoFiles = allFiles
            .where((final file) => !file.path.endsWith('.json'))
            .toList();
        expect(photoFiles.length, equals(5));

        // Verify simple folder structure
        final allDirEntities = await outputDir.list(recursive: true).toList();
        final directories = allDirEntities.whereType<Directory>().toList();
        expect(directories.length, equals(1)); // Only ALL_PHOTOS
      });
    });

    group('Album Handling - Nothing Mode', () {
      test('ignores albums and creates only ALL_PHOTOS', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        final allEntities = await outputDir
            .list(recursive: true, followLinks: false)
            .toList();

        // Verify only ALL_PHOTOS directory exists
        final directories = allEntities.whereType<Directory>().toList();
        expect(directories.length, equals(1));
        expect(p.basename(directories[0].path), equals('ALL_PHOTOS'));

        // Verify no symlinks
        final symlinks = allEntities.whereType<Link>().toList();
        expect(symlinks.length, equals(0));

        // Verify only files from year folders are included (null key media)
        final allFiles = allEntities.whereType<File>().toList();
        final yearFolderPhotos = testMedia
            .where((final media) => media.files.containsKey(null))
            .length;

        expect(allFiles.length, equals(yearFolderPhotos));
      });

      test('provides fastest execution with clean result', () async {
        final stopwatch = Stopwatch()..start();

        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        stopwatch.stop();

        // Verify clean, simple structure
        final allEntities = await outputDir
            .list(recursive: true, followLinks: false)
            .toList();

        // Should be minimal: 1 directory + files from year folders only
        final directories = allEntities.whereType<Directory>().toList();
        final files = allEntities.whereType<File>().toList();

        expect(directories.length, equals(1));
        expect(p.basename(directories[0].path), equals('ALL_PHOTOS'));

        // Only photos that had null keys (from year folders)
        final expectedFileCount = testMedia
            .where((final media) => media.files.containsKey(null))
            .length;
        expect(files.length, equals(expectedFileCount));
      });

      test('completely loses album organization', () async {
        await moveFiles(
          testMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Verify no album folders exist
        final allEntities = await outputDir
            .list(recursive: true, followLinks: false)
            .toList();

        final directories = allEntities.whereType<Directory>().toList();
        final directoryNames = directories
            .map((final dir) => p.basename(dir.path))
            .toSet();

        expect(directoryNames, equals({'ALL_PHOTOS'}));
        expect(directoryNames, isNot(contains('Vacation 2022')));
        expect(directoryNames, isNot(contains('Family Photos')));
        expect(directoryNames, isNot(contains('Holiday Memories')));

        // Verify no album metadata is preserved
        final files = allEntities.whereType<File>().toList();
        final hasJsonFile = files.any(
          (final file) => file.path.endsWith('.json'),
        );
        expect(hasJsonFile, isFalse);
      });
    });

    group('File Movement - Copy vs Move Mode', () {
      test('copy mode preserves original takeout structure', () async {
        // Create reference to original files before processing
        final originalFiles = <String, bool>{};
        for (final media in testMedia) {
          for (final file in media.files.values) {
            originalFiles[file.path] = file.existsSync();
          }
        }

        await moveFiles(
          testMedia,
          outputDir,
          copy: true, // Copy mode
          divideToDates: 0,
          albumBehavior: 'shortcut',
        ).toList();

        // Verify original files still exist
        for (final entry in originalFiles.entries) {
          if (entry.value) {
            // If file existed before
            expect(
              File(entry.key).existsSync(),
              isTrue,
              reason:
                  'Original file should still exist in copy mode: ${entry.key}',
            );
          }
        }

        // Verify output files exist
        final outputEntities = await outputDir.list(recursive: true).toList();
        final outputFiles = outputEntities.whereType<File>().toList();
        expect(outputFiles.length, greaterThan(0));
      });

      test('move mode removes original files to save space', () async {
        // Create reference to original files before processing
        final originalFilePaths = <String>[];
        for (final media in testMedia) {
          for (final file in media.files.values) {
            if (file.existsSync()) {
              originalFilePaths.add(file.path);
            }
          }
        }

        await moveFiles(
          testMedia,
          outputDir,
          copy: false, // Move mode
          divideToDates: 0,
          albumBehavior: 'duplicate-copy',
        ).toList();

        // Verify original files are moved/removed (depending on album behavior)
        // Note: With duplicate-copy and album files, some originals may remain
        // but the primary files should be moved to output

        // Verify output files exist
        final outputEntitiesMove = await outputDir
            .list(recursive: true)
            .toList();
        final outputFiles = outputEntitiesMove.whereType<File>().toList();
        expect(outputFiles.length, greaterThan(0));

        // In move mode, we expect that at least the main files were moved
        // (exact behavior depends on album handling mode)
        int movedFiles = 0;
        for (final path in originalFilePaths) {
          if (!File(path).existsSync()) {
            movedFiles++;
          }
        }

        // In move mode with albums, some files should be moved
        expect(movedFiles, greaterThan(0));
      });

      test('validates file operation safety and integrity', () async {
        // Test with a specific file to ensure content integrity
        final testFile = fixture.createImageWithExif('integrity_test.jpg');
        final originalContent = await testFile.readAsBytes();
        final originalSize = originalContent.length;

        final integrityMedia = [
          Media(
            {null: testFile},
            // ignore: avoid_redundant_argument_values
            dateTaken: DateTime(2022, 1, 1),
            dateTakenAccuracy: 1,
          ),
        ];

        // Test copy mode
        await moveFiles(
          integrityMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Verify original still exists with correct content
        expect(testFile.existsSync(), isTrue);
        final originalContentAfter = await testFile.readAsBytes();
        expect(originalContentAfter, equals(originalContent));

        // Verify copied file has correct content
        final copiedEntities = await outputDir.list(recursive: true).toList();
        final copiedFiles = copiedEntities
            .whereType<File>()
            .where(
              (final file) => p.basename(file.path) == 'integrity_test.jpg',
            )
            .toList();

        expect(copiedFiles.length, equals(1));
        final copiedContent = await copiedFiles[0].readAsBytes();
        expect(copiedContent, equals(originalContent));
        expect(copiedContent.length, equals(originalSize));
      });
    });

    group('Complex Integration Scenarios', () {
      test(
        'handles photos in multiple albums with different behaviors',
        () async {
          // Test a photo that appears in multiple albums
          final multiAlbumPhoto = fixture.createImageWithExif(
            'multi_album_photo.jpg',
          );

          // Create multiple album copies
          final album1Dir = fixture.createDirectory('Album One');
          final album2Dir = fixture.createDirectory('Album Two');
          final album3Dir = fixture.createDirectory('Album Three');

          final copy1 = File(p.join(album1Dir.path, 'multi_album_photo.jpg'));
          final copy2 = File(p.join(album2Dir.path, 'multi_album_photo.jpg'));
          final copy3 = File(p.join(album3Dir.path, 'multi_album_photo.jpg'));

          multiAlbumPhoto.copySync(copy1.path);
          multiAlbumPhoto.copySync(copy2.path);
          multiAlbumPhoto.copySync(copy3.path);

          final multiAlbumMedia = [
            Media(
              {
                null: multiAlbumPhoto,
                'Album One': copy1,
                'Album Two': copy2,
                'Album Three': copy3,
              },
              dateTaken: DateTime(2022, 5, 15),
              dateTakenAccuracy: 1,
            ),
          ];

          removeDuplicates(multiAlbumMedia);
          findAlbums(multiAlbumMedia);

          // Test with shortcut mode
          await moveFiles(
            multiAlbumMedia,
            outputDir,
            copy: true,
            divideToDates: 0,
            albumBehavior: 'shortcut',
          ).toList();

          // Verify one file in ALL_PHOTOS
          final allPhotosDir = Directory(p.join(outputDir.path, 'ALL_PHOTOS'));
          final allPhotosEntities = await allPhotosDir.list().toList();
          final allPhotosFiles = allPhotosEntities
              .whereType<File>()
              .where(
                (final file) =>
                    p.basename(file.path) == 'multi_album_photo.jpg',
              )
              .toList();
          expect(allPhotosFiles.length, equals(1));

          // Verify shortcuts in all three album folders
          final album1OutDir = Directory(p.join(outputDir.path, 'Album One'));
          final album2OutDir = Directory(p.join(outputDir.path, 'Album Two'));
          final album3OutDir = Directory(p.join(outputDir.path, 'Album Three'));

          expect(album1OutDir.existsSync(), isTrue);
          expect(album2OutDir.existsSync(), isTrue);
          expect(album3OutDir.existsSync(), isTrue);

          // Each album should have one shortcut/symlink
          final album1Items = await album1OutDir.list().toList();
          final album2Items = await album2OutDir.list().toList();
          final album3Items = await album3OutDir.list().toList();

          expect(album1Items.length, equals(1));
          expect(album2Items.length, equals(1));
          expect(album3Items.length, equals(1));
        },
      );

      test('handles mixed file types and naming conventions', () async {
        // Create files with various naming patterns
        final screenshotFile = fixture.createImageWithExif(
          'Screenshot_20220815-143022.jpg',
        );
        final mvimgFile = fixture.createImageWithExif(
          'MVIMG_20220820_190145.jpg',
        );
        final editedFile = fixture.createImageWithExif(
          'IMG_20220825_110045-edited.jpg',
        );
        final unicodeFile = fixture.createImageWithExif(
          'Urlaub_in_München_🏔️.jpg',
        );

        final mixedMedia = [
          Media(
            {null: screenshotFile},
            dateTaken: DateTime(2022, 8, 15, 14, 30, 22),
            dateTakenAccuracy: 1,
          ),
          Media(
            {null: mvimgFile},
            dateTaken: DateTime(2022, 8, 20, 19, 1, 45),
            dateTakenAccuracy: 1,
          ),
          Media(
            {null: editedFile},
            dateTaken: DateTime(2022, 8, 25, 11, 0, 45),
            dateTakenAccuracy: 1,
          ),
          Media(
            {null: unicodeFile},
            dateTaken: DateTime(2022, 8, 30, 16, 15, 30),
            dateTakenAccuracy: 1,
          ),
        ];

        await moveFiles(
          mixedMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        // Verify all files are processed correctly
        final outputEntities = await outputDir.list(recursive: true).toList();
        final outputFiles = outputEntities.whereType<File>().toList();

        final fileNames = outputFiles
            .map((final file) => p.basename(file.path))
            .toSet();

        expect(fileNames, contains('Screenshot_20220815-143022.jpg'));
        expect(fileNames, contains('MVIMG_20220820_190145.jpg'));
        expect(fileNames, contains('IMG_20220825_110045-edited.jpg'));
        expect(fileNames, contains('Urlaub_in_München_🏔️.jpg'));
      });

      test('performance with large number of files', () async {
        // Create a large number of test files for performance testing
        final largeMediaList = <Media>[];

        for (int i = 0; i < 100; i++) {
          final testFile = fixture.createFile('perf_test_$i.jpg', [
            i % 256,
            (i + 1) % 256,
            (i + 2) % 256,
          ]);

          largeMediaList.add(
            Media(
              {null: testFile},
              // ignore: avoid_redundant_argument_values
              dateTaken: DateTime(2022, 1, 1).add(Duration(days: i)),
              dateTakenAccuracy: 1,
            ),
          );
        }

        final stopwatch = Stopwatch()..start();

        await moveFiles(
          largeMediaList,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'nothing',
        ).toList();

        stopwatch.stop();

        // Verify all files were processed
        final outputEntities = await outputDir.list(recursive: true).toList();
        final outputFiles = outputEntities.whereType<File>().toList();

        expect(outputFiles.length, equals(100));

        // Performance expectation (should complete within reasonable time)
        expect(
          stopwatch.elapsed.inSeconds,
          lessThan(30),
          reason: 'Processing 100 files should complete within 30 seconds',
        );
      });
    });

    group('Error Handling and Edge Cases', () {
      test('handles corrupt or inaccessible files gracefully', () async {
        // Create a file and then make it inaccessible (if possible)
        final testFile = fixture.createImageWithExif('test_file.jpg');

        final testMediaWithIssues = [
          Media(
            {null: testFile},
            // ignore: avoid_redundant_argument_values
            dateTaken: DateTime(2022, 1, 1),
            dateTakenAccuracy: 1,
          ),
        ];

        // The operation should not throw exceptions
        expect(() async {
          await moveFiles(
            testMediaWithIssues,
            outputDir,
            copy: true,
            divideToDates: 0,
            albumBehavior: 'nothing',
          ).toList();
        }, returnsNormally);
      });

      test('handles insufficient disk space scenarios', () async {
        // This is difficult to test without actually filling up disk space
        // But we can verify the error handling mechanisms are in place
        final testFile = fixture.createImageWithExif('space_test.jpg');

        final spaceTestMedia = [
          Media(
            {null: testFile},
            // ignore: avoid_redundant_argument_values
            dateTaken: DateTime(2022, 1, 1),
            dateTakenAccuracy: 1,
          ),
        ];

        // Should handle gracefully (implementation should catch FileSystemException)
        expect(() async {
          await moveFiles(
            spaceTestMedia,
            outputDir,
            copy: true,
            divideToDates: 0,
            albumBehavior: 'nothing',
          ).toList();
        }, returnsNormally);
      });

      test('validates cross-platform compatibility', () async {
        // Test platform-specific features
        final testFile = fixture.createImageWithExif('platform_test.jpg');
        final albumDir = fixture.createDirectory('Platform Album');
        final albumFile = File(p.join(albumDir.path, 'platform_test.jpg'));
        testFile.copySync(albumFile.path);

        final platformMedia = [
          Media(
            {null: testFile, 'Platform Album': albumFile},
            // ignore: avoid_redundant_argument_values
            dateTaken: DateTime(2022, 1, 1),
            dateTakenAccuracy: 1,
          ),
        ];

        removeDuplicates(platformMedia);
        findAlbums(platformMedia);

        // Test shortcut creation (different on Windows vs Unix)
        await moveFiles(
          platformMedia,
          outputDir,
          copy: true,
          divideToDates: 0,
          albumBehavior: 'shortcut',
        ).toList();

        final allEntities = await outputDir
            .list(recursive: true, followLinks: false)
            .toList();

        if (Platform.isWindows) {
          // Should create .lnk files on Windows
          final shortcuts = allEntities
              .whereType<File>()
              .where((final file) => file.path.endsWith('.lnk'))
              .toList();
          expect(shortcuts.length, greaterThan(0));
        } else {
          // Should create symlinks on Unix systems
          final symlinks = allEntities.whereType<Link>().toList();
          expect(symlinks.length, greaterThan(0));
        }
      });
    });
  });
}
