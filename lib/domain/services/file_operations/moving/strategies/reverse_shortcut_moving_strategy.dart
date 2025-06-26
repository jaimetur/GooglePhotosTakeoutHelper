import '../../../../entities/media_entity.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import '../symlink_service.dart';
import 'media_entity_moving_strategy.dart';

/// Reverse shortcut moving strategy implementation
///
/// This strategy moves files to album folders and creates shortcuts in ALL_PHOTOS.
/// Files remain in their album context, with shortcuts providing chronological access.
class ReverseShortcutMovingStrategy extends MediaEntityMovingStrategy {
  const ReverseShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  @override
  String get name => 'Reverse Shortcut';

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
    final primaryFile = entity.primaryFile;

    // If entity has album associations, move to first album and create shortcuts elsewhere
    if (entity.albumNames.isNotEmpty) {
      // Step 1: Move file to first album folder
      final primaryAlbum = entity.albumNames.first;
      final primaryAlbumDir = _pathService.generateTargetDirectory(
        primaryAlbum,
        entity.dateTaken,
        context,
      );
      final stopwatch = Stopwatch()..start();
      try {
        final movedFile = await _fileService.moveFile(
          primaryFile,
          primaryAlbumDir,
          dateTaken: entity.dateTaken,
        );

        stopwatch.stop();
        final primaryResult = MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: primaryFile,
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          resultFile: movedFile,
          duration: stopwatch.elapsed,
        );
        results.add(primaryResult);
        yield primaryResult;

        // Step 2: Create shortcut in ALL_PHOTOS
        final allPhotosDir = _pathService.generateTargetDirectory(
          null, // null = ALL_PHOTOS
          entity.dateTaken,
          context,
        );

        final shortcutStopwatch = Stopwatch()..start();
        try {
          final shortcutFile = await _symlinkService.createSymlink(
            allPhotosDir,
            movedFile,
          );

          shortcutStopwatch.stop();
          final shortcutResult = MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.createReverseSymlink,
              mediaEntity: entity,
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
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.createReverseSymlink,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to create reverse shortcut: $e',
            duration: shortcutStopwatch.elapsed,
          );
          results.add(errorResult);
          yield errorResult;
        }

        // Step 3: Create shortcuts in other album folders
        for (int i = 1; i < entity.albumNames.length; i++) {
          final albumName = entity.albumNames.elementAt(i);
          final albumDir = _pathService.generateTargetDirectory(
            albumName,
            entity.dateTaken,
            context,
          );

          final albumShortcutStopwatch = Stopwatch()..start();
          try {
            final albumShortcutFile = await _symlinkService.createSymlink(
              albumDir,
              movedFile,
            );

            albumShortcutStopwatch.stop();
            final albumShortcutResult = MediaEntityMovingResult.success(
              operation: MediaEntityMovingOperation(
                sourceFile: movedFile,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.createSymlink,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              resultFile: albumShortcutFile,
              duration: albumShortcutStopwatch.elapsed,
            );
            results.add(albumShortcutResult);
            yield albumShortcutResult;
          } catch (e) {
            albumShortcutStopwatch.stop();
            final errorResult = MediaEntityMovingResult.failure(
              operation: MediaEntityMovingOperation(
                sourceFile: movedFile,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.createSymlink,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              errorMessage: 'Failed to create album shortcut: $e',
              duration: albumShortcutStopwatch.elapsed,
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
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          errorMessage: 'Failed to move to album folder: $e',
          duration: stopwatch.elapsed,
        );
        results.add(errorResult);
        yield errorResult;
      }
    } else {
      // No album associations, move to ALL_PHOTOS
      final allPhotosDir = _pathService.generateTargetDirectory(
        null,
        entity.dateTaken,
        context,
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
      } catch (e) {
        stopwatch.stop();
        final errorResult = MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: primaryFile,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to move to ALL_PHOTOS: $e',
          duration: stopwatch.elapsed,
        );
        results.add(errorResult);
        yield errorResult;
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for reverse shortcut mode
  }
}
