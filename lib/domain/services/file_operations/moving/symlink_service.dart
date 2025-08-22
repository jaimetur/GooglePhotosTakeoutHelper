import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../../infrastructure/windows_symlink_service.dart';
import '../../core/service_container.dart';

/// Service responsible for creating symlinks across platforms
///
/// This service creates symbolic links on all platforms (Windows, macOS, Linux),
/// providing a unified interface for the moving logic. Previously created Windows
/// shortcuts (.lnk files), but now creates real symlinks for better compatibility.
class SymlinkService {
  /// Creates a symbolic link to target file
  ///
  /// [targetDirectory] Directory where the symlink will be created
  /// [sourceFile] File to link to
  /// Returns the created symlink file
  /// Uses relative paths to avoid breaking when folders are moved
  Future<File> createSymlink(
    final Directory targetDirectory,
    final File sourceFile,
  ) async {
    final String basename = p.basename(sourceFile.path);
    final File linkFile = ServiceContainer.instance.utilityService
        .findUniqueFileName(File(p.join(targetDirectory.path, basename)));

    // Ensure the parent directory for the symlink exists
    final linkDir = Directory(p.dirname(linkFile.path));
    if (!await linkDir.exists()) {
      await linkDir.create(recursive: true);
    }

    // Ensure the target directory exists before creating symlinks
    if (!await targetDirectory.exists()) {
      await targetDirectory.create(recursive: true);
    }

    // Use relative path to prevent breaking when folders are moved
    final String targetRelativePath = p.relative(
      sourceFile.path,
      from: linkFile.parent.path,
    );

    // Create a symlink on all platforms (including Windows)
    if (Platform.isWindows) {
      // Use Windows symlink service for better control on Windows
      final service = WindowsSymlinkService();
      await service.createSymlink(linkFile.path, sourceFile.absolute.path);
      return linkFile;
    } else {
      // Unix: create a symlink
      final link = await Link(linkFile.path).create(targetRelativePath);
      return File(link.path);
    }
  }
}
