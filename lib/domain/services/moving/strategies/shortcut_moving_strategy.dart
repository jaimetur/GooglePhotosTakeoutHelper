import 'dart:io';

import '../../../../media.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import '../shortcut_service.dart';
import 'moving_strategy.dart';

/// Moving strategy that creates shortcuts in album folders pointing to ALL_PHOTOS
///
/// This is the recommended strategy as it provides space efficiency while
/// maintaining both chronological and album organization.
class ShortcutMovingStrategy extends MovingStrategy {
  const ShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._shortcutService,
  );
  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final ShortcutService _shortcutService;

  @override
  String get name => 'shortcut';

  @override
  bool get createsShortcuts => true;

  @override
  bool get createsDuplicates => false;

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
          // This is an album file - create a shortcut
          try {
            final operation = MovingOperation(
              sourceFile: file,
              targetDirectory: targetDirectory,
              operationType: MovingOperationType.createShortcut,
              albumKey: albumKey,
              dateTaken: media.dateTaken,
            );

            final shortcutFile = await _shortcutService.createShortcut(
              targetDirectory,
              mainFile,
            );

            yield MovingResult.success(
              operation: operation,
              resultFile: shortcutFile,
              duration: stopwatch.elapsed,
            );
          } catch (e) {
            // If shortcut creation fails, fall back to copying the file
            print(
              '[Warning] Creating shortcut for ${file.path} in $albumKey '
              'failed: $e - copying normal file instead',
            );

            final fallbackOperation = MovingOperation(
              sourceFile: file,
              targetDirectory: targetDirectory,
              operationType: context.copyMode
                  ? MovingOperationType.copy
                  : MovingOperationType.move,
              albumKey: albumKey,
              dateTaken: media.dateTaken,
            );

            final resultFile = await _fileService.moveOrCopyFile(
              file,
              targetDirectory,
              copyMode: context.copyMode,
            );

            if (media.dateTaken != null) {
              await _fileService.setFileTimestamp(resultFile, media.dateTaken!);
            }

            yield MovingResult.success(
              operation: fallbackOperation,
              resultFile: resultFile,
              duration: stopwatch.elapsed,
            );
          }
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
    // Shortcut mode works on all platforms
  }
}
