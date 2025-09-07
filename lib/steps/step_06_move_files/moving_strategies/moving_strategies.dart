import 'dart:convert';
import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Ignore-Albums strategy:
/// - Move only CANONICAL files (primary + secondaries that are canonical) to ALL_PHOTOS (date-structured if needed).
/// - Delete all NON-CANONICAL files from source (they will not appear in Output in any form).
/// - After each operation: update fe.targetPath (for moved), fe.isShortcut=false, fe.isMoved=true on moves,
///   and fe.isDeleted=true on deletions.
/// - Uses a snapshot of primary and secondaries to avoid in-loop modifications side effects.
class IgnoreAlbumsMovingStrategy extends MediaEntityMovingStrategy {
  const IgnoreAlbumsMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Ignore Albums';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    // Snapshot of the files to respect the "immutable getters" idea
    final List<FileEntity> files = <FileEntity>[
      entity.primaryFile,
      ...entity.secondaryFiles,
    ];

    for (final fe in files) {
      if (fe.isCanonical == true) {
        final sw = Stopwatch()..start();
        final File src = fe.asFile();
        try {
          final moved = await _fileService.moveFile(
            src,
            allPhotosDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          fe.targetPath = moved.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            resultFile: moved,
            duration: sw.elapsed,
          );
        } catch (e) {
          final elapsed = sw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to move canonical file: $e',
            duration: elapsed,
          );
        }
      } else {
        // Non-canonical → delete from source
        final dsw = Stopwatch()..start();
        final File src = fe.asFile();
        try {
          // If you have a delete method on _fileService, replace with that.
          await src.delete();
          dsw.stop();

          fe.isDeleted = true;
          fe.isShortcut = false;
          fe.targetPath = null;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: Directory(MovingStrategyUtils.dirOf(src.path)),
              operationType: MediaEntityOperationType.delete,
              mediaEntity: entity,
            ),
            resultFile: src,
            duration: dsw.elapsed,
          );
        } catch (e) {
          final elapsed = dsw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: Directory(MovingStrategyUtils.dirOf(src.path)),
              operationType: MediaEntityOperationType.delete,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to delete non-canonical file: $e',
            duration: elapsed,
          );
        }
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}

/// Nothing strategy:
/// - Move **primary** to ALL_PHOTOS (date-structured if needed).
/// - Delete **all secondaries** from source (they will not appear in Output).
/// - After each operation: update fe.targetPath and flags (isShortcut=false; isMoved=true for moved; isDeleted=true for deleted).
class NothingMovingStrategy extends MediaEntityMovingStrategy {
  const NothingMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Nothing';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => false;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    // Snapshot to avoid in-loop mutations
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];

    // Move primary
    {
      final sw = Stopwatch()..start();
      final File src = primary.asFile();
      try {
        final moved = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        primary.targetPath = moved.path;
        primary.isShortcut = false;
        primary.isMoved = true;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: src,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          resultFile: moved,
          duration: sw.elapsed,
        );
      } catch (e) {
        final elapsed = sw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: src,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to move primary: $e',
          duration: elapsed,
        );
      }
    }

    // Delete all secondaries
    for (final sec in secondaries) {
      final dsw = Stopwatch()..start();
      final File src = sec.asFile();
      try {
        await src.delete();
        dsw.stop();

        sec.isDeleted = true;
        sec.isShortcut = false;
        sec.targetPath = null;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: src,
            targetDirectory: Directory(MovingStrategyUtils.dirOf(src.path)),
            operationType: MediaEntityOperationType.delete,
            mediaEntity: entity,
          ),
          resultFile: src,
          duration: dsw.elapsed,
        );
      } catch (e) {
        final elapsed = dsw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: src,
            targetDirectory: Directory(MovingStrategyUtils.dirOf(src.path)),
            operationType: MediaEntityOperationType.delete,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to delete secondary: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}

/// JSON strategy:
/// - Move **primary** to ALL_PHOTOS.
/// - For each album:
///   - If the primary was originally NON-CANONICAL and belonged to that album, add a JSON entry for it.
///   - For each NON-CANONICAL secondary that belonged to that album, add a JSON entry.
/// - After JSON recording:
///   - Delete **all secondaries** from source (CANONICAL secondaries are deleted without JSON entry).
/// - JSON fields (all relative paths use forward slashes):
///   {
///     "albums": {
///       "<albumName>": [
///         {
///           "albumName": "<album>",
///           "albumPath": "Albums/<Album>",                 // relative to output
///           "fileName": "<originalBaseName>",
///           "filePath": "Albums/<Album>/<originalBase>",   // relative to output (intended album path for original name)
///           "targetPath": "All Photos/.../<movedPrimary>"  // relative to output, final target of moved primary
///         },
///         ...
///       ]
///     },
///     "metadata": { ... }
///   }
class JsonMovingStrategy extends MediaEntityMovingStrategy {
  JsonMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  // albumName -> list of entries
  final Map<String, List<Map<String, String>>> _albumInfo = {};

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
    final Directory outDir = context.outputDirectory;
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    // Snapshot
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];

    final bool primaryWasCanonical = primary.isCanonical == true;

    // Move primary to ALL_PHOTOS
    final sw = Stopwatch()..start();
    final File src = primary.asFile();
    File movedPrimary;
    try {
      movedPrimary = await _fileService.moveFile(
        src,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      primary.targetPath = movedPrimary.path;
      primary.isShortcut = false;
      primary.isMoved = true;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: src,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: movedPrimary,
        duration: sw.elapsed,
      );
    } catch (e) {
      final elapsed = sw.elapsed;
      yield MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: src,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move primary: $e',
        duration: elapsed,
      );
      return;
    }

    final String primaryRel =
        path.relative(movedPrimary.path, from: outDir.path).replaceAll('\\', '/');

    // Build JSON entries per album
    for (final albumName in entity.albumNames) {
      final Directory albumDir = MovingStrategyUtils.albumDir(
        _pathService,
        albumName,
        entity,
        context,
      );
      final String albumRel =
          path.relative(albumDir.path, from: outDir.path).replaceAll('\\', '/');

      // Primary entry if it was originally non-canonical and belonged to this album
      if (!primaryWasCanonical &&
          MovingStrategyUtils.fileBelongsToAlbum(entity, primary, albumName)) {
        final String originalBase = path.basename(primary.sourcePath);
        final String albumPathWithFile = '$albumRel/$originalBase';
        (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
          'albumName': albumName,
          'albumPath': albumRel,
          'fileName': originalBase,
          'filePath': albumPathWithFile,
          'targetPath': primaryRel,
        });
      }

      // Secondary entries: only NON-CANONICAL that belonged to this album
      for (final sec in secondaries) {
        if (sec.isCanonical == true) continue;
        if (!MovingStrategyUtils.fileBelongsToAlbum(entity, sec, albumName)) {
          continue;
        }
        final String secBase = path.basename(sec.sourcePath);
        final String albumPathWithFile = '$albumRel/$secBase';
        (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
          'albumName': albumName,
          'albumPath': albumRel,
          'fileName': secBase,
          'filePath': albumPathWithFile,
          'targetPath': primaryRel,
        });
      }
    }

    // Delete all secondaries from source (CANONICAL: no JSON entry; NON-CANONICAL: entry already recorded above)
    for (final sec in secondaries) {
      final dsw = Stopwatch()..start();
      final File srcSec = sec.asFile();
      try {
        await srcSec.delete();
        dsw.stop();

        sec.isDeleted = true;
        sec.isShortcut = false;
        sec.targetPath = null;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: srcSec,
            targetDirectory: Directory(MovingStrategyUtils.dirOf(srcSec.path)),
            operationType: MediaEntityOperationType.delete,
            mediaEntity: entity,
          ),
          resultFile: srcSec,
          duration: dsw.elapsed,
        );
      } catch (e) {
        final elapsed = dsw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: srcSec,
            targetDirectory: Directory(MovingStrategyUtils.dirOf(srcSec.path)),
            operationType: MediaEntityOperationType.delete,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to delete secondary after JSON: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  Future<List<MediaEntityMovingResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async {
    final String jsonPath = _pathService.generateAlbumsInfoJsonPath(
      context.outputDirectory,
    );
    final File jsonFile = File(jsonPath);

    final sw = Stopwatch()..start();
    try {
      final payload = {
        'albums': _albumInfo,
        'metadata': {
          'generated': DateTime.now().toIso8601String(),
          'total_albums': _albumInfo.length,
          'total_entities': processedEntities.length,
          'strategy': 'json',
        },
      };
      await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      sw.stop();

      if (processedEntities.isEmpty) return const <MediaEntityMovingResult>[];

      return [
        MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: jsonFile,
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.first,
          ),
          resultFile: jsonFile,
          duration: sw.elapsed,
        ),
      ];
    } catch (e) {
      sw.stop();
      if (processedEntities.isEmpty) return const <MediaEntityMovingResult>[];
      return [
        MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: jsonFile,
            targetDirectory: context.outputDirectory,
            operationType: MediaEntityOperationType.createJsonReference,
            mediaEntity: processedEntities.first,
          ),
          errorMessage: 'Failed to create albums-info.json: $e',
          duration: sw.elapsed,
        ),
      ];
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}

/// Shortcut strategy:
/// - Choose the file to move to ALL_PHOTOS:
///   - If there is any CANONICAL among primary+secondaries, choose the best-ranked CANONICAL.
///   - Otherwise, use the current primary.
/// - Move the chosen file to ALL_PHOTOS.
/// - For each album:
///   - If primary (originally NON-CANONICAL) belonged to it → create shortcut named with original primary basename.
///   - For each NON-CANONICAL secondary that belonged to it → create shortcut named with its original basename.
///   - After creating a shortcut that represents a NON-CANONICAL source file, delete the original source
///     (the representation in Output is the link), and mark that FileEntity or its synthetic clone accordingly.
/// - Flags:
///   - Moved file: isMoved=true, isShortcut=false.
///   - For represented NON-CANONICAL files by a shortcut: original deleted → isDeleted=true; shortcut entries use isShortcut=true.
class ShortcutMovingStrategy extends MediaEntityMovingStrategy {
  const ShortcutMovingStrategy(
    this._fileService,
    this._pathService,
    this._symlinkService,
  );

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final SymlinkService _symlinkService;

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
    // Snapshot
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];

    // Decide which file to move to ALL_PHOTOS (prefer best canonical if exists)
    final List<FileEntity> allFiles = <FileEntity>[primary, ...secondaries];
    final List<FileEntity> canonicals =
        allFiles.where((f) => f.isCanonical == true).toList();
    final FileEntity chosen =
        canonicals.isNotEmpty ? _chooseBestRanked(canonicals) : primary;

    // Move chosen file to ALL_PHOTOS
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    final sw = Stopwatch()..start();
    final File src = chosen.asFile();
    File movedPrimary;
    try {
      movedPrimary = await _fileService.moveFile(
        src,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      chosen.targetPath = movedPrimary.path;
      chosen.isShortcut = false;
      chosen.isMoved = true;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: src,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: movedPrimary,
        duration: sw.elapsed,
      );
    } catch (e) {
      final elapsed = sw.elapsed;
      yield MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: src,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move chosen file: $e',
        duration: elapsed,
      );
      return;
    }

    // Collect synthetic shortcut secondaries after loops
    final List<FileEntity> pendingShortcutSecondaries = <FileEntity>[];

    // For each album, create shortcuts for non-canonicals that belonged to that album
    for (final albumName in entity.albumNames) {
      final Directory albumDir = MovingStrategyUtils.albumDir(
        _pathService,
        albumName,
        entity,
        context,
      );

      // Primary shortcut if originally non-canonical and belonged to this album
      if (primary.isCanonical != true &&
          MovingStrategyUtils.fileBelongsToAlbum(entity, primary, albumName)) {
        final String desiredName = path.basename(primary.sourcePath);
        final ssw = Stopwatch()..start();
        try {
          final File shortcut =
              await MovingStrategyUtils.createSymlinkWithPreferredName(
            _symlinkService,
            albumDir,
            movedPrimary,
            desiredName,
          );
          ssw.stop();

          // Represent primary's original as shortcut (synthetic or reuse same FE)
          pendingShortcutSecondaries.add(
            _buildShortcutClone(primary, shortcut.path),
          );

          // Delete the original NON-CANONICAL primary source
          try {
            await File(primary.sourcePath).delete();
            primary.isDeleted = true;
          } catch (_) {}

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedPrimary,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createSymlink,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: shortcut,
            duration: ssw.elapsed,
          );
        } catch (e) {
          final elapsed = ssw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: movedPrimary,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createSymlink,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage:
                'Failed to create album shortcut for non-canonical primary: $e',
            duration: elapsed,
          );
        }
      }

      // Shortcuts for NON-CANONICAL secondaries that belonged to this album
      for (final sec in secondaries) {
        if (sec.isCanonical == true) continue;
        if (!MovingStrategyUtils.fileBelongsToAlbum(entity, sec, albumName)) {
          continue;
        }
        final String desiredName = path.basename(sec.sourcePath);
        final ssw = Stopwatch()..start();
        try {
          final File shortcut =
              await MovingStrategyUtils.createSymlinkWithPreferredName(
            _symlinkService,
            albumDir,
            movedPrimary,
            desiredName,
          );
          ssw.stop();

          if (sec.targetPath == null) {
            sec.targetPath = shortcut.path;
            sec.isShortcut = true;
          } else {
            pendingShortcutSecondaries.add(
              _buildShortcutClone(sec, shortcut.path),
            );
          }

          // Delete the original NON-CANONICAL secondary source
          try {
            await File(sec.sourcePath).delete();
            sec.isDeleted = true;
          } catch (_) {}

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedPrimary,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createSymlink,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: shortcut,
            duration: ssw.elapsed,
          );
        } catch (e) {
          final elapsed = ssw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: movedPrimary,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.createSymlink,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to create secondary shortcut: $e',
            duration: elapsed,
          );
        }
      }
    }

    if (pendingShortcutSecondaries.isNotEmpty) {
      entity.secondaryFiles.addAll(pendingShortcutSecondaries);
    }
  }

  @override
  void validateContext(final MovingContext context) {}

  FileEntity _buildShortcutClone(
    final FileEntity src,
    final String shortcutPath,
  ) =>
      FileEntity(
        sourcePath: src.sourcePath,
        targetPath: shortcutPath,
        isShortcut: true,
        dateAccuracy: src.dateAccuracy,
        ranking: src.ranking,
      );

  FileEntity _chooseBestRanked(final List<FileEntity> files) {
    files.sort((final a, final b) {
      final ra = a.ranking;
      final rb = b.ranking;
      final cmp = ra.compareTo(rb); // lower is better
      if (cmp != 0) return cmp;

      final ba = path.basename(a.path).length;
      final bb = path.basename(b.path).length;
      if (ba != bb) return ba.compareTo(bb);

      return a.path.length.compareTo(b.path.length);
    });
    return files.first;
  }
}

/// Reverse-Shortcut strategy:
/// - Move all NON-CANONICAL files (primary and secondaries) physically into Albums/<Album>.
/// - Choose the best-ranked NON-CANONICAL (among the moved ones) as the "anchor".
/// - For each CANONICAL file (including canonical primary if any), create a shortcut in ALL_PHOTOS pointing to the anchor,
///   then delete the original canonical source (its representation in Output becomes the shortcut).
/// - If there are NO NON-CANONICAL files at all, move the canonical primary to ALL_PHOTOS (fallback).
/// - Flags are updated as: moved.isMoved=true; represented-by-shortcut.isShortcut=true and originals deleted (isDeleted=true).
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
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];
    final List<FileEntity> allFiles = <FileEntity>[primary, ...secondaries];

    final List<FileEntity> nonCanonicals =
        allFiles.where((f) => f.isCanonical != true).toList();

    if (nonCanonicals.isNotEmpty) {
      // Move every NON-CANONICAL to its album (deterministic choice per file)
      final Map<FileEntity, File> movedMap = <FileEntity, File>{};

      for (final fe in nonCanonicals) {
        final List<String> albumsForThisFile =
            MovingStrategyUtils.albumsForFile(entity, fe);
        final String primaryAlbum = albumsForThisFile.isNotEmpty
            ? albumsForThisFile.first
            : (entity.albumNames.isNotEmpty ? entity.albumNames.first : 'Unknown Album');

        final Directory albumDir = MovingStrategyUtils.albumDir(
          _pathService,
          primaryAlbum,
          entity,
          context,
        );

        final sw = Stopwatch()..start();
        final File src = fe.asFile();
        try {
          final File m = await _fileService.moveFile(
            src,
            albumDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          fe.targetPath = m.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          movedMap[fe] = m;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            resultFile: m,
            duration: sw.elapsed,
          );
        } catch (e) {
          final elapsed = sw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            errorMessage: 'Failed to move non-canonical file: $e',
            duration: elapsed,
          );
        }
      }

      // Choose anchor: best-ranked among NON-CANONICAL moved
      final FileEntity anchor = _chooseBestRanked(nonCanonicals);
      final File? anchorMoved = movedMap[anchor];
      if (anchorMoved == null) {
        // Fallback: if nothing moved, do nothing more
        return;
      }

      // For each CANONICAL (primary or secondary), create shortcut in ALL_PHOTOS pointing to anchor and delete original
      final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
        _pathService,
        entity,
        context,
      );

      for (final fe in allFiles.where((f) => f.isCanonical == true)) {
        final ssw = Stopwatch()..start();
        try {
          final File shortcut = await _symlinkService.createSymlink(
            allPhotosDir,
            anchorMoved,
          );
          ssw.stop();

          // Represent this canonical via shortcut (synthetic or reuse):
          entity.secondaryFiles.add(
            FileEntity(
              sourcePath: fe.sourcePath,
              targetPath: shortcut.path,
              isShortcut: true,
              dateAccuracy: fe.dateAccuracy,
              ranking: fe.ranking,
            ),
          );

          // Delete original canonical source
          try {
            await File(fe.sourcePath).delete();
            fe.isDeleted = true;
          } catch (_) {}

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: anchorMoved,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.createReverseSymlink,
              mediaEntity: entity,
            ),
            resultFile: shortcut,
            duration: ssw.elapsed,
          );
        } catch (e) {
          final elapsed = ssw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: anchorMoved,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.createReverseSymlink,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to create reverse shortcut: $e',
            duration: elapsed,
          );
        }
      }
    } else {
      // No NON-CANONICALS → move canonical primary to ALL_PHOTOS
      final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
        _pathService,
        entity,
        context,
      );

      final sw = Stopwatch()..start();
      final File src = primary.asFile();
      try {
        final moved = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        primary.targetPath = moved.path;
        primary.isShortcut = false;
        primary.isMoved = true;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: src,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          resultFile: moved,
          duration: sw.elapsed,
        );
      } catch (e) {
        final elapsed = sw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: src,
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to move canonical primary: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}

  FileEntity _chooseBestRanked(final List<FileEntity> files) {
    files.sort((final a, final b) {
      final ra = a.ranking;
      final rb = b.ranking;
      final cmp = ra.compareTo(rb); // lower is better
      if (cmp != 0) return cmp;

      final ba = path.basename(a.path).length;
      final bb = path.basename(b.path).length;
      if (ba != bb) return ba.compareTo(bb);

      return a.path.length.compareTo(b.path.length);
    });
    return files.first;
  }
}

/// Duplicate-Copy strategy:
/// - If there is ANY CANONICAL file in the entity:
///   - Move CANONICAL files to ALL_PHOTOS (no album copies for canonicals).
///   - Move NON-CANONICAL files to one album they belonged to; copy to other albums they belonged to.
///   - Do NOT create copies in ALL_PHOTOS for NON-CANONICAL files.
/// - If there are NO CANONICAL files in the entity:
///   - Choose the best-ranked NON-CANONICAL and create ONE duplicate copy in ALL_PHOTOS
///     as a new synthetic secondary with `isDuplicateCopy=true` and `isMoved=false`.
///   - Move originals to their primary album and copy to other albums they belonged to.
/// - Always update targetPath and flags accordingly.
class DuplicateCopyMovingStrategy extends MediaEntityMovingStrategy {
  const DuplicateCopyMovingStrategy(this._fileService, this._pathService);

  final FileOperationService _fileService;
  final PathGeneratorService _pathService;

  @override
  String get name => 'Duplicate Copy';

  @override
  bool get createsShortcuts => false;

  @override
  bool get createsDuplicates => true;

  @override
  Stream<MediaEntityMovingResult> processMediaEntity(
    final MediaEntity entity,
    final MovingContext context,
  ) async* {
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );
    final FileEntity primary = entity.primaryFile;
    final List<FileEntity> secondaries = <FileEntity>[...entity.secondaryFiles];
    final List<FileEntity> allFiles = <FileEntity>[primary, ...secondaries];

    final bool hasCanonical = allFiles.any((f) => f.isCanonical == true);

    // Helper: move a file to a target dir
    Future<(File?, Duration)> _moveWithTiming(
      final File src,
      final Directory dest,
    ) async {
      final sw = Stopwatch()..start();
      try {
        final moved = await _fileService.moveFile(
          src,
          dest,
          dateTaken: entity.dateTaken,
        );
        sw.stop();
        return (moved, sw.elapsed);
      } catch (_) {
        final elapsed = sw.elapsed;
        return (null, elapsed);
      }
    }

    // Helper: copy a file to a target dir
    Future<(File?, Duration)> _copyWithTiming(
      final File src,
      final Directory dest,
    ) async {
      final sw = Stopwatch()..start();
      try {
        final copied = await _fileService.copyFile(
          src,
          dest,
          dateTaken: entity.dateTaken,
        );
        sw.stop();
        return (copied, sw.elapsed);
      } catch (_) {
        final elapsed = sw.elapsed;
        return (null, elapsed);
      }
    }

    // Case A: There is at least one canonical in the entity
    if (hasCanonical) {
      // Move canonicals to ALL_PHOTOS
      for (final fe in allFiles.where((f) => f.isCanonical == true)) {
        final File src = fe.asFile();
        final (File? moved, Duration elapsed) = await _moveWithTiming(src, allPhotosDir);
        if (moved != null) {
          fe.targetPath = moved.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            resultFile: moved,
            duration: elapsed,
          );
        } else {
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: src,
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to move canonical file',
            duration: elapsed,
          );
        }
      }

      // For NON-CANONICALS: move to primary album and copy to the rest
      for (final fe in allFiles.where((f) => f.isCanonical != true)) {
        final List<String> albumsForThisFile =
            MovingStrategyUtils.albumsForFile(entity, fe);
        final String primaryAlbum = albumsForThisFile.isNotEmpty
            ? albumsForThisFile.first
            : (entity.albumNames.isNotEmpty ? entity.albumNames.first : 'Unknown Album');

        // Move original to primary album
        final Directory primaryAlbumDir = MovingStrategyUtils.albumDir(
          _pathService,
          primaryAlbum,
          entity,
          context,
        );
        final File srcMove = fe.asFile();
        final (File? movedToAlbum, Duration moveElapsed) =
            await _moveWithTiming(srcMove, primaryAlbumDir);
        if (movedToAlbum != null) {
          fe.targetPath = movedToAlbum.path;
          fe.isShortcut = false;
          fe.isMoved = true;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: srcMove,
              targetDirectory: primaryAlbumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            resultFile: movedToAlbum,
            duration: moveElapsed,
          );
        } else {
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: srcMove,
              targetDirectory: primaryAlbumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: primaryAlbum,
            ),
            errorMessage: 'Failed to move non-canonical file to album',
            duration: moveElapsed,
          );
          continue;
        }

        // Copy to remaining albums
        for (final albumName in albumsForThisFile.skip(1)) {
          final Directory albumDir = MovingStrategyUtils.albumDir(
            _pathService,
            albumName,
            entity,
            context,
          );
          final (File? copied, Duration copyElapsed) =
              await _copyWithTiming(movedToAlbum, albumDir);
          if (copied != null) {
            yield MediaEntityMovingResult.success(
              operation: MediaEntityMovingOperation(
                sourceFile: movedToAlbum,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.copy,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              resultFile: copied,
              duration: copyElapsed,
            );
          } else {
            yield MediaEntityMovingResult.failure(
              operation: MediaEntityMovingOperation(
                sourceFile: movedToAlbum,
                targetDirectory: albumDir,
                operationType: MediaEntityOperationType.copy,
                mediaEntity: entity,
                albumKey: albumName,
              ),
              errorMessage: 'Failed to copy non-canonical file to album',
              duration: copyElapsed,
            );
          }
        }
      }

      return;
    }

    // Case B: No canonicals → create ONE duplicate copy in ALL_PHOTOS from the best-ranked NON-CANONICAL
    final List<FileEntity> nonCanonicals =
        allFiles.where((f) => f.isCanonical != true).toList();
    if (nonCanonicals.isEmpty) return;

    final FileEntity best = _chooseBestRanked(nonCanonicals);
    final File srcBest = best.asFile();
    final (File? copiedToAll, Duration copyElapsed) =
        await _copyWithTiming(srcBest, allPhotosDir);
    if (copiedToAll != null) {
      // Synthetic secondary representing the duplicate copy in ALL_PHOTOS
      entity.secondaryFiles.add(
        FileEntity(
          sourcePath: best.sourcePath,
          targetPath: copiedToAll.path,
          isShortcut: false,
          dateAccuracy: best.dateAccuracy,
          ranking: best.ranking,
        )..isDuplicateCopy = true, // mark duplicate copy
      );

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: srcBest,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.copy,
          mediaEntity: entity,
        ),
        resultFile: copiedToAll,
        duration: copyElapsed,
      );
    } else {
      yield MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: srcBest,
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.copy,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to create duplicate copy in ALL_PHOTOS',
        duration: copyElapsed,
      );
    }

    // Move each NON-CANONICAL original to its primary album and copy to other albums
    for (final fe in nonCanonicals) {
      final List<String> albumsForThisFile =
          MovingStrategyUtils.albumsForFile(entity, fe);
      final String primaryAlbum = albumsForThisFile.isNotEmpty
          ? albumsForThisFile.first
          : (entity.albumNames.isNotEmpty ? entity.albumNames.first : 'Unknown Album');

      // Move original to primary album
      final Directory primaryAlbumDir = MovingStrategyUtils.albumDir(
        _pathService,
        primaryAlbum,
        entity,
        context,
      );
      final File srcMove = fe.asFile();
      final (File? movedToAlbum, Duration moveElapsed) =
          await _moveWithTiming(srcMove, primaryAlbumDir);
      if (movedToAlbum != null) {
        fe.targetPath = movedToAlbum.path;
        fe.isShortcut = false;
        fe.isMoved = true;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: srcMove,
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          resultFile: movedToAlbum,
          duration: moveElapsed,
        );
      } else {
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: srcMove,
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          errorMessage: 'Failed to move non-canonical file to album',
          duration: moveElapsed,
        );
        continue;
      }

      // Copy to remaining albums
      for (final albumName in albumsForThisFile.skip(1)) {
        final Directory albumDir = MovingStrategyUtils.albumDir(
          _pathService,
          albumName,
          entity,
          context,
        );
        final (File? copied, Duration copyElapsed2) =
            await _copyWithTiming(movedToAlbum, albumDir);
        if (copied != null) {
          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedToAlbum,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: copied,
            duration: copyElapsed2,
          );
        } else {
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: movedToAlbum,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to copy non-canonical file to album',
            duration: copyElapsed2,
          );
        }
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}

  FileEntity _chooseBestRanked(final List<FileEntity> files) {
    files.sort((final a, final b) {
      final ra = a.ranking;
      final rb = b.ranking;
      final cmp = ra.compareTo(rb); // lower is better
      if (cmp != 0) return cmp;

      final ba = path.basename(a.path).length;
      final bb = path.basename(b.path).length;
      if (ba != bb) return ba.compareTo(bb);

      return a.path.length.compareTo(b.path.length);
    });
    return files.first;
  }
}

/// ─────────────────────────────────────────────────────────────────────────
/// Common helpers to avoid code duplication across strategies
/// (centralized in this service module so strategies can import and reuse them)
/// ─────────────────────────────────────────────────────────────────────────
class MovingStrategyUtils {
  const MovingStrategyUtils._();

  /// Generate ALL_PHOTOS target directory (date-structured if needed).
  static Directory allPhotosDir(
    final PathGeneratorService pathService,
    final MediaEntity entity,
    final MovingContext context,
  ) =>
      pathService.generateTargetDirectory(
        null,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnerShared,
      );

  /// Generate Albums/<albumName> target directory (date-structured if needed).
  static Directory albumDir(
    final PathGeneratorService pathService,
    final String albumName,
    final MediaEntity entity,
    final MovingContext context,
  ) =>
      pathService.generateTargetDirectory(
        albumName,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnerShared,
      );

  /// Returns true if 'child' path equals or is a subpath of 'parent'.
  static bool isSubPath(final String child, final String parent) {
    final String c = child.replaceAll('\\', '/');
    final String p = parent.replaceAll('\\', '/');
    return c == p || c.startsWith('$p/');
  }

  /// Returns the directory (without trailing slash) of a path, handling both separators.
  static String dirOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? '' : normalized.substring(0, idx);
  }

  /// Infer album name for a given file source directory using albumsMap metadata.
  /// Returns null if no album matches.
  static String? inferAlbumForSourceDir(
    final MediaEntity entity,
    final String fileSourceDir,
  ) {
    for (final entry in entity.albumsMap.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (isSubPath(fileSourceDir, src)) return entry.key;
      }
    }
    return entity.albumNames.isNotEmpty ? entity.albumNames.first : null;
  }

  /// Compute the list of album names a given file (by its source directory) belonged to.
  static List<String> albumsForFile(
    final MediaEntity entity,
    final FileEntity file,
  ) {
    final fileDir = dirOf(file.sourcePath);
    final List<String> result = <String>[];
    for (final entry in entity.albumsMap.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (isSubPath(fileDir, src)) {
          result.add(entry.key);
          break;
        }
      }
    }
    return result;
  }

  /// Predicate: whether [file] belonged to the given [albumName] according to sourceDirectories.
  static bool fileBelongsToAlbum(
    final MediaEntity entity,
    final FileEntity file,
    final String albumName,
  ) {
    final info = entity.albumsMap[albumName];
    if (info == null || info.sourceDirectories.isEmpty) return false;
    final fileDir = dirOf(file.sourcePath);
    for (final src in info.sourceDirectories) {
      if (isSubPath(fileDir, src)) return true;
    }
    return false;
  }

  /// Create a symlink to [target] inside [dir] and try to rename it to [preferredBasename].
  /// On name collision, appends " (n)" before extension.
  static Future<File> createSymlinkWithPreferredName(
    final SymlinkService symlinkService,
    final Directory dir,
    final File target,
    final String preferredBasename,
  ) async {
    final File link = await symlinkService.createSymlink(dir, target);
    final String currentBase = link.uri.pathSegments.last;
    if (currentBase == preferredBasename) return link;

    final String finalBasename = _resolveUniqueBasename(dir, preferredBasename);
    final String desiredPath = '${dir.path}/$finalBasename';
    try {
      return await link.rename(desiredPath);
    } catch (_) {
      return link;
    }
  }

  static String _resolveUniqueBasename(final Directory dir, final String base) {
    final int dot = base.lastIndexOf('.');
    final String stem = dot > 0 ? base.substring(0, dot) : base;
    final String ext = dot > 0 ? base.substring(dot) : '';
    String candidate = base;
    int idx = 1;
    while (_existsAny('${dir.path}/$candidate')) {
      candidate = '$stem ($idx)$ext';
      idx++;
    }
    return candidate;
  }

  static bool _existsAny(final String fullPath) {
    try {
      return File(fullPath).existsSync() ||
          Link(fullPath).existsSync() ||
          Directory(fullPath).existsSync();
    } catch (_) {
      return false;
    }
  }
}
