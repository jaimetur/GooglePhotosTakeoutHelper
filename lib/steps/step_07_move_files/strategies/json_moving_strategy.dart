import 'dart:convert';
import 'dart:io';
import 'package:gpth/gpth-lib.dart';

/// JSON moving strategy implementation
///
/// This strategy creates a single ALL_PHOTOS folder with all files and generates
/// an albums-info.json file containing metadata about album associations.
///
/// NOTE (model update):
/// - MediaEntity now has `primaryFile` (single source), `secondaryFiles` (original duplicate paths),
///   and `belongToAlbums` / `albumNames` (album associations). There is no `files` map anymore.
/// - Physical duplicates (non-primary files) were already deleted or moved to `_Duplicates` in Step 3,
///   so this strategy MUST NOT try to move them again here. The helper `_moveNonPrimaryFilesToDuplicates`
///   is intentionally a no-op to keep backwards comments/APIs without side effects.
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
    // Move file to ALL_PHOTOS (or PARTNER_SHARED)
    final primaryFile = entity.primaryFile;
    final allPhotosDir = _pathService.generateTargetDirectory(
      null, // null = ALL_PHOTOS or PARTNER_SHARED
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );
    final stopwatch = Stopwatch()..start();
    try {
      final movedFile = await _fileService.moveFile(
        primaryFile,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );

      stopwatch.stop();

      // Track album associations for JSON file.
      // IMPORTANT: We only track album names (keys from belongToAlbums). Use entity.albumNames.
      final fileName = movedFile.uri.pathSegments.last;
      for (final albumName in entity.albumNames) {
        _albumInfo.putIfAbsent(albumName, () => []).add(fileName);
      }

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
        errorMessage: 'Failed to move file: $e',
        duration: stopwatch.elapsed,
      );
      yield errorResult;
    }

    // Move non-primary physical files to _Duplicates preserving source structure
    // NOTE: Step 3 already handled physical duplicates. Keep this call for API parity, but it's a no-op now.
    yield* _moveNonPrimaryFilesToDuplicates(entity, context);
  }

  @override
  Future<List<MediaEntityMovingResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async {
    // Generate albums-info.json file
    final jsonPath = _pathService.generateAlbumsInfoJsonPath(context.outputDirectory);
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

      await jsonFile.writeAsString(const JsonEncoder.withIndent('  ').convert(albumData));

      stopwatch.stop();

      // IMPORTANT: if no entities were processed, we return an empty results list to avoid
      // constructing ad-hoc MediaEntity placeholders that may not exist in the new model.
      if (processedEntities.isEmpty) {
        return const <MediaEntityMovingResult>[];
      }

      return [
        MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: jsonFile, // Placeholder for JSON generation
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            // Reuse the first processed entity to keep the operation linked to a real entity
            mediaEntity: processedEntities.first,
          ),
          resultFile: jsonFile,
          duration: stopwatch.elapsed,
        ),
      ];
    } catch (e) {
      stopwatch.stop();

      if (processedEntities.isEmpty) {
        // See note above: avoid creating synthetic MediaEntity when none exist
        return const <MediaEntityMovingResult>[];
      }

      return [
        MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: jsonFile,
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.first,
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

  // --- helper: move all non-primary physical files to _Duplicates, preserving structure ---
  // NOTE (new model / pipeline):
  // Step 3 (RemoveDuplicates) already deletes or moves secondary files to _Duplicates.
  // This helper is intentionally a no-op now to keep backward API/comments without duplicating work.
  Stream<MediaEntityMovingResult> _moveNonPrimaryFilesToDuplicates(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    // no-op by design
    return;
  }
}

