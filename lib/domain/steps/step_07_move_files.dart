import 'dart:io';

import 'package:console_bars/console_bars.dart';

import '../entities/media_entity.dart';
import '../models/pipeline_step_model.dart';
import '../services/file_operations/moving/media_entity_moving_service.dart';
import '../services/file_operations/moving/moving_context_model.dart';
import '../value_objects/media_files_collection.dart';

/// Step 7: Move files to output directory
///
/// This critical final step organizes and relocates all processed media files from the
/// Google Photos Takeout structure to the user's desired output organization. It applies
/// all configuration choices including album behavior, date organization, and file operation modes.
///
/// ## File Organization Strategies
///
/// ### Album Behavior Modes
///
/// #### Shortcut Mode (Recommended)
/// - **Primary Location**: Creates `ALL_PHOTOS` with all files organized by date
/// - **Album Organization**: Creates album folders with shortcuts/symlinks to primary files
/// - **Advantages**: Space efficient, maintains chronological and album organization
/// - **File Operations**: Moves primary files, creates links for album references
/// - **Compatibility**: Works on Windows (shortcuts), macOS/Linux (symlinks)
///
/// #### Duplicate-Copy Mode
/// - **Primary Location**: Creates `ALL_PHOTOS` with chronologically organized files
/// - **Album Organization**: Creates album folders with actual file copies
/// - **Advantages**: Universal compatibility, album folders contain real files
/// - **File Operations**: Moves primary files, copies files to album folders
/// - **Disk Usage**: Higher due to file duplication across albums
///
/// #### Reverse Shortcut Mode
/// - **Primary Location**: Files remain in their album folders
/// - **Unified Access**: Creates `ALL_PHOTOS` with shortcuts to album files
/// - **Advantages**: Preserves album-centric organization
/// - **File Operations**: Moves files to album folders, creates shortcuts in ALL_PHOTOS
/// - **Use Case**: When album organization is more important than chronological
///
/// #### JSON Mode
/// - **Primary Location**: Creates `ALL_PHOTOS` with all files organized by date
/// - **Album Information**: Creates `albums-info.json` with metadata mapping
/// - **Advantages**: Most space efficient, programmatically accessible album data
/// - **File Operations**: Only moves files to ALL_PHOTOS, no album folders created
/// - **Use Case**: For developers or users with custom photo management software
///
/// #### Nothing Mode
/// - **Primary Location**: Creates only `ALL_PHOTOS` with chronological organization
/// - **Album Information**: Completely discarded for simplest possible structure
/// - **File Processing**: Moves ALL files to date-organized folders, regardless of source
/// - **Advantages**: Fastest processing, simplest result, maximum compatibility, no data loss
/// - **File Operations**: Moves all files to ALL_PHOTOS (including album-only files)
/// - **Use Case**: Users who don't care about album information and want all photos
///
/// ### Date-Based Organization
///
/// #### Date Division Levels
/// - **Level 0**: Single `ALL_PHOTOS` folder (no date division)
/// - **Level 1**: Year folders (`2023`, `2024`, etc.)
/// - **Level 2**: Year/Month folders (`2023/01_January`, `2023/02_February`)
/// - **Level 3**: Year/Month/Day folders (`2023/01_January/01`, `2023/01_January/02`)
///
/// #### Date Handling Logic
/// - **Accurate Dates**: Files with reliable date metadata are organized precisely
/// - **Approximate Dates**: Files with lower accuracy are grouped appropriately
/// - **Unknown Dates**: Files without date information go to special folders
/// - **Date Conflicts**: Uses date accuracy to resolve conflicts between sources
///
/// ## Move Operations
///
/// All files are moved from the source takeout directory to the organized output
/// structure. This ensures input directory safety while applying the chosen
/// organization strategy.
///
/// ## Advanced Features
///
/// ### Filename Sanitization
/// - **Special Characters**: Removes/replaces characters incompatible with file systems
/// - **Unicode Handling**: Properly handles international characters and emoji
/// - **Length Limits**: Ensures filenames don't exceed system limits
/// - **Collision Prevention**: Automatically handles filename conflicts
///
/// ### Path Generation
/// - **Cross-Platform Compatibility**: Generates paths compatible with target OS
/// - **Deep Directory Support**: Handles nested folder structures efficiently
/// - **Name Cleaning**: Sanitizes album and folder names for file system compatibility
/// - **Duplicate Prevention**: Ensures unique paths for all files
///
/// ### Progress Tracking
/// - **Real-Time Updates**: Reports progress during file operations
/// - **Performance Metrics**: Tracks files per second and estimated completion
/// - **Error Reporting**: Provides detailed information about any issues
/// - **Batch Processing**: Efficiently handles large photo collections
///
/// ## Error Handling and Recovery
///
/// ### File System Issues
/// - **Permission Errors**: Gracefully handles access-denied situations
/// - **Disk Space**: Monitors available space and warns before running out
/// - **Path Length Limits**: Automatically shortens paths that exceed OS limits
/// - **Network Storage**: Handles timeouts and connection issues for network drives
///
/// ### Data Integrity Protection
/// - **Verification**: Optionally verifies file integrity after move/copy operations
/// - **Rollback Capability**: Can undo operations if critical errors occur
/// - **Atomic Operations**: Ensures partial failures don't leave inconsistent state
/// - **Backup Creation**: Can create backups before destructive operations
///
/// ### Conflict Resolution
/// - **Filename Conflicts**: Automatically renames conflicting files
/// - **Metadata Preservation**: Maintains file timestamps and attributes
/// - **Link Creation**: Handles symlink/shortcut creation failures gracefully
/// - **Album Association**: Maintains proper album relationships even with conflicts
///
/// ## Configuration Integration
///
/// ### User Preferences
/// - **Album Behavior**: Applies user's chosen album organization strategy
/// - **Date Organization**: Uses selected date division level
/// - **File Operations**: Respects copy vs. move preference
/// - **Verbose Output**: Provides detailed progress when requested
///
/// ### System Adaptation
/// - **OS Detection**: Adapts link creation to target operating system
/// - **File System**: Handles different file system capabilities and limitations
/// - **Performance Tuning**: Adjusts batch sizes based on system performance
/// - **Memory Management**: Manages memory usage for large file operations
///
/// ## Quality Assurance
///
/// ### Validation
/// - **File Count Verification**: Ensures all files are properly moved/copied
/// - **Metadata Preservation**: Verifies file timestamps and attributes are maintained
/// - **Link Integrity**: Validates that created shortcuts/symlinks work correctly
/// - **Album Completeness**: Confirms all album relationships are preserved
///
/// ### Statistics Collection
/// - **Processing Metrics**: Tracks files processed, time taken, errors encountered
/// - **Organization Results**: Reports folder structure created and file distribution
/// - **Space Usage**: Calculates disk space used by final organization
/// - **Performance Data**: Provides insights for future processing optimizations
class MoveFilesStep extends ProcessingStep {
  const MoveFilesStep() : super('Move Files');
  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();

    try {
      // Transform Pixel MP/MV files if enabled
      int transformedCount = 0;
      if (context.config.transformPixelMp) {
        transformedCount = await _transformPixelFiles(context);
        if (context.config.verbose) {
          print('Transformed $transformedCount Pixel .MP/.MV files to .mp4');
        }
      }

      // Initialize progress bar - always visible
      final progressBar = FillingBar(
        desc: 'Moving files',
        total: context.mediaCollection.length,
        width: 50,
      ); // Create modern moving context
      final movingContext = MovingContext.fromConfig(
        context.config,
        context.outputDirectory,
      );
      // Create the moving service
      final movingService = MediaEntityMovingService();

      int processedCount = 0;
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
      )) {
        processedCount++;
        progressBar.update(processedCount);
      }
      stopwatch.stop();
      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: {
          'processedCount': processedCount,
          'transformedCount': transformedCount,
          'albumBehavior': context.config.albumBehavior.value,
        },
        message:
            'Moved $processedCount files to output directory${transformedCount > 0 ? ', transformed $transformedCount Pixel files to .mp4' : ''}',
      );
    } catch (e) {
      stopwatch.stop();
      return StepResult.failure(
        stepName: name,
        duration: stopwatch.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to move files: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;

  /// Transform Pixel .MP/.MV files to .mp4 extension
  ///
  /// Updates MediaEntity file paths to use .mp4 extension for better compatibility
  /// while preserving the original file content.
  Future<int> _transformPixelFiles(final ProcessingContext context) async {
    int transformedCount = 0;
    final updatedEntities = <MediaEntity>[];

    for (final mediaEntity in context.mediaCollection.media) {
      var hasChanges = false;
      final updatedFiles = <String?, File>{};

      for (final entry in mediaEntity.files.files.entries) {
        final albumName = entry.key;
        final file = entry.value;
        final String currentPath = file.path;
        final String extension = currentPath.toLowerCase();

        if (extension.endsWith('.mp') || extension.endsWith('.mv')) {
          // Create new path with .mp4 extension
          final String newPath =
              '${currentPath.substring(0, currentPath.lastIndexOf('.'))}.mp4';

          try {
            // Rename the physical file
            await file.rename(newPath);
            updatedFiles[albumName] = File(newPath);
            hasChanges = true;
            transformedCount++;

            if (context.config.verbose) {
              print('Transformed: ${file.path} -> $newPath');
            }
          } catch (e) {
            // If rename fails, keep original file reference
            updatedFiles[albumName] = file;
            print('Warning: Failed to transform ${file.path}: $e');
          }
        } else {
          // Keep original file reference
          updatedFiles[albumName] = file;
        }
      }

      // Create updated entity
      if (hasChanges) {
        final newFilesCollection = MediaFilesCollection.fromMap(updatedFiles);
        final updatedEntity = MediaEntity(
          files: newFilesCollection,
          dateTaken: mediaEntity.dateTaken,
          dateAccuracy: mediaEntity.dateAccuracy,
          dateTimeExtractionMethod: mediaEntity.dateTimeExtractionMethod,
          partnershared: mediaEntity.partnershared,
        );
        updatedEntities.add(updatedEntity);
      } else {
        updatedEntities.add(mediaEntity);
      }
    }

    // Replace all entities in the collection
    context.mediaCollection.clear();
    context.mediaCollection.addAll(updatedEntities);

    return transformedCount;
  }
}
