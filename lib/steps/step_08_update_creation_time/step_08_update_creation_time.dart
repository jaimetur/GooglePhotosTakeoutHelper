import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:console_bars/console_bars.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:gpth/gpth-lib.dart';

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
  UpdateCreationTimeStep() : super('Update Creation Time');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();
    print ('');

    try {
      if (!Platform.isWindows || !context.config.updateCreationTime) {
        final reason = !Platform.isWindows
            ? 'not supported on this platform (${Platform.operatingSystem})'
            : 'disabled in configuration';

        logWarning('[Step 8/8] Skipping creation time update ($reason).', forcePrint: true);
        stopwatch.stop();
        return StepResult.success(
          stepName: name,
          duration: stopwatch.elapsed,
          data: {'updatedCount': 0, 'skipped': true},
          message: 'Creation time update skipped: $reason',
        );
      }

      print('[Step 8/8] Updating creation times (this may take a while)...');

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
        print('[Step 8/8] No files found to update creation times.');
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
        desc: '[Step 8/8] Updating creation times',
        total: filesToTouch.length,
        width: 50,
      );

      int updated = 0;
      int failed = 0;

      for (int i = 0; i < filesToTouch.length; i++) {
        final f = filesToTouch[i];
        try {
          final ok = _setFileTimesToDateTakenSync(
            f.file.path,
            f.dateTaken,
            isShortcut: f.isShortcut,
          );
          if (ok) {
            updated++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }

        progressBar.update(i + 1);
        if (i + 1 == filesToTouch.length) {
          print(''); // newline after progress bar
        }
      }

      // Explicit summary line
      print('[Step 8/8] Creation time update summary → updated: $updated, failed: $failed');

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'updatedCount': updated,
          'failedCount': failed,
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
    final shouldSkipStep =
        !Platform.isWindows || !context.config.updateCreationTime;

    if (shouldSkipStep) {
      final reason = !Platform.isWindows
          ? 'not supported on this platform (${Platform.operatingSystem})'
          : 'disabled in configuration';
      logWarning('[Step 8/8] Skipping creation time update ($reason).', forcePrint: true);
    }

    return shouldSkipStep;
  }

  /// Synchronous Win32 creation/write time update to a specific DateTime (entity.dateTaken).
  /// If [isShortcut] is true, the handle is opened with FILE_FLAG_OPEN_REPARSE_POINT
  /// so we touch the link itself (not its target). LastAccessTime is preserved as-is.
  bool _setFileTimesToDateTakenSync(
    final String filePath,
    final DateTime dateTaken, {
    required bool isShortcut,
  }) {
    try {
      return using((final Arena arena) {
        // Convert to extended-length path to avoid MAX_PATH issues on Windows.
        final String extended = _toExtendedLengthPath(filePath);
        final Pointer<Utf16> pathPtr = extended.toNativeUtf16(allocator: arena);

        // Always allow directory handles; don't follow symlinks when touching shortcuts.
        final int flags = FILE_ATTRIBUTE_NORMAL |
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
          return false;
        }

        try {
          // Target FILETIME from dateTaken (UTC)
          final Pointer<FILETIME> pCreation = arena<FILETIME>();
          final Pointer<FILETIME> pWrite = arena<FILETIME>();
          _writeDateTimeToFileTimePtr(pCreation, dateTaken.toUtc());
          _writeDateTimeToFileTimePtr(pWrite, dateTaken.toUtc());

          // Set CreationTime and LastWriteTime = dateTaken; keep LastAccessTime unchanged (nullptr)
          final bool setOk = SetFileTime(fileHandle, pCreation, nullptr, pWrite) != FALSE;
          return setOk;
        } finally {
          CloseHandle(fileHandle);
        }
      });
    } catch (_) {
      return false;
    }
  }

  // ------------------------------- Utilities --------------------------------

  /// Convert normal path to extended-length path (\\?\ prefix) for long-path safety on Windows.
  String _toExtendedLengthPath(final String p) {
    if (!Platform.isWindows) return p;
    if (p.startsWith('\\\\?\\')) return p;
    if (p.startsWith('\\\\')) return '\\\\?\\UNC${p.substring(1)}';
    return '\\\\?\\$p';
  }

  /// Write a DateTime (UTC) into a FILETIME pointer.
  /// FILETIME = 100-nanosecond intervals since January 1, 1601 (UTC).
  void _writeDateTimeToFileTimePtr(final Pointer<FILETIME> p, final DateTime utc) {
    const int epochDiff100ns = 116444736000000000; // between 1601-01-01 and 1970-01-01
    final int ftTicks = utc.millisecondsSinceEpoch * 10000 + epochDiff100ns;
    p.ref
      ..dwHighDateTime = (ftTicks >> 32) & 0xFFFFFFFF
      ..dwLowDateTime = ftTicks & 0xFFFFFFFF;
  }
}

class _ToTouch {
  final File file;
  final DateTime dateTaken;
  final bool isShortcut;
  _ToTouch(this.file, this.dateTaken, {required this.isShortcut});
}
