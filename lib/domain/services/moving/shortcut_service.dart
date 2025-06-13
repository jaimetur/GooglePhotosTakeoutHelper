import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../infrastructure/windows_shortcut_service.dart';

/// Service responsible for creating shortcuts and symlinks across platforms
///
/// This service abstracts the creation of Windows shortcuts (.lnk files) and
/// Unix/Linux symlinks, providing a unified interface for the moving logic.
class ShortcutService {
  /// Creates a symbolic link (Unix) or shortcut (Windows) to target file
  ///
  /// [targetDirectory] Directory where the link/shortcut will be created
  /// [sourceFile] File to link to
  /// Returns the created link/shortcut file
  /// Uses relative paths to avoid breaking when folders are moved
  Future<File> createShortcut(
    final Directory targetDirectory,
    final File sourceFile,
  ) async {
    final String basename = p.basename(sourceFile.path);
    final String linkName = Platform.isWindows
        ? (basename.endsWith('.lnk') ? basename : '$basename.lnk')
        : basename;

    final File linkFile = _findUniqueFileName(
      File(p.join(targetDirectory.path, linkName)),
    );

    // Ensure the parent directory for the shortcut exists
    final linkDir = Directory(p.dirname(linkFile.path));
    if (!await linkDir.exists()) {
      await linkDir.create(recursive: true);
    }

    // Ensure the target directory exists before creating shortcuts
    if (!await targetDirectory.exists()) {
      await targetDirectory.create(recursive: true);
    }

    // Use relative path to prevent breaking when folders are moved
    final String targetRelativePath = p.relative(
      sourceFile.path,
      from: linkFile.parent.path,
    );
    if (Platform.isWindows) {
      // Use the Windows shortcut service
      const service = WindowsShortcutService();
      await service.createShortcut(linkFile.path, sourceFile.absolute.path);
      return linkFile;
    } else {
      // Unix: create a symlink
      final link = await Link(linkFile.path).create(targetRelativePath);
      return File(link.path);
    }
  }

  /// Creates a unique file name by appending (1), (2), etc. until non-existing
  File _findUniqueFileName(final File initialFile) {
    File file = initialFile;
    int counter = 1;
    while (file.existsSync()) {
      final String baseName = p.withoutExtension(initialFile.path);
      final String extension = p.extension(initialFile.path);
      file = File('$baseName($counter)$extension');
      counter++;
    }
    return file;
  }
}
