import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';

/// Step 5: Find and merge album relationships
///
/// This sophisticated step analyzes the media collection to identify files that represent
/// the same photo/video across different albums and locations, then merges them into
/// unified Media objects. This is crucial for Google Photos exports where the same file
/// appears in both year folders and multiple album folders.
///
/// ## Album Relationship Detection
///
/// ### Content-Based Matching
/// - **Hash Comparison**: Uses SHA-256 hashing to identify identical file content
/// - **Size Verification**: Pre-filters by file size before expensive hash calculations
/// - **Binary Comparison**: Ensures exact content matches for reliable identification
/// - **Performance Optimization**: Groups by size first to minimize hash operations
///
/// ### File Location Analysis
/// - **Year Folder Files**: Primary files from "Photos from YYYY" directories
/// - **Album Folder Files**: Duplicate copies in named album directories
/// - **Cross-Reference Mapping**: Identifies which albums contain each photo
/// - **Relationship Preservation**: Maintains all album associations for each file
///
/// ### Multi-Album Detection
/// Files appearing in multiple albums are properly handled:
/// - **Album List Consolidation**: Merges all album names into single Media object
/// - **File Path Preservation**: Keeps references to all file locations
/// - **Metadata Reconciliation**: Chooses best metadata from available sources
/// - **Duplicate Elimination**: Removes redundant Media objects after merging
///
/// ## Merging Logic
///
/// ### Data Consolidation Strategy
/// When multiple Media objects represent the same file:
/// 1. **Date Accuracy Priority**: Chooses the Media with best date accuracy
/// 2. **Album Information Merge**: Combines all album associations
/// 3. **File Reference Consolidation**: Preserves all file location references
/// 4. **Metadata Selection**: Uses most reliable metadata source
/// 5. **Original Cleanup**: Removes now-redundant Media objects
///
/// ### Best Source Selection
/// The algorithm prioritizes:
/// - **Higher date accuracy** (lower accuracy number = better)
/// - **Shorter filename length** (often indicates original vs processed)
/// - **Year folder over album folder** (primary source preference)
/// - **Earlier discovery order** (first found = canonical)
///
/// ### Album Association Management
/// - **Null Key Preservation**: Maintains year folder association (null key)
/// - **Named Album Keys**: Preserves all album folder associations
/// - **Album Name Cleanup**: Handles special characters and emoji in album names
/// - **Hierarchy Respect**: Maintains Google Photos album organization structure
///
/// ## Processing Performance
///
/// ### Optimization Strategies
/// - **Size-Based Grouping**: Groups files by size before hash comparison
/// - **Incremental Processing**: Processes files in batches for memory efficiency
/// - **Hash Caching**: Avoids recalculating hashes for the same files
/// - **Early Termination**: Skips further processing when no matches possible
///
/// ### Scalability Features
/// - **Large Collection Support**: Efficiently handles thousands of photos
/// - **Memory Management**: Processes groups incrementally to control memory usage
/// - **Progress Reporting**: Provides feedback for long-running operations
/// - **Interruption Handling**: Can be safely interrupted and resumed
///
/// ## Album Behavior Preparation
///
/// This step prepares the media collection for various album handling modes:
///
/// ### Shortcut Mode Preparation
/// - **Primary File Identification**: Designates main file for each photo
/// - **Album Reference Setup**: Prepares album folder references for linking
///
/// ### Duplicate-Copy Mode Preparation
/// - **Multi-Location Tracking**: Maintains all file location information
/// - **Copy Source Identification**: Identifies which files need album copies
/// - **Album Structure Mapping**: Maps album organization for file duplication
///
/// ### JSON Mode Preparation
/// - **Album Membership Tracking**: Records which albums contain each file
/// - **Metadata Consolidation**: Prepares album information for JSON export
/// - **File-Album Associations**: Creates mapping for JSON output generation
///
/// ## Error Handling and Edge Cases
///
/// ### File Access Issues
/// - **Permission Errors**: Gracefully handles inaccessible files
/// - **Corrupted Files**: Skips files that cannot be hashed
/// - **Missing Files**: Handles broken file references
/// - **Network Storage**: Manages timeouts and connection issues
///
/// ### Data Integrity Protection
/// - **Hash Verification**: Ensures content matching is accurate
/// - **Metadata Validation**: Verifies merged metadata consistency
/// - **Rollback Capability**: Can undo merging if issues detected
/// - **Audit Logging**: Tracks all merge operations for debugging
///
/// ### Special Cases
/// - **Identical Filenames**: Handles files with same name but different content
/// - **Modified Timestamps**: Manages files with different modification times
/// - **Size Variations**: Handles minor size differences due to metadata changes
/// - **Encoding Differences**: Manages files with different character encodings
///
/// ## Integration and Dependencies
///
/// ### Prerequisites
/// - **Media Discovery**: Requires fully populated MediaCollection
/// - **Date Extraction**: Benefits from date information for conflict resolution
/// - **Duplicate Removal**: Should run after basic duplicate detection
///
/// ### Output Usage
/// - **File Moving**: Provides unified Media objects for organization
/// - **Album Creation**: Enables proper album folder structure generation
/// - **Symlink Creation**: Supports linking strategies for album modes
/// - **Statistics Generation**: Provides data for final processing reports
///
/// ### Configuration Dependencies
/// - **Album Behavior**: Different merging strategies for different output modes
/// - **Verbose Mode**: Controls detailed progress and statistics reporting
/// - **Performance Settings**: May use different algorithms for large collections
///
/// ───────────────────────────────────────────────────────────────────────────
/// ADAPTATION NOTE (new data model):
/// In the new pipeline, Step 3 already consolidated duplicates and selected a
/// single primary per entity. Therefore, Step 5 no longer performs content-based
/// merging. Instead, it consolidates and normalizes album memberships stored in
/// `belongToAlbums`, ensures each membership has at least one `sourceDirectory`
/// (parent folder of `primaryFile` as fallback), and emits album statistics.
/// It keeps return data keys compatible with callers (mergedCount/groupsMerged/albumsMerged).
/// ───────────────────────────────────────────────────────────────────────────
class FindAlbumsStep extends ProcessingStep with LoggerMixin {
  FindAlbumsStep() : super('Find Albums');

  @override
  Future<StepResult> execute(final ProcessingContext context) async {
    final sw = Stopwatch()..start();

    try {
      print('\n[Step 5/8] Finding albums (this may take a while)...');

      final collection = context.mediaCollection;
      final initial = collection.length;

      if (collection.isEmpty) {
        sw.stop();
        return StepResult.success(
          stepName: name,
          duration: sw.elapsed,
          data: {
            'initialCount': 0,
            'finalCount': 0,
            'mergedCount': 0,
            'albumsMerged': 0,
            'groupsMerged': 0,
            'mediaWithAlbums': 0,
            'distinctAlbums': 0,
            'albumCounts': const <String, int>{},
            'enrichedAlbumInfos': 0,
          },
          message: 'No media to process.',
        );
      }

      // Consolidation over current entities (no content merges; Step 3 already did it)
      int mediaWithAlbums = 0;
      int enrichedAlbumInfos = 0;
      final Map<String, int> albumCounts = <String, int>{};

      for (int i = 0; i < collection.length; i++) {
        final e = collection[i];
        final Map<String, AlbumInfo> albums = e.belongToAlbums;

        if (albums.isEmpty) continue;
        mediaWithAlbums++;

        Map<String, AlbumInfo> updated = albums;
        bool changed = false;

        // 1) Sanitize album names (trim) and merge if the normalized key collides.
        for (final entry in albums.entries) {
          final String origName = entry.key;
          final String sanitized = _sanitizeAlbumName(origName);
          if (sanitized != origName) {
            final AlbumInfo incoming = entry.value;
            final AlbumInfo merged = (updated[sanitized] == null)
                ? incoming
                : updated[sanitized]!.merge(incoming);
            if (identical(updated, albums)) {
              updated = Map<String, AlbumInfo>.from(albums)
                ..remove(origName)
                ..[sanitized] = merged;
            } else {
              updated
                ..remove(origName)
                ..[sanitized] = merged;
            }
            changed = true;
          }
        }

        // 2) Ensure at least one sourceDirectory per existing membership.
        for (final entry in updated.entries) {
          final AlbumInfo info = entry.value;
          if (info.sourceDirectories.isEmpty) {
            final String parent = _safeParentDir(e.primaryFile);
            final AlbumInfo patched = info.addSourceDir(parent);
            if (!identical(updated, albums) || changed) {
              updated = Map<String, AlbumInfo>.from(updated)
                ..[entry.key] = patched;
            } else {
              updated = Map<String, AlbumInfo>.from(albums)
                ..[entry.key] = patched;
            }
            enrichedAlbumInfos++;
            changed = true;
          }
        }

        // Apply updates if any
        if (changed) {
          final updatedEntity = MediaEntity(
            primaryFile: e.primaryFile,
            secondaryFiles: e.secondaryFiles,
            belongToAlbums: updated,
            dateTaken: e.dateTaken,
            dateAccuracy: e.dateAccuracy,
            dateTimeExtractionMethod: e.dateTimeExtractionMethod,
            partnershared: e.partnerShared,
          );
          collection.replaceAt(i, updatedEntity);
        }

        // Stats (use sanitized keys from the possibly updated entity)
        for (final albumName in collection[i].belongToAlbums.keys) {
          if (albumName.trim().isEmpty) continue;
          albumCounts[albumName] = (albumCounts[albumName] ?? 0) + 1;
        }
      }

      final int totalAlbums = albumCounts.length;
      final int finalCount = collection.length;
      const int mergedCount = 0; // no entity-level merges in the new model

      print('[Step 5/8] Media with album associations: $mediaWithAlbums');
      print('[Step 5/8] Distinct album folders detected: $totalAlbums');

      sw.stop();
      return StepResult.success(
        stepName: name,
        duration: sw.elapsed,
        data: {
          'initialCount': initial,
          'finalCount': finalCount,
          'mergedCount': mergedCount,
          'albumsMerged': 0,
          'groupsMerged': 0,
          'mediaWithAlbums': mediaWithAlbums,
          'distinctAlbums': totalAlbums,
          'albumCounts': albumCounts,
          'enrichedAlbumInfos': enrichedAlbumInfos,
        },
        message:
            'Found $totalAlbums different albums ($mergedCount albums were merged)',
      );
    } catch (e) {
      sw.stop();
      return StepResult.failure(
        stepName: name,
        duration: sw.elapsed,
        error: e is Exception ? e : Exception(e.toString()),
        message: 'Failed to find albums: $e',
      );
    }
  }

  @override
  bool shouldSkip(final ProcessingContext context) =>
      context.mediaCollection.isEmpty;

  // ───────────────────────────── Helpers ─────────────────────────────

  String _sanitizeAlbumName(final String name) {
    final n = name.trim();
    return n.isEmpty ? name : n;
  }

  /// Returns parent directory path from a FileEntity effective path (targetPath if present, else sourcePath).
  String _safeParentDir(final FileEntity fe) {
    try {
      final String p = fe.path; // effective path (target if moved)
      return File(p).parent.path;
    } catch (_) {
      return '';
    }
  }
}
