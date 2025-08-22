import '../../../../entities/media_entity.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import '../symlink_service.dart';
import 'media_entity_moving_strategy.dart';

/// Shortcut moving strategy implementation
///
/// This strategy creates shortcuts/symlinks from album folders to files in ALL_PHOTOS.
/// Files are moved to ALL_PHOTOS organized by date, and shortcuts are created in album folders.
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

      // Step 2: Create shortcuts for each album association
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
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for shortcut mode
  }
}
