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
///
/// ### Conflict Resolution
/// - **Filename Conflicts**: Automatically renames conflicting files
/// - **Metadata Preservation**: Maintains file timestamps and attributes
/// - **Link Creation**: Handles symlink/shortcut creation failures gracefully
/// - **Album Association**: Maintains proper album relationships even with conflicts
///
/// ## Configuration Integration
/// - Applies user's chosen album organization strategy, date division, file operation modes,
///   and verbose output preferences. Adapts to OS/filesystem limitations and tunes performance.
class MoveFilesStep extends ProcessingStep {
  const MoveFilesStep() : super('Move Files');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final stopwatch = Stopwatch()..start();

    try {
      // 1) Optional transformation of Pixel .MP/.MV files (before estimating ops)
      int transformedCount = 0;
      if (context.config.transformPixelMp) {
        transformedCount = await _transformPixelFiles(context);
        if (context.config.verbose) {
          print('Transformed $transformedCount Pixel .MP/.MV files to .mp4');
        }
      }

      // 2) Prepare moving context and service
      final movingContext = MovingContext.fromConfig(
        context.config,
        context.outputDirectory,
      );
      final movingService = MediaEntityMovingService();

      // 3) Compute the number of REAL file operations (exclude symlinks/shortcuts/json)
      final filesPlanned = _estimateRealFileOpsPlanned(context);

      // 4) Initialize a progress bar that tracks ONLY real file operations
      final progressBar = FillingBar(
        desc: 'Moving files',
        total: filesPlanned > 0 ? filesPlanned : 1,
        width: 50,
      );

      // 5) Counters
      int processedEntities = 0;       // secondary: entities
      int filesMovedCount = 0;         // primary: real file ops (move/copy)
      int symlinksCreatedCount = 0;    // symlink/shortcut ops
      int jsonWritesCount = 0;         // JSON writes (if any)
      int otherOpsCount = 0;           // any other operation kind

      // 6) Consume stream; progress is driven by onOperation classification
      await for (final _ in movingService.moveMediaEntities(
        context.mediaCollection,
        movingContext,
        onOperation: (final result) {
          final kind = _classifyOperationKind(result);

          if (kind == _OpKind.file) {
            filesMovedCount++;
            // Keep progress bar in range (in case finalize adds extra file ops)
            final next = filesMovedCount <= progressBar.total
                ? filesMovedCount
                : progressBar.total;
            progressBar.update(next);
          } else if (kind == _OpKind.symlink) {
            symlinksCreatedCount++;
          } else if (kind == _OpKind.json) {
            jsonWritesCount++;
          } else {
            otherOpsCount++;
          }
        },
      )) {
        processedEntities++;
      }

      // 7) Finalize timing and UI
      stopwatch.stop();
      print(''); // newline after progress bar

      // 8) Build success result with split counters
      final messageBuffer = StringBuffer()
        ..write('Moved $filesMovedCount files to output directory')
        ..write(', created $symlinksCreatedCount symlinks');
      if (jsonWritesCount > 0) {
        messageBuffer.write(', wrote $jsonWritesCount JSON entries');
      }

      return StepResult.success(
        stepName: name,
        duration: stopwatch.elapsed,
        data: <String, dynamic>{
          'processedEntities': processedEntities,
          'transformedCount': transformedCount,
          'albumBehavior': context.config.albumBehavior.value,
          'filesMovedCount': filesMovedCount,
          'symlinksCreatedCount': symlinksCreatedCount,
          'jsonWritesCount': jsonWritesCount,
          'otherOpsCount': otherOpsCount,
          'filesPlanned': filesPlanned,
        },
        message: messageBuffer.toString(),
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

  /// Estimate how many REAL file operations (move/copy) will happen,
  /// excluding symlinks/shortcuts and JSON writes.
  /// Heuristic based on album behavior:
  /// - duplicate: all placements are real files → sum of placements
  /// - json: 1 per entity
  /// - reverse/shortcut/nothing: 1 per entity (a single primary, the rest are links or none)
  int _estimateRealFileOpsPlanned(final ProcessingContext context) {
    final behavior = context.config.albumBehavior.value.toString().toLowerCase();

    final bool isDuplicate = behavior.contains('duplicate');
    final bool isJson = behavior.contains('json');
    // reverse/shortcut/nothing fall back to 1 per entity

    int total = 0;
    for (final mediaEntity in context.mediaCollection.media) {
      final placements = mediaEntity.files.files.length;
      if (isDuplicate) {
        total += placements; // each placement is a real copy
      } else if (isJson) {
        total += 1; // only ALL_PHOTOS real file
      } else {
        total += 1; // one primary real file (ALL_PHOTOS or album), rest links or nothing
      }
    }
    return total;
  }

  /// Classify the operation kind without relying on unsupported reflection.
  /// We use a robust, compile-safe heuristic based on `toString()` contents.
  /// This avoids invalid dynamic access in AOT and still provides useful split counters.
  _OpKind _classifyOperationKind(final dynamic result) {
    // Use the string representation as a best-effort signal
    final String text = (result?.toString() ?? '').toLowerCase();

    // Symlink/shortcut detection first
    if (text.contains('symlink') || text.contains('shortcut') || text.contains('link ->')) {
      return _OpKind.symlink;
    }

    // JSON-related detection
    if (text.contains('.json') || text.contains('json')) {
      // Some operations may include JSON path; treat as JSON write
      return _OpKind.json;
    }

    // Clear "file" operation hints
    if (text.contains(' move ') ||
        text.contains(' copy ') ||
        text.contains('rename') ||
        text.contains('moved') ||
        text.contains('copied')) {
      return _OpKind.file;
    }

    // Fallback: default to file to avoid under-counting progress
    return _OpKind.file;
  }

  /// Transform Pixel .MP/.MV files to .mp4 extension.
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

enum _OpKind { file, symlink, json, other }
