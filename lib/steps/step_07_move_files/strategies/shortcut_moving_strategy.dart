import 'package:gpth/gpth-lib.dart';

/// Shortcut moving strategy implementation
///
/// This strategy creates shortcuts/symlinks from album folders to files in ALL_PHOTOS.
/// Files are moved to ALL_PHOTOS organized by date, and shortcuts are created in album folders.
///
/// NOTE (model update):
/// - MediaEntity now exposes `primaryFile` (single canonical source), `secondaryFiles`
///   (original duplicate paths kept only as metadata), and album associations via
///   `belongToAlbums` / `albumNames`. There is no `files` map anymore.
/// - Step 3 (RemoveDuplicates) already deleted or moved physical duplicates to `_Duplicates`.
///   This strategy MUST NOT attempt to move any secondary file again. The helper
///   `_moveNonPrimaryFilesToDuplicates` is intentionally a no-op to keep API/comments
///   without duplicating work.
class ShortcutMovingStrategy extends MediaEntityMovingStrategy {
  const ShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  @override
  String get name => 'Shortcut';

  @override
  bool get createsShortcuts => true;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final results = <MediaEntityMovingResult>[];

    // Step 1: Move primary file to ALL_PHOTOS (or PARTNER_SHARED)
    final primaryFile = entity.primaryFile;
    final allPhotosDir = _pathService.generateTargetDirectory(
      null, // null = ALL_PHOTOS (or PARTNER_SHARED if partner shared)
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
      final primaryResult = MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: primaryFile,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: movedFile,
        duration: stopwatch.elapsed,
      );
      results.add(primaryResult);
      yield primaryResult;

      // Step 2: Create shortcuts for each album association (use primary as source)
      for (final albumName in entity.albumNames) {
        final albumDir = _pathService.generateTargetDirectory(
          albumName,
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnershared,
        );
        final shortcutStopwatch = Stopwatch()..start();
        try {
          final shortcutFile = await _symlinkService.createSymlink(
            albumDir,
            movedFile,
          );

          shortcutStopwatch.stop();
          final shortcutResult = MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createSymlink,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: shortcutFile,
            duration: shortcutStopwatch.elapsed,
          );
          results.add(shortcutResult);
          yield shortcutResult;
        } catch (e) {
          shortcutStopwatch.stop();
          final errorResult = MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createSymlink,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to create shortcut: $e',
            duration: shortcutStopwatch.elapsed,
          );
          results.add(errorResult);
          yield errorResult;
        }
      }
    } catch (e) {
      stopwatch.stop();
      final errorResult = MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: primaryFile,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move primary file: $e',
        duration: stopwatch.elapsed,
      );
      results.add(errorResult);
      yield errorResult;
    }

    // Move non-primary physical files to _Duplicates, preserving structure
    // NOTE: Step 3 already handled physical duplicates → this is now a no-op.
    yield* _moveNonPrimaryFilesToDuplicates(entity, context);
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for shortcut mode
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

