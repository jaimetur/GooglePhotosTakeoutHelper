import 'dart:io';
import 'package:gpth/gpth-lib.dart';

/// Base class for MediaEntity moving strategies (unchanged public API)
abstract class MediaEntityMovingStrategy {
  const MediaEntityMovingStrategy();

  String get name;
  bool get createsShortcuts;
  bool get createsDuplicates;

  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  );

  Future<List<MediaEntityMovingResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async =>
      [];

  void validateContext(final MovingContext context) {}
}

/// Represents a single file moving operation
class MediaEntityMovingOperation {
  const MediaEntityMovingOperation({
    required this.sourceFile,
    required this.targetDirectory,
    required this.operationType,
    required this.mediaEntity,
    this.albumKey,
  });

  final File sourceFile;
  final Directory targetDirectory;
  final MediaEntityOperationType operationType;
  final MediaEntity mediaEntity;
  final String? albumKey;

  File get targetFile =>
      File('${targetDirectory.path}/${sourceFile.uri.pathSegments.last}');

  bool get isAlbumFile => albumKey != null;
  bool get isMainFile => albumKey == null;
}

enum MediaEntityOperationType {
  move,
  copy,
  createSymlink,
  createReverseSymlink,
  createJsonReference,
}

/// Operation result
class MediaEntityMovingResult {
  const MediaEntityMovingResult({
    required this.operation,
    required this.success,
    required this.duration,
    this.resultFile,
    this.errorMessage,
  });

  factory MediaEntityMovingResult.success({
    required final MediaEntityMovingOperation operation,
    required final File resultFile,
    required final Duration duration,
  }) =>
      MediaEntityMovingResult(
        operation: operation,
        success: true,
        resultFile: resultFile,
        duration: duration,
      );

  factory MediaEntityMovingResult.failure({
    required final MediaEntityMovingOperation operation,
    required final String errorMessage,
    required final Duration duration,
  }) =>
      MediaEntityMovingResult(
        operation: operation,
        success: false,
        errorMessage: errorMessage,
        duration: duration,
      );

  final MediaEntityMovingOperation operation;
  final bool success;
  final File? resultFile;
  final Duration duration;
  final String? errorMessage;

  bool get isSuccess => success;
  bool get isFailure => !success;
}

/// Factory to create strategy by AlbumBehavior
class MediaEntityMovingStrategyFactory {
  const MediaEntityMovingStrategyFactory(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

  MediaEntityMovingStrategy createStrategy(final AlbumBehavior albumBehavior) {
    switch (albumBehavior) {
      case AlbumBehavior.shortcut:
        return ShortcutMovingStrategy(_fileService, _pathService, _symlinkService);
      case AlbumBehavior.duplicateCopy:
        return DuplicateCopyMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.reverseShortcut:
        return ReverseShortcutMovingStrategy(_fileService, _pathService, _symlinkService);
      case AlbumBehavior.json:
        return JsonMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.nothing:
        return NothingMovingStrategy(_fileService, _pathService);
    }
  }
}
