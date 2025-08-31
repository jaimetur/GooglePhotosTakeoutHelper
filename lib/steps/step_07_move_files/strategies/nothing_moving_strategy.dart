import 'dart:io';
import 'package:gpth/gpth-lib.dart';

/// Nothing moving strategy implementation
///
/// This strategy ignores albums entirely and creates only ALL_PHOTOS with all files
/// organized chronologically. All files are moved to ALL_PHOTOS regardless of their
/// source location (year folders or albums) to ensure no data loss.
///
/// NOTE (model update):
/// - MediaEntity now exposes `primaryFile` (single canonical source), `secondaryFiles`
///   (original duplicate paths kept only as metadata), and album associations via
///   `belongToAlbums` / `albumNames`. There is no `files` map anymore.
/// - Step 3 (RemoveDuplicates) already deleted or moved physical duplicates to `_Duplicates`.
///   This strategy MUST NOT attempt to move any secondary file again. The helper
///   `_moveNonPrimaryFilesToDuplicates` is intentionally a no-op to keep API/comments
///   without duplicating work.
class NothingMovingStrategy extends MediaEntityMovingStrategy {
  const NothingMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Nothing';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    // Move ONLY the primary file to ALL_PHOTOS (or PARTNER_SHARED).
    // Albums are ignored in this strategy.

    final primaryFile = entity.primaryFile;
    final allPhotosDir = _pathService.generateTargetDirectory(
      null, // null = ALL_PHOTOS or PARTNER_SHARED
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );

    final stopwatch = Stopwatch()..start();
    try {
      final movedFile = await _fileService.moveFile(
        primaryFile,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );

      stopwatch.stop();
      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: primaryFile,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: movedFile,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      yield MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: primaryFile,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move file: $e',
        duration: stopwatch.elapsed,
      );
    }

    // Move non-primary physical files to _Duplicates (legacy helper).
    // NOTE: Step 3 already handled physical duplicates → this is now a no-op.
    yield* _moveNonPrimaryFilesToDuplicates(entity, context);
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for nothing mode
  }

  // --- helper: move all non-primary physical files to _Duplicates, preserving structure ---
  // Kept for backward compatibility with comments/APIs, but intentionally does nothing now,
  // because Step 3 already deleted/moved duplicate files.
  Stream<MediaEntityMovingResult> _moveNonPrimaryFilesToDuplicates(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    // no-op by design in the new pipeline
    return;
  }
}

// Kept for backward-compat (comment/type), though not used anymore in the no-op helper.
class _RelInfo {
  const _RelInfo({required this.relativeDir, required this.hint});
  final String relativeDir;
  final String hint;
}
