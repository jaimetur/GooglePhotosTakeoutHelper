import 'dart:convert';
import 'dart:io';

import '../../../../media.dart';
import '../../../services/emoji_cleaner_service.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import 'moving_strategy.dart';

/// Moving strategy that creates JSON metadata for album information
///
/// This strategy puts all photos in ALL_PHOTOS and creates an albums-info.json
/// file containing the album membership information for each file.
class JsonMovingStrategy extends MovingStrategy {
  JsonMovingStrategy(this._fileService, this._pathService);
  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  /// Maps filename to list of albums it belongs to
  final Map<String, List<String>> _albumInfo = {};

  @override
  String get name => 'json';

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
      // In JSON mode, we only process the first file and treat it as main file
      final mainFile = media.files.values.first;

      // Generate target directory (always ALL_PHOTOS for JSON mode)
      final targetDirectory = _pathService.generateTargetDirectory(
        null, // Always use ALL_PHOTOS
        media.dateTaken,
        context,
      );

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

      // Record album information for JSON
      final fileName = resultFile.path.split('/').last;
      final albumNames = media.files.keys
          .where((final key) => key != null)
          .map((final key) => key!)
          .map(decodeEmojiInText) // Decode hex-encoded emoji
          .toList();

      _albumInfo[fileName] = albumNames;

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
  Future<List<MovingResult>> finalize(
    final MovingContext context,
    final List<Media> processedMedia,
  ) async {
    if (_albumInfo.isEmpty) {
      return [];
    }

    try {
      final jsonPath = _pathService.generateAlbumsInfoJsonPath(
        context.outputDirectory,
      );
      final jsonFile = File(jsonPath);

      await jsonFile.writeAsString(jsonEncode(_albumInfo));

      return [
        MovingResult.success(
          operation: MovingOperation(
            sourceFile: jsonFile, // Dummy source file for the operation
            targetDirectory: context.outputDirectory,
            operationType: MovingOperationType.copy,
          ),
          resultFile: jsonFile,
          duration: Duration.zero,
        ),
      ];
    } catch (e) {
      return [
        MovingResult.failure(
          operation: MovingOperation(
            sourceFile: File('dummy'), // Dummy source file
            targetDirectory: context.outputDirectory,
            operationType: MovingOperationType.copy,
          ),
          errorMessage: 'Failed to create albums-info.json: $e',
          duration: Duration.zero,
        ),
      ];
    }
  }

  @override
  void validateContext(final MovingContext context) {
    // JSON mode has no special requirements
  }
}
