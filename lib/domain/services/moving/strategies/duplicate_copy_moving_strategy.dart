import '../../../entities/media_entity.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import 'media_entity_moving_strategy.dart';

/// Duplicate-copy moving strategy implementation
///
/// This strategy creates actual file copies in both ALL_PHOTOS and album folders.
/// Files are moved to ALL_PHOTOS and copied to each album folder.
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
    final results = <MediaEntityMovingResult>[];

    // Step 1: Move primary file to ALL_PHOTOS
    final primaryFile = entity.primaryFile;
    final allPhotosDir = _pathService.generateTargetDirectory(
      null, // null = ALL_PHOTOS
      entity.dateTaken,
      context,
    );

    final stopwatch = Stopwatch()..start();
    try {
      final movedFile = await _fileService.moveOrCopyFile(
        primaryFile,
        allPhotosDir,
        copyMode: context.copyMode,
        dateTaken: entity.dateTaken,
      );

      stopwatch.stop();
      final primaryResult = MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: primaryFile,
          targetDirectory: allPhotosDir,
          operationType: context.copyMode
              ? MediaEntityOperationType.copy
              : MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: movedFile,
        duration: stopwatch.elapsed,
      );
      results.add(primaryResult);
      yield primaryResult;

      // Step 2: Copy file to each album folder
      for (final albumName in entity.albumNames) {
        final albumDir = _pathService.generateTargetDirectory(
          albumName,
          entity.dateTaken,
          context,
        );

        final copyStopwatch = Stopwatch()..start();
        try {
          final copiedFile = await _fileService.moveOrCopyFile(
            movedFile,
            albumDir,
            copyMode: true, // Always copy for album folders
            dateTaken: entity.dateTaken,
          );

          copyStopwatch.stop();
          final copyResult = MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: copiedFile,
            duration: copyStopwatch.elapsed,
          );
          results.add(copyResult);
          yield copyResult;
        } catch (e) {
          copyStopwatch.stop();
          final errorResult = MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to copy to album folder: $e',
            duration: copyStopwatch.elapsed,
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
          operationType: context.copyMode
              ? MediaEntityOperationType.copy
              : MediaEntityOperationType.move,
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
    // No special validation needed for duplicate-copy mode
  }
}
