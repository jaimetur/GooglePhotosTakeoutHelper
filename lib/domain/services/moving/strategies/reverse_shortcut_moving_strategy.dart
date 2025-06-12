import 'dart:io';

import '../../../../media.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import '../shortcut_service.dart';
import 'moving_strategy.dart';

/// Moving strategy that keeps files in album folders with shortcuts in ALL_PHOTOS
///
/// This strategy preserves album-centric organization by keeping real files in
/// album folders and creating shortcuts in ALL_PHOTOS for unified access.
class ReverseShortcutMovingStrategy extends MovingStrategy {
  const ReverseShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._shortcutService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final ShortcutService _shortcutService;

  @override
  String get name => 'reverse-shortcut';

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
      // In reverse-shortcut mode, we need to:
      // 1. Skip processing the main file (null key) initially
      // 2. Process album files first (move/copy them to album folders)
      // 3. Create shortcuts in ALL_PHOTOS pointing to the album files

      File? albumFile;

      // First pass: process album files
      for (final entry in media.files.entries) {
        final currentAlbumKey = entry.key;
        final file = entry.value;

        // Skip the main file (null key) for now
        if (currentAlbumKey == null) {
          continue;
        }

        // Generate album target directory
        final albumTargetDirectory = _pathService.generateTargetDirectory(
          currentAlbumKey,
          media.dateTaken,
          context,
        );

        await _fileService.ensureDirectoryExists(albumTargetDirectory);

        // Move/copy the file to the album folder
        final operation = MovingOperation(
          sourceFile: file,
          targetDirectory: albumTargetDirectory,
          operationType: context.copyMode
              ? MovingOperationType.copy
              : MovingOperationType.move,
          albumKey: currentAlbumKey,
          dateTaken: media.dateTaken,
        );

        final resultFile = await _fileService.moveOrCopyFile(
          file,
          albumTargetDirectory,
          copyMode: context.copyMode,
        );

        // Set file timestamp
        if (media.dateTaken != null) {
          await _fileService.setFileTimestamp(resultFile, media.dateTaken!);
        } // Remember the first album file for shortcut creation
        albumFile ??= resultFile;

        yield MovingResult.success(
          operation: operation,
          resultFile: resultFile,
          duration: stopwatch.elapsed,
        );
      }

      // Second pass: create shortcut in ALL_PHOTOS if we have an album file
      if (albumFile != null) {
        final allPhotosDirectory = _pathService.generateTargetDirectory(
          null, // ALL_PHOTOS
          media.dateTaken,
          context,
        );

        await _fileService.ensureDirectoryExists(allPhotosDirectory);

        try {
          final shortcutOperation = MovingOperation(
            sourceFile: albumFile,
            targetDirectory: allPhotosDirectory,
            operationType: MovingOperationType.createShortcut,
            dateTaken: media.dateTaken,
          );

          final shortcutFile = await _shortcutService.createShortcut(
            allPhotosDirectory,
            albumFile,
          );

          yield MovingResult.success(
            operation: shortcutOperation,
            resultFile: shortcutFile,
            duration: stopwatch.elapsed,
          );
        } catch (e) {
          // If shortcut creation fails, fall back to copying the file
          print(
            '[Warning] Creating reverse shortcut for ${albumFile.path} in ALL_PHOTOS '
            'failed: $e - copying normal file instead',
          );

          final fallbackOperation = MovingOperation(
            sourceFile: albumFile,
            targetDirectory: allPhotosDirectory,
            operationType: MovingOperationType.copy,
            dateTaken: media.dateTaken,
          );

          final fallbackFile = await _fileService.moveOrCopyFile(
            albumFile,
            allPhotosDirectory,
            copyMode: true, // Always copy for fallback
          );

          if (media.dateTaken != null) {
            await _fileService.setFileTimestamp(fallbackFile, media.dateTaken!);
          }

          yield MovingResult.success(
            operation: fallbackOperation,
            resultFile: fallbackFile,
            duration: stopwatch.elapsed,
          );
        }
      } else {
        // No album files found, process main file if it exists
        final mainFile = media.files[null];
        if (mainFile != null) {
          final allPhotosDirectory = _pathService.generateTargetDirectory(
            null,
            media.dateTaken,
            context,
          );

          await _fileService.ensureDirectoryExists(allPhotosDirectory);

          final operation = MovingOperation(
            sourceFile: mainFile,
            targetDirectory: allPhotosDirectory,
            operationType: context.copyMode
                ? MovingOperationType.copy
                : MovingOperationType.move,
            dateTaken: media.dateTaken,
          );

          final resultFile = await _fileService.moveOrCopyFile(
            mainFile,
            allPhotosDirectory,
            copyMode: context.copyMode,
          );

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
    // Reverse-shortcut mode works on all platforms
    // Note: This mode keeps files in album folders with shortcuts in ALL_PHOTOS
  }
}
