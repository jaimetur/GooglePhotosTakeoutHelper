import '../../../../entities/media_entity.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import '../shortcut_service.dart';
import 'media_entity_moving_strategy.dart';

/// Shortcut moving strategy implementation
///
/// This strategy creates shortcuts/symlinks from album folders to files in ALL_PHOTOS.
/// Files are moved to ALL_PHOTOS organized by date, and shortcuts are created in album folders.
class ShortcutMovingStrategy extends MediaEntityMovingStrategy {
  const ShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._shortcutService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final ShortcutService _shortcutService;

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
    print(
      '[DEBUG] ShortcutMovingStrategy.processMediaEntity called for ${entity.primaryFile.path}',
    );
    print('[DEBUG] Entity album names: ${entity.albumNames}');
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
      print(
        '[DEBUG] Moving primary file ${primaryFile.path} to ${allPhotosDir.path}',
      );
      final movedFile = await _fileService.moveFile(
        primaryFile,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      print('[DEBUG] Primary file moved successfully to ${movedFile.path}');
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
      print(
        '[DEBUG] About to yield primary result for ${entity.primaryFile.path}',
      );
      yield primaryResult;
      print(
        '[DEBUG] Primary result yielded, now processing album associations for ${entity.primaryFile.path}',
      );

      print(
        '[DEBUG] About to process album associations for ${entity.primaryFile.path}',
      );
      // Step 2: Create shortcuts for each album association      print('[DEBUG] Entity ${entity.primaryFile.path} has ${entity.albumNames.length} albums: ${entity.albumNames}');
      for (final albumName in entity.albumNames) {
        print(
          '[DEBUG] Processing album: $albumName for ${entity.primaryFile.path}',
        );
        final albumDir = _pathService.generateTargetDirectory(
          albumName,
          entity.dateTaken,
          context,
        );
        print('[DEBUG] Generated album directory: ${albumDir.path}');
        final shortcutStopwatch = Stopwatch()..start();
        try {
          print(
            '[DEBUG] Creating shortcut for album $albumName from ${movedFile.path} to ${albumDir.path}',
          );
          final shortcutFile = await _shortcutService.createShortcut(
            albumDir,
            movedFile,
          );

          print('[DEBUG] Shortcut created successfully: ${shortcutFile.path}');
          shortcutStopwatch.stop();
          final shortcutResult = MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createShortcut,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: shortcutFile,
            duration: shortcutStopwatch.elapsed,
          );
          results.add(shortcutResult);
          print('[DEBUG] About to yield shortcut result for album $albumName');
          yield shortcutResult;
          print('[DEBUG] Shortcut result yielded for album $albumName');
        } catch (e) {
          print('[DEBUG] Exception creating shortcut for album $albumName: $e');
          shortcutStopwatch.stop();
          final errorResult = MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: movedFile,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createShortcut,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to create shortcut: $e',
            duration: shortcutStopwatch.elapsed,
          );
          results.add(errorResult);
          print(
            '[DEBUG] About to yield shortcut error result for album $albumName',
          );
          yield errorResult;
          print('[DEBUG] Shortcut error result yielded for album $albumName');
        }
      }
      print(
        '[DEBUG] Finished processing all albums for ${entity.primaryFile.path}',
      );
    } catch (e) {
      print(
        '[DEBUG] Exception moving primary file ${entity.primaryFile.path}: $e',
      );
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
