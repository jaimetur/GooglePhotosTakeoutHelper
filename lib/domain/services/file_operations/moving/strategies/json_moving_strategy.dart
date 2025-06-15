import 'dart:convert';
import 'dart:io';

import '../../../../entities/media_entity.dart';
import '../file_operation_service.dart';
import '../moving_context_model.dart';
import '../path_generator_service.dart';
import 'media_entity_moving_strategy.dart';

/// JSON moving strategy implementation
///
/// This strategy creates a single ALL_PHOTOS folder with all files and generates
/// an albums-info.json file containing metadata about album associations.
class JsonMovingStrategy extends MediaEntityMovingStrategy {
  JsonMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  // Track album information for JSON generation
  final Map<String, List<String>> _albumInfo = {};

  @override
  String get name => 'JSON';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
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

      // Track album associations for JSON file
      final fileName = movedFile.uri.pathSegments.last;
      for (final albumName in entity.albumNames) {
        _albumInfo.putIfAbsent(albumName, () => []).add(fileName);
      }

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
  Future<List<MediaEntityMovingResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async {
    // Generate albums-info.json file
    final jsonPath = _pathService.generateAlbumsInfoJsonPath(
      context.outputDirectory,
    );
    final jsonFile = File(jsonPath);

    final stopwatch = Stopwatch()..start();
    try {
      final albumData = {
        'albums': _albumInfo,
        'metadata': {
          'generated': DateTime.now().toIso8601String(),
          'total_albums': _albumInfo.length,
          'total_files': processedEntities.length,
          'strategy': 'json',
        },
      };

      await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(albumData),
      );

      stopwatch.stop();
      return [
        MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: jsonFile, // Placeholder for JSON generation
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.isNotEmpty
                ? processedEntities.first
                : MediaEntity.single(file: jsonFile), // Fallback
          ),
          resultFile: jsonFile,
          duration: stopwatch.elapsed,
        ),
      ];
    } catch (e) {
      stopwatch.stop();
      return [
        MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: jsonFile,
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.isNotEmpty
                ? processedEntities.first
                : MediaEntity.single(file: jsonFile), // Fallback
          ),
          errorMessage: 'Failed to create albums-info.json: $e',
          duration: stopwatch.elapsed,
        ),
      ];
    }
  }

  @override
  void validateContext(final MovingContext context) {
    // No special validation needed for JSON mode
  }
}
