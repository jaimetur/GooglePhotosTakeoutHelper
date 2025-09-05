import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:console_bars/console_bars.dart';
import 'package:ffi/ffi.dart';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:win32/win32.dart';

/// Step 8: Update creation times (Windows only)
///
/// This Windows-specific final step synchronizes file creation timestamps with their
/// modification times to ensure proper chronological sorting in Windows Explorer and
/// other file managers that rely on creation time for organization.
///
/// ## Purpose and Rationale
///
/// ### Windows File System Behavior
/// - **Creation vs Modification Time**: Windows tracks both creation and modification timestamps
/// - **File Manager Sorting**: Windows Explorer often sorts by creation time by default
/// - **Photo Viewer Behavior**: Many photo viewers use creation time for chronological display
/// - **Backup Software**: Some backup tools rely on creation time for change detection
///
/// ### Google Photos Export Issues
/// - **Incorrect Creation Times**: Exported files often have creation time = export time
/// - **Chronological Confusion**: Photos appear in wrong order due to export timestamps
/// - **Date Mismatch**: Creation time doesn't match actual photo date
/// - **User Experience**: Confusing timeline when browsing organized photos
///
/// ## Processing Logic
///
/// ### Timestamp Synchronization
/// 1. **Source Timestamp**: Uses the entity's authoritative `dateTaken`
/// 2. **Target Timestamp**: Sets both CreationTime and LastWriteTime to `dateTaken`
/// 3. **Preservation**: Keeps LastAccessTime unchanged
/// 4. **Verification**: Confirms timestamp update was successful (treated as updated on success)
///
/// ### Platform Detection
/// - **Windows Only**: Operation is only performed on Windows systems
/// - **Graceful Skipping**: Silently skips on non-Windows platforms
/// - **Cross-Platform Compatibility**: Uses Dart's Platform detection for safety
///
/// ## Configuration and Control
///
/// ### User Options
/// - **Enable/Disable**: Controlled by `updateCreationTime` configuration flag
/// - **Verbose Logging**: Provides detailed progress when verbose mode enabled
/// - **Error Reporting**: Reports any files that couldn't be updated
/// - **Statistics**: Tracks number of files successfully updated
///
/// ### Safety Features
/// - **Non-Destructive**: Only modifies timestamps, never file content
/// - **Error Recovery**: Continues processing if individual files fail
/// - **Permission Respect**: Skips files that can't be modified due to permissions
///
/// ### Step Sequencing
/// - **Final Step**: Runs as the last step after all file operations complete
/// - **Post-Processing**: Applied after files are in their final locations
/// - **Non-Critical**: Failure doesn't affect core functionality
/// - **Optional**: Can be safely skipped without affecting main workflow
///
/// ### Prerequisites
/// - **Completed File Organization**: Files must be in final output locations
/// - **Windows Platform**: Only runs on Windows operating systems
/// - **Configuration Flag**: Must be explicitly enabled by user
/// - **File Accessibility**: Files must be writable for timestamp modification
///
/// ## Benefits and Use Cases
///
/// ### User Experience Improvements
/// - **Chronological Browsing**: Photos appear in correct order in Windows Explorer
/// - **Date-Based Organization**: File managers can properly sort by creation date
/// - **Photo Viewer Compatibility**: Improves experience with Windows photo applications
/// - **Backup Software**: Ensures backup tools see correct file dates
///
/// ### Professional Workflows
/// - **Digital Asset Management**: Supports professional photo management workflows
/// - **Archive Organization**: Improves long-term photo archive organization
/// - **Client Delivery**: Ensures photos are properly timestamped for client delivery
/// - **System Integration**: Better integration with Windows-based photo workflows
///
/// ## Technical Considerations
///
/// ### File System Impact
/// - **Minimal Overhead**: Very low impact on file system performance
/// - **Journal Updates**: May trigger file system journal updates
/// - **Index Updates**: May cause Windows Search index updates
/// - **Backup Impact**: May affect incremental backup change detection
///
/// ### Security and Permissions
/// - **User Permissions**: Respects current user's file permissions
/// - **Administrator Rights**: May require elevated permissions for some files
/// - **Security Descriptors**: Preserves file security information
/// - **Audit Trails**: May generate file system audit events
class UpdateCreationTimeStep extends ProcessingStep with LoggerMixin {
  const UpdateCreationTimeStep() : super('Update Creation Time');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();

    try {
      if (!context.config.updateCreationTime) {
        const reason = 'disabled in configuration';

        logWarning('[Step 8/8] Skipping creation time update ($reason).', forcePrint: true);
        stopwatch.stop();
        return StepResult.success(
          stepName: name,
          duration: stopwatch.elapsed,
          data: {'updatedCount': 0, 'skipped': true},
          message: 'Creation time update skipped: $reason',
        );
      }

      logPrint('[Step 8/8] Updating creation times (this may take a while)...');

      // Build the list of output items from the collection
      // (primary + secondaries with targetPath != null; include shortcuts too).
      final filesToTouch = <_ToTouch>[];
      for (final entity in context.mediaCollection.entities) {
        final dt = entity.dateTaken;
        if (dt == null) continue;

        final fes = <FileEntity>[entity.primaryFile, ...entity.secondaryFiles];
        for (final fe in fes) {
          final tp = fe.targetPath;
          if (tp == null) continue;
          filesToTouch.add(_ToTouch(File(tp), dt, isShortcut: fe.isShortcut));
        }
      }

      if (filesToTouch.isEmpty) {
        logPrint('[Step 8/8] No files found to update creation times.');
        stopwatch.stop();
        return StepResult.success(
          stepName: name,
          duration: stopwatch.elapsed,
          data: {'updatedCount': 0, 'failedCount': 0, 'skipped': false},
          message: 'Updated creation times for 0 files',
        );
      }

      // Initialize progress bar - always visible
      final progressBar = FillingBar(
        desc: '[ INFO  ] [Step 8/8] Updating creation times',
        total: filesToTouch.length,
        width: 50,
      );

      int updated = 0;
      int failed = 0;
      // Per-type counters (physical vs shortcuts)
      int updatedPhysical = 0;
      int updatedShortcuts = 0;
      int failedPhysical = 0;
      int failedShortcuts = 0;

      for (int i = 0; i < filesToTouch.length; i++) {
        final f = filesToTouch[i];
        try {
          final ok = _setFileTimesToDateTakenCrossPlatform(
            f.file.path,
            f.dateTaken,
            isShortcut: f.isShortcut,
          );
          if (ok) {
            updated++;
            // Increment per-type updated counters
            if (f.isShortcut) {
              updatedShortcuts++;
            } else {
              updatedPhysical++;
            }
          } else {
            failed++;
            // Increment per-type failed counters
            if (f.isShortcut) {
              failedShortcuts++;
            } else {
              failedPhysical++;
            }
          }
        } catch (e) {
          failed++;
          if (f.isShortcut) {
            failedShortcuts++;
          } else {
            failedPhysical++;
          }
          logWarning('[Step 8/8] Timestamp update failed for ${f.file.path}: $e', forcePrint: true);
        }
        progressBar.update(i + 1);
      }

      // Explicit summary line (with per-type breakdown)
      logPrint(
        '[Step 8/8] Update Creation Time Summary → '
        'updated: $updated (physical=$updatedPhysical, shortcuts=$updatedShortcuts), '
        'failed: $failed (physical=$failedPhysical, shortcuts=$failedShortcuts)',
      );

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'updatedCount': updated,
          'failedCount': failed,
          'updatedPhysical': updatedPhysical,
          'updatedShortcuts': updatedShortcuts,
          'failedPhysical': failedPhysical,
          'failedShortcuts': failedShortcuts,
          'skipped': false,
        },
        message: 'Updated creation times for $updated files',
      );
    } catch (e) {
      stopwatch.stop();
      return StepResult.failure(
        stepName: name,
        duration: stopwatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to update creation times: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) {
    final shouldSkipStep = !context.config.updateCreationTime;

    if (shouldSkipStep) {
      const reason = 'disabled in configuration';
      logWarning('[Step 8/8] Skipping creation time update ($reason).', forcePrint: true);
    }

    return shouldSkipStep;
  }

  /// Cross-platform timestamp update.
  /// Windows: sets CreationTime and LastWriteTime = dateTaken (preserving LastAccessTime).
  /// POSIX   : sets mtime (and atime) = dateTaken. If [isShortcut] is true and the path is a symlink,
  ///           we update the symlink's own timestamps using utimensat(AT_SYMLINK_NOFOLLOW).
  bool _setFileTimesToDateTakenCrossPlatform(
    final String filePath,
    final DateTime dateTaken, {
    required final bool isShortcut,
  }) {
    if (Platform.isWindows) {
      return _setFileTimesToDateTakenWindows(filePath, dateTaken, isShortcut: isShortcut);
    } else {
      return _setFileTimesToDateTakenPosix(filePath, dateTaken, isShortcut: isShortcut);
    }
  }

  /// Synchronous Win32 creation/write time update to a specific DateTime (entity.dateTaken).
  /// If [isShortcut] is true, the handle is opened with FILE_FLAG_OPEN_REPARSE_POINT
  /// so we touch the link itself (not its target). LastAccessTime is preserved as-is.
  bool _setFileTimesToDateTakenWindows(
    final String filePath,
    final DateTime dateTaken, {
    required final bool isShortcut,
  }) {
    try {
      return using((final Arena arena) {
        // Convert to extended-length path to avoid MAX_PATH issues on Windows.
        // IMPORTANT: make path absolute first; \\?\ only makes sense for absolute paths.
        final String extended = _toExtendedLengthPath(filePath);
        final Pointer<Utf16> pathPtr = extended.toNativeUtf16(allocator: arena);

        // Always allow directory handles; don't follow symlinks when touching shortcuts.
        final int flags =
            FILE_ATTRIBUTE_NORMAL |
            FILE_FLAG_BACKUP_SEMANTICS |
            (isShortcut ? FILE_FLAG_OPEN_REPARSE_POINT : 0);

        // Open file handle with write attributes access
        final int fileHandle = CreateFile(
          pathPtr,
          FILE_WRITE_ATTRIBUTES,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
          nullptr, // leave security attributes null
          OPEN_EXISTING,
          flags,
          0,
        );

        if (fileHandle == INVALID_HANDLE_VALUE) {
          // Log GetLastError for diagnostics (helped catch \\?\ misuse).
          final int err = GetLastError();
          logWarning('[Step 8/8] CreateFileW failed for "$extended" (error=$err)', forcePrint: true);
          return false;
        }

        try {
          // Target FILETIME from dateTaken (UTC)
          final Pointer<FILETIME> pCreation = arena<FILETIME>();
          final Pointer<FILETIME> pWrite = arena<FILETIME>();
          _writeDateTimeToFileTimePtr(pCreation, dateTaken.toUtc());
          _writeDateTimeToFileTimePtr(pWrite, dateTaken.toUtc());

          // Set CreationTime and LastWriteTime = dateTaken; keep LastAccessTime unchanged (nullptr)
          final bool setOk =
              SetFileTime(fileHandle, pCreation, nullptr, pWrite) != FALSE;
          return setOk;
        } finally {
          CloseHandle(fileHandle);
        }
      });
    } catch (e) {
      logWarning('[Step 8/8] Windows timestamp update failed for "$filePath": $e', forcePrint: true);
      return false;
    }
  }

  /// POSIX implementation using utimensat.
  /// NOTE: On POSIX there is no creation time; we set both mtime and atime to `dateTaken`.
  ///       If the path is a shortcut/symlink, we attempt to touch the link itself using
  ///       AT_SYMLINK_NOFOLLOW. Fallbacks apply if utimensat is not available.
  bool _setFileTimesToDateTakenPosix(
    final String filePath,
    final DateTime dateTaken, {
    required final bool isShortcut,
  }) {
    try {
      final DynamicLibrary? libc = _loadLibC();
      if (libc == null) {
        // Fallback: only mtime on the target (cannot touch the symlink itself here).
        try {
          File(filePath).setLastModifiedSync(dateTaken);
          return !isShortcut; // we only updated the target; for shortcuts say false
        } catch (_) {
          return false;
        }
      }

      // typedef int utimensat(int dirfd, const char *pathname, const struct timespec times[2], int flags);
      _Utimensat? utimensat;
      try {
        utimensat = libc
            .lookup<NativeFunction<_UtimensatNative>>('utimensat')
            .asFunction<_Utimensat>();
      } catch (_) {
        utimensat = null;
      }

      if (utimensat == null) {
        // Fallback if symbol not found.
        try {
          File(filePath).setLastModifiedSync(dateTaken);
          return !isShortcut;
        } catch (_) {
          return false;
        }
      }

      return using((final Arena arena) {
        final Pointer<Utf8> p = filePath.toNativeUtf8(allocator: arena);

        // Build timespec array [atime, mtime]
        final Pointer<_Timespec> times = arena<_Timespec>(2);

        // NOTE: We set BOTH atime and mtime to dateTaken for simplicity/cross-tool consistency.
        final int sec = dateTaken.toUtc().millisecondsSinceEpoch ~/ 1000;
        final int nsec = (dateTaken.toUtc().microsecondsSinceEpoch % 1000000) * 1000;

        times[0]
          ..tv_sec = sec
          ..tv_nsec = nsec;
        times[1]
          ..tv_sec = sec
          ..tv_nsec = nsec;

        const int atFdcwd = -100;
        const int atSymlinkNofollow = 0x100;

        final int flags = isShortcut ? atSymlinkNofollow : 0;
        final int r = utimensat!(atFdcwd, p, times, flags);
        if (r == 0) return true;

        // Fallback: if touching symlink itself is unsupported, try touching target when isShortcut=false or as last resort.
        try {
          File(filePath).setLastModifiedSync(dateTaken);
          return !isShortcut; // if it was a symlink we likely only touched the target
        } catch (_) {
          return false;
        }
      });
    } catch (e) {
      logWarning('[Step 8/8] POSIX timestamp update failed for "$filePath": $e', forcePrint: true);
      return false;
    }
  }

  // ------------------------------- Utilities --------------------------------

  /// Convert normal path to extended-length path (\\?\ prefix) for long-path safety on Windows.
  /// IMPORTANT: This function now ensures the path is absolute before applying the prefix.
  String _toExtendedLengthPath(final String p) {
    if (!Platform.isWindows) return p;
    final String abs = File(p).absolute.path; // ensure absolute first
    if (abs.startsWith('\\\\?\\')) return abs;
    if (abs.startsWith('\\\\')) return '\\\\?\\UNC${abs.substring(1)}';
    return '\\\\?\\$abs';
  }

  /// Write a DateTime (UTC) into a FILETIME pointer.
  /// FILETIME = 100-nanosecond intervals since January 1, 1601 (UTC).
  void _writeDateTimeToFileTimePtr(
    final Pointer<FILETIME> p,
    final DateTime utc,
  ) {
    const int epochDiff100ns =
        116444736000000000; // between 1601-01-01 and 1970-01-01
    final int ftTicks = utc.millisecondsSinceEpoch * 10000 + epochDiff100ns;
    p.ref
      ..dwHighDateTime = (ftTicks >> 32) & 0xFFFFFFFF
      ..dwLowDateTime = ftTicks & 0xFFFFFFFF;
  }

  DynamicLibrary? _loadLibC() {
    try {
      if (Platform.isLinux) return DynamicLibrary.open('libc.so.6');
      if (Platform.isMacOS) return DynamicLibrary.process(); // libc is in the default namespace on macOS
      if (Platform.isAndroid) return DynamicLibrary.open('libc.so');
      return null;
    } catch (_) {
      return null;
    }
  }
}

// FFI types for POSIX utimensat

// struct timespec { time_t tv_sec; long tv_nsec; }
// NOTE: We use Int64 for both fields, which matches 64-bit Linux/macOS ABIs.
final class _Timespec extends Struct {
  @Int64()
  external int tv_sec;

  @Int64()
  external int tv_nsec;
}

typedef _UtimensatNative = Int32 Function(
  Int32 dirfd,
  Pointer<Utf8> pathname,
  Pointer<_Timespec> times,
  Int32 flags,
);
typedef _Utimensat = int Function(
  int dirfd,
  Pointer<Utf8> pathname,
  Pointer<_Timespec> times,
  int flags,
);

class _ToTouch {
  _ToTouch(this.file, this.dateTaken, {required this.isShortcut});
  final File file;
  final DateTime dateTaken;
  final bool isShortcut;
}
