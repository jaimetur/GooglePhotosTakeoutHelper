import 'dart:io';
import 'package:gpth/gpth-lib.dart';

/// Duplicate-copy moving strategy implementation
///
/// This strategy creates actual file copies in both ALL_PHOTOS and album folders.
/// Files are moved to ALL_PHOTOS and copied to each album folder.
///
/// NOTE (model update):
/// - MediaEntity now has `primaryFile` (single source), `secondaryFiles` (original duplicate paths),
///   and `belongToAlbums` (album associations). There is no `files` map anymore.
/// - Physical duplicates (non-primary files) were already deleted or moved to `_Duplicates` in Step 3,
///   so this strategy MUST NOT try to move them again here. We only handle:
///     1) Move/rename of the PRIMARY file to the canonical ALL_PHOTOS path
///     2) Copy of the PRIMARY to each album folder (duplicate-copy behavior)
class DuplicateCopyMovingStrategy extends MediaEntityMovingStrategy {
  const DuplicateCopyMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Duplicate Copy';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => true;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    // Step 1: Ensure we have (or create) the primary canonical file in ALL_PHOTOS (or PARTNER_SHARED)
    final originalPrimaryFile = entity.primaryFile;
    final allPhotosDir = _pathService.generateTargetDirectory(
      null, // null = ALL_PHOTOS or PARTNER_SHARED
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );

    // If the original file physically resides inside one of the album folders that we will later populate,
    // we must MOVE it to the canonical ALL_PHOTOS folder instead of copying it, otherwise the original
    // remains and causes leftover files. Heuristic: if its path contains any of the album directory target paths.
    File canonicalFile = originalPrimaryFile;
    final stopwatch = Stopwatch()..start();
    try {
      if (entity.albumNames.isNotEmpty) {
        // Pre-generate album directories to test path containment cheaply
        final albumDirs = <String, Directory>{};
        for (final albumName in entity.albumNames) {
          final dir = _pathService.generateTargetDirectory(
            albumName,
            entity.dateTaken,
            context,
            isPartnerShared: entity.partnershared,
          );
          albumDirs[albumName] = dir;
        }

        final originalPathLower = originalPrimaryFile.path.toLowerCase();
        final isInsideAlbum = albumDirs.values.any(
          (final d) => originalPathLower.startsWith(d.path.toLowerCase()),
        );

        // Regular flow: move (rename) into ALL_PHOTOS (if already there rename handles uniqueness)
        canonicalFile = await _fileService.moveFile(
          originalPrimaryFile,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
      } else {
        // No albums: just move
        canonicalFile = await _fileService.moveFile(
          originalPrimaryFile,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
      }

      stopwatch.stop();
      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: originalPrimaryFile,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: canonicalFile,
        duration: stopwatch.elapsed,
      );

      // Step 2: For each album, ensure a copy exists (use canonicalFile as source)
      for (final albumName in entity.albumNames) {
        final albumDir = _pathService.generateTargetDirectory(
          albumName,
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnershared,
        );

        final copyStopwatch = Stopwatch()..start();
        try {
          final copiedFile = await _fileService.copyFile(
            canonicalFile,
            albumDir,
            dateTaken: entity.dateTaken,
          );
          copyStopwatch.stop();
          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: canonicalFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: copiedFile,
            duration: copyStopwatch.elapsed,
          );
        } catch (e) {
          copyStopwatch.stop();
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: canonicalFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to copy to album folder: $e',
            duration: copyStopwatch.elapsed,
          );
        }
      }
    } catch (e) {
      stopwatch.stop();
      yield MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: originalPrimaryFile,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to establish canonical file: $e',
        duration: stopwatch.elapsed,
      );
    }

    // IMPORTANT (new data model):
    // Do NOT move secondary/non-primary files here. Step 3 already deleted or moved them to `_Duplicates`.
    // Album reconstruction in Step 7 works exclusively from the canonical primary file.
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for duplicate-copy strategy
  }
}
