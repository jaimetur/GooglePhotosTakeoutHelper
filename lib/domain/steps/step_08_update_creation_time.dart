import 'dart:io';
import '../models/pipeline_step_model.dart';

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
/// 1. **Source Timestamp**: Uses the file's current last modification time
/// 2. **Target Timestamp**: Sets creation time to match modification time
/// 3. **Preservation**: Maintains all other file attributes and metadata
/// 4. **Verification**: Confirms timestamp update was successful
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
class UpdateCreationTimeStep extends ProcessingStep {
  const UpdateCreationTimeStep() : super('Update Creation Time');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();

    try {
      if (!Platform.isWindows || !context.config.updateCreationTime) {
        if (context.config.verbose) {
          final reason = !Platform.isWindows
              ? 'not supported on this platform'
              : 'disabled in configuration';
          print('\n[Step 8/8] Skipping creation time update ($reason).');
        }
        stopwatch.stop();
        return StepResult.success(
          stepName: name,
          duration: stopwatch.elapsed,
          data: {'updatedCount': 0, 'skipped': true},
          message: 'Creation time update skipped',
        );
      }
      if (context.config.verbose) {
        print('\n[Step 8/8] Updating creation times...');
      }

      int updatedCount = 0;

      // 1. Traverse the output directory and update creation times
      final outputDir = Directory(context.config.outputPath);
      if (!await outputDir.exists()) {
        if (context.config.verbose) {
          print(
            'Output directory does not exist, skipping creation time update',
          );
        }

        stopwatch.stop();
        return StepResult.success(
          stepName: name,
          duration: stopwatch.elapsed,
          data: {'updatedCount': 0, 'skipped': true},
          message: 'Creation time update skipped - output directory not found',
        );
      } // 2. For each file, set creation time = last modified time
      // 3. Use Windows APIs/PowerShell for the operation
      updatedCount = await _updateCreationTimeRecursively(outputDir);

      if (context.config.verbose) {
        print('Creation time update completed. Updated $updatedCount files.');
      }

      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {'updatedCount': updatedCount, 'skipped': false},
        message: 'Updated creation times for $updatedCount files',
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
  bool shouldSkip(final ProcessingContext context) =>
      !Platform.isWindows || !context.config.updateCreationTime;

  /// Updates creation times recursively for all files in the directory
  ///
  /// Returns the number of files processed
  Future<int> _updateCreationTimeRecursively(final Directory directory) async {
    int count = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        try {
          // On Windows, we can use PowerShell to update creation time
          final result = await Process.run('powershell', [
            '-Command',
            '(Get-Item "${entity.path}").CreationTime = (Get-Item "${entity.path}").LastWriteTime',
          ]);
          if (result.exitCode == 0) {
            count++;
          }
        } catch (e) {
          // Continue with other files if one fails
          print('Failed to update creation time for ${entity.path}: $e');
        }
      }
    }
    return count;
  }
}
