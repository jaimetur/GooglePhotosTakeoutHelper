import '../../../entities/media_entity.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import 'media_entity_moving_strategy.dart';

/// Nothing moving strategy implementation
///
/// This strategy ignores albums entirely and creates only ALL_PHOTOS with files
/// organized chronologically. This is the simplest strategy.
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
    // Only process files that have year folder associations (albumKey = null)
    // Skip album-only files
    if (!entity.files.hasYearBasedFiles) {
      // Skip album-only files in nothing mode
      return;
    }

    // Move file to ALL_PHOTOS
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
      yield primaryResult;
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
        errorMessage: 'Failed to move file: $e',
        duration: stopwatch.elapsed,
      );
      yield errorResult;
    }
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for nothing mode
  }
}
