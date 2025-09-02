import 'dart:io';

import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;


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
    // Ensure the parent directory for the symlink exists
    if (!await targetDirectory.exists()) {
      await targetDirectory.create(recursive: true);
    }

    // Use relative path to prevent breaking when folders are moved
    final String targetRelativePath = path.relative(
      sourceFile.path,
      from: targetDirectory.path,
    );

    // Windows-safe link name: strip trailing spaces/dots only on the *link* leaf.
    // (We do NOT touch the source file on disk.)
    final String rawBasename = path.basename(sourceFile.path);
    final String linkBasename = _sanitizeLeafForWindows(rawBasename);
    final File desiredLink = File(path.join(targetDirectory.path, linkBasename));

    // Respect your unique-name policy
    final File linkFile =
        ServiceContainer.instance.utilityService.findUniqueFileName(desiredLink);

    if (!Platform.isWindows) {
      // Unix: create a symlink
      final Link link = await Link(linkFile.path).create(targetRelativePath);
      return File(link.path);
    }

    // Windows: try a *real* symlink first (requires SeCreateSymbolicLinkPrivilege).
    try {
      final service = WindowsSymlinkService();
      await service.createSymlink(linkFile.path, sourceFile.absolute.path);
      return linkFile;
    } catch (e) {
      // NEW (Windows): graceful fallbacks when symlink privilege is missing.
      // 1) If it's a regular file, try a *hard link* (same volume only).
      // 2) If it's (or behaves like) a directory, try a *junction*.
      // 3) If both fail, rethrow with a clear explanation.
      try {
        final FileStat st = await sourceFile.stat();
        if (st.type == FileSystemEntityType.directory) {
          // Junction (directory link)
          await _createWindowsJunction(linkFile.path, sourceFile.absolute.path);
          return linkFile;
        } else {
          // Hard link (file link) – works only when source and link are in the same NTFS volume
          if (_sameDrive(sourceFile.path, linkFile.path)) {
            await _createWindowsHardLink(linkFile.path, sourceFile.absolute.path);
            return linkFile;
          } else {
            // Different drive: hard link impossible. As a last resort, try junction IF target is a directory.
            // For files living on different drives we cannot degrade to hardlink; we keep the error explicit.
            throw FileSystemException(
              'Cannot create hard link across different drives. '
              'Enable Developer Mode (Windows) or run as Administrator to allow symlinks.',
              linkFile.path,
            );
          }
        }
      } catch (fallbackErr) {
        // Rethrow with context of both attempts
        throw FileSystemException(
          'Failed to create link for "${sourceFile.path}". '
          'Tried: symlink → ${_isDirPath(sourceFile.path) ? "junction" : "hard link"}. '
          'Original error: $e | Fallback error: $fallbackErr',
          linkFile.path,
        );
      }
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Windows helpers
  // ───────────────────────────────────────────────────────────────────────────

  /// Create a Windows hard link for files using `mklink /H`.
  Future<void> _createWindowsHardLink(final String linkPath, final String targetAbs) async {
    // mklink /H "link" "target"
    final result = await Process.run(
      'cmd',
      ['/c', 'mklink', '/H', linkPath, targetAbs],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'mklink /H failed (${result.exitCode}): ${(result.stderr ?? '').toString().trim()}',
        linkPath,
      );
    }
  }

  /// Create a Windows junction for directories using `mklink /J`.
  Future<void> _createWindowsJunction(final String linkPath, final String targetAbs) async {
    // mklink /J "link" "target"
    final result = await Process.run(
      'cmd',
      ['/c', 'mklink', '/J', linkPath, targetAbs],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'mklink /J failed (${result.exitCode}): ${(result.stderr ?? '').toString().trim()}',
        linkPath,
      );
    }
  }

  /// On Windows, hard links require both paths to live on the same drive.
  bool _sameDrive(final String a, final String b) {
    if (!Platform.isWindows) return true;
    String driveOf(String p) => p.length >= 2 ? p.substring(0, 2).toUpperCase() : '';
    return driveOf(a) == driveOf(b);
  }

  /// Returns true if the path clearly refers to a directory (cheap heuristic used only for messages).
  bool _isDirPath(final String p) {
    final ext = path.extension(p);
    if (ext.isEmpty) return true;
    return false;
  }

  /// Windows does not allow trailing spaces or dots in *file names* (leaf).
  /// We only sanitize the link *basename* we are creating, never the source.
  String _sanitizeLeafForWindows(final String leaf) {
    if (!Platform.isWindows) return leaf;
    // Remove trailing spaces/dots only (keep Unicode intact).
    final sanitized = leaf.replaceAll(RegExp(r'[. ]+$'), '');
    return sanitized.isEmpty ? leaf : sanitized;
  }
}
