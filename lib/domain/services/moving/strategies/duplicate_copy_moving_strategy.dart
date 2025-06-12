import 'dart:io';

import '../../../../media.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import 'moving_strategy.dart';

/// Moving strategy that creates duplicate copies in both ALL_PHOTOS and album folders
///
/// This strategy provides maximum compatibility by creating real files in all locations,
/// but uses more disk space due to file duplication.
class DuplicateCopyMovingStrategy extends MovingStrategy {
  const DuplicateCopyMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'duplicate-copy';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => true;
  @override
  Stream<MovingResult> processMedia(
    final Media media,
    final MovingContext context,
  ) async* {
    final stopwatch = Stopwatch()..start();

    try {
      // Sort files so null key (ALL_PHOTOS) comes first
      final sortedFiles = media.files.entries.toList()
        ..sort((final a, final b) => (a.key ?? '').compareTo(b.key ?? ''));

      File? mainFile;

      for (final entry in sortedFiles) {
        final String? albumKey = entry.key;
        final file = entry.value;

        // Generate target directory
        final targetDirectory = _pathService.generateTargetDirectory(
          albumKey,
          media.dateTaken,
          context,
        );

        await _fileService.ensureDirectoryExists(targetDirectory);

        if (albumKey == null) {
          // This is the main file - move/copy it to ALL_PHOTOS
          final operation = MovingOperation(
            sourceFile: file,
            targetDirectory: targetDirectory,
            operationType: context.copyMode
                ? MovingOperationType.copy
                : MovingOperationType.move,
            dateTaken: media.dateTaken,
          );

          final resultFile = await _fileService.moveOrCopyFile(
            file,
            targetDirectory,
            copyMode: context.copyMode,
          );

          // Set file timestamp
          if (media.dateTaken != null) {
            await _fileService.setFileTimestamp(resultFile, media.dateTaken!);
          }

          mainFile = resultFile;

          yield MovingResult.success(
            operation: operation,
            resultFile: resultFile,
            duration: stopwatch.elapsed,
          );
        } else if (mainFile != null) {
          // This is an album file - create a copy
          final operation = MovingOperation(
            sourceFile: file,
            targetDirectory: targetDirectory,
            operationType:
                MovingOperationType.copy, // Always copy for duplicates
            albumKey: albumKey,
            dateTaken: media.dateTaken,
          );

          File resultFile;
          if (context.copyMode) {
            // In copy mode, copy from original source
            resultFile = await _fileService.moveOrCopyFile(
              file,
              targetDirectory,
              copyMode: true,
            );
          } else {
            // In move mode, copy from the mainFile (which was moved to ALL_PHOTOS)
            resultFile = await _fileService.moveOrCopyFile(
              mainFile,
              targetDirectory,
              copyMode: true, // Always copy for album duplicates
            );
          }

          // Set file timestamp
          if (media.dateTaken != null) {
            await _fileService.setFileTimestamp(resultFile, media.dateTaken!);
          }

          yield MovingResult.success(
            operation: operation,
            resultFile: resultFile,
            duration: stopwatch.elapsed,
          );
        }
      }
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
    // Duplicate-copy mode works on all platforms
    // Note: This mode uses more disk space due to file duplication
  }
}
