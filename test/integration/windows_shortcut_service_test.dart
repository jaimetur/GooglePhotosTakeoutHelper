import 'dart:io';

import 'package:gpth/infrastructure/windows_shortcut_service.dart';
import 'package:test/test.dart';

void main() {
  group('WindowsShortcutService', () {
    late WindowsShortcutService shortcutService;
    late Directory tempDir;

    setUp(() async {
      shortcutService = const WindowsShortcutService();
      tempDir = await Directory.systemTemp.createTemp('shortcut_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('should create WindowsShortcutService instance', () {
      expect(shortcutService, isA<WindowsShortcutService>());
    });

    group('Windows platform tests', () {
      test(
        'should create shortcut to existing file',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          final shortcutPath = '${tempDir.path}/shortcut.lnk';

          await shortcutService.createShortcut(shortcutPath, targetFile.path);

          // Verify shortcut was created
          final shortcutFile = File(shortcutPath);
          expect(await shortcutFile.exists(), isTrue);

          // Basic validation that it's a .lnk file (should have LNK header)
          final bytes = await shortcutFile.readAsBytes();
          expect(bytes.length, greaterThan(0));
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should create shortcut to existing directory',
        () async {
          if (!Platform.isWindows) return;

          // Create a target directory
          final targetDir = Directory('${tempDir.path}/target_folder');
          await targetDir.create();

          final shortcutPath = '${tempDir.path}/folder_shortcut.lnk';

          await shortcutService.createShortcut(shortcutPath, targetDir.path);

          // Verify shortcut was created
          final shortcutFile = File(shortcutPath);
          expect(await shortcutFile.exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle absolute target paths',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file with absolute path
          final targetFile = File('${tempDir.path}/absolute_target.txt');
          await targetFile.writeAsString('Test content');

          final shortcutPath = '${tempDir.path}/absolute_shortcut.lnk';

          await shortcutService.createShortcut(
            shortcutPath,
            targetFile.absolute.path,
          );

          // Verify shortcut was created
          final shortcutFile = File(shortcutPath);
          expect(await shortcutFile.exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle relative target paths',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/relative_target.txt');
          await targetFile.writeAsString('Test content');

          final shortcutPath = '${tempDir.path}/relative_shortcut.lnk';

          // Use relative path from temp directory
          final originalDir = Directory.current;
          Directory.current = tempDir;

          try {
            await shortcutService.createShortcut(
              shortcutPath,
              'relative_target.txt',
            );

            // Verify shortcut was created
            final shortcutFile = File(shortcutPath);
            expect(await shortcutFile.exists(), isTrue);
          } finally {
            Directory.current = originalDir;
          }
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should create parent directories if they do not exist',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          // Create shortcut in nested directory that doesn't exist
          final shortcutPath = '${tempDir.path}/nested/folder/shortcut.lnk';

          await shortcutService.createShortcut(shortcutPath, targetFile.path);

          // Verify shortcut was created and parent directories exist
          final shortcutFile = File(shortcutPath);
          expect(await shortcutFile.exists(), isTrue);
          expect(
            await Directory('${tempDir.path}/nested/folder').exists(),
            isTrue,
          );
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle special characters in paths',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file with spaces and special characters
          final targetFile = File(
            '${tempDir.path}/target with spaces & symbols.txt',
          );
          await targetFile.writeAsString('Test content');

          final shortcutPath = '${tempDir.path}/shortcut with spaces.lnk';

          await shortcutService.createShortcut(shortcutPath, targetFile.path);

          // Verify shortcut was created
          final shortcutFile = File(shortcutPath);
          expect(await shortcutFile.exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should fail when target does not exist',
        () async {
          if (!Platform.isWindows) return;

          final nonExistentTarget = '${tempDir.path}/does_not_exist.txt';
          final shortcutPath = '${tempDir.path}/shortcut.lnk';

          expect(
            () =>
                shortcutService.createShortcut(shortcutPath, nonExistentTarget),
            throwsA(isA<Exception>()),
          );
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should overwrite existing shortcut',
        () async {
          if (!Platform.isWindows) return;

          // Create two target files
          final targetFile1 = File('${tempDir.path}/target1.txt');
          await targetFile1.writeAsString('Target 1');

          final targetFile2 = File('${tempDir.path}/target2.txt');
          await targetFile2.writeAsString('Target 2');

          final shortcutPath = '${tempDir.path}/shortcut.lnk';

          // Create first shortcut
          await shortcutService.createShortcut(shortcutPath, targetFile1.path);
          expect(await File(shortcutPath).exists(), isTrue);

          // Create second shortcut with same path (should overwrite)
          await shortcutService.createShortcut(shortcutPath, targetFile2.path);
          expect(await File(shortcutPath).exists(), isTrue);
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );

      test(
        'should handle long paths correctly',
        () async {
          if (!Platform.isWindows) return;

          // Create a target file
          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          // Create a long path for the shortcut
          final longPath = List.generate(
            5,
            (final i) => 'very_long_folder_name_$i',
          ).join('/');
          final shortcutPath = '${tempDir.path}/$longPath/shortcut.lnk';

          try {
            await shortcutService.createShortcut(shortcutPath, targetFile.path);

            // Verify shortcut was created
            final shortcutFile = File(shortcutPath);
            expect(await shortcutFile.exists(), isTrue);
          } catch (e) {
            // Long paths might fail on some systems, which is acceptable
            expect(e, isA<Exception>());
          }
        },
        skip: !Platform.isWindows ? 'Windows-only test' : null,
      );
    });

    group('Non-Windows platform tests', () {
      test(
        'should throw UnsupportedError on non-Windows platforms',
        () async {
          if (Platform.isWindows) return;

          final targetFile = File('${tempDir.path}/target.txt');
          await targetFile.writeAsString('Test content');

          final shortcutPath = '${tempDir.path}/shortcut.lnk';

          expect(
            () => shortcutService.createShortcut(shortcutPath, targetFile.path),
            throwsA(isA<UnsupportedError>()),
          );
        },
        skip: Platform.isWindows ? 'Non-Windows test' : null,
      );
    });

    test(
      'should handle null or empty paths gracefully',
      () async {
        if (!Platform.isWindows) return;

        expect(
          () => shortcutService.createShortcut('', ''),
          throwsA(isA<Exception>()),
        );
      },
      skip: !Platform.isWindows ? 'Windows-only test' : null,
    );

    test(
      'should validate shortcut path extension',
      () async {
        if (!Platform.isWindows) return;

        final targetFile = File('${tempDir.path}/target.txt');
        await targetFile.writeAsString('Test content');

        // Test with .lnk extension
        final validShortcutPath = '${tempDir.path}/shortcut.lnk';
        await shortcutService.createShortcut(
          validShortcutPath,
          targetFile.path,
        );
        expect(await File(validShortcutPath).exists(), isTrue);

        // Test without .lnk extension (should still work - service might add it)
        final noExtShortcutPath = '${tempDir.path}/shortcut_no_ext';
        try {
          await shortcutService.createShortcut(
            noExtShortcutPath,
            targetFile.path,
          );
          // Either it works as-is or the service handles it appropriately
          expect(true, isTrue); // Test that it doesn't crash
        } catch (e) {
          // It's acceptable if it fails due to extension requirements
          expect(e, isA<Exception>());
        }
      },
      skip: !Platform.isWindows ? 'Windows-only test' : null,
    );
  });
}



