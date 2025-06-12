import '../../../../media.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import 'moving_strategy.dart';

/// Moving strategy that ignores albums entirely
///
/// This strategy creates only ALL_PHOTOS with files from year folders,
/// providing the simplest possible organization structure.
class NothingMovingStrategy extends MovingStrategy {
  const NothingMovingStrategy(this._fileService, this._pathService);
  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'nothing';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MovingResult> processMedia(
    final Media media,
    final MovingContext context,
  ) async* {
    final stopwatch = Stopwatch()..start();

    try {
      // Only process the main file (null key), skip album files
      final mainFile = media.files[null];
      if (mainFile == null) {
        stopwatch.stop();
        yield MovingResult.failure(
          operation: MovingOperation(
            sourceFile: media.firstFile,
            targetDirectory: context.outputDirectory,
            operationType: MovingOperationType.move,
          ),
          errorMessage: 'No main file found for media',
          duration: stopwatch.elapsed,
        );
        return;
      }

      // Generate target directory
      final targetDirectory = _pathService.generateTargetDirectory(
        null, // Always use ALL_PHOTOS (null album key)
        media.dateTaken,
        context,
      );

      // Ensure directory exists
      await _fileService.ensureDirectoryExists(targetDirectory);

      // Create moving operation
      final operation = MovingOperation(
        sourceFile: mainFile,
        targetDirectory: targetDirectory,
        operationType: context.copyMode
            ? MovingOperationType.copy
            : MovingOperationType.move,
        dateTaken: media.dateTaken,
      );

      // Perform the file operation
      final resultFile = await _fileService.moveOrCopyFile(
        mainFile,
        targetDirectory,
        copyMode: context.copyMode,
      );

      // Set file timestamp
      if (media.dateTaken != null) {
        await _fileService.setFileTimestamp(resultFile, media.dateTaken!);
      }

      stopwatch.stop();
      yield MovingResult.success(
        operation: operation,
        resultFile: resultFile,
        duration: stopwatch.elapsed,
      );
    } catch (e) {
      stopwatch.stop();
      yield MovingResult.failure(
        operation: MovingOperation(
          sourceFile: media.firstFile,
          targetDirectory: context.outputDirectory,
          operationType: context.copyMode
              ? MovingOperationType.copy
              : MovingOperationType.move,
        ),
        errorMessage: e.toString(),
        duration: stopwatch.elapsed,
      );
    }
  }

  @override
  void validateContext(final MovingContext context) {
    // Nothing mode has no special requirements
  }
}
