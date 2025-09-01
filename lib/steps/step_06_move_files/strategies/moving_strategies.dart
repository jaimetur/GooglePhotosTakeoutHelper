import 'dart:convert';
import 'dart:io';
import 'package:gpth/gpth-lib.dart';
import 'package:path/path.dart' as path;


/// Nothing strategy:
/// - Move **primary** and **all secondaries** to ALL_PHOTOS (date-structured if needed).
/// - No Albums and no shortcuts.
/// - After each operation: update fe.targetPath and fe.isShortcut = false.
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
    final Directory allPhotosDir = _pathService.generateTargetDirectory(
      null,
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );

    // Move primary
    {
      final sw = Stopwatch()..start();
      try {
        final moved = await _fileService.moveFile(
          entity.primaryFile.asFile(),
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        // Update FileEntity (mutable setters)
        entity.primaryFile.targetPath = moved.path;
        entity.primaryFile.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: entity.primaryFile.asFile(),
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
            sourceFile: entity.primaryFile.asFile(),
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to move primary: $e',
          duration: elapsed,
        );
      }
    }

    // Move all secondaries
    for (final sec in entity.secondaryFiles) {
      final sw = Stopwatch()..start();
      try {
        final moved = await _fileService.moveFile(
          sec.asFile(),
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        sec.targetPath = moved.path;
        sec.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: sec.asFile(),
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
            sourceFile: sec.asFile(),
            targetDirectory: allPhotosDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
          ),
          errorMessage: 'Failed to move secondary: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}


/// JSON strategy:
/// - Move all **primary** files to ALL_PHOTOS.
/// - Do NOT move secondaries.
/// - Build a JSON including (for each album item):
///   { originalFilename, primaryRelativePathInOutput, albumRelativePathUnderAlbums }
///   for **primary** and **secondary non-canonical**.
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
    final Directory allPhotosDir = _pathService.generateTargetDirectory(
      null,
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );

    // Move primary to ALL_PHOTOS
    final sw = Stopwatch()..start();
    File movedPrimary;
    try {
      movedPrimary = await _fileService.moveFile(
        entity.primaryFile.asFile(),
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      // Update FileEntity
      entity.primaryFile.targetPath = movedPrimary.path;
      entity.primaryFile.isShortcut = false;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: entity.primaryFile.asFile(),
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
          sourceFile: entity.primaryFile.asFile(),
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move primary: $e',
        duration: elapsed,
      );
      return;
    }

    // Build JSON entries for albums: primary + secondary non-canonical
    final primaryRel = path.relative(movedPrimary.path, from: outDir.path);

    for (final albumName in entity.albumNames) {
      final albumDir = _pathService.generateTargetDirectory(
        albumName,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnershared,
      );
      final albumRel = path.relative(albumDir.path, from: outDir.path);

      // Primary entry
      (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
        'originalFilename': path.basename(entity.primaryFile.sourcePath),
        'primaryRelativePathInOutput': primaryRel,
        'albumRelativePathUnderAlbums': albumRel,
      });

      // Secondary entries (only non-canonical)
      for (final sec in entity.secondaryFiles) {
        if (sec.isCanonical == true) continue;
        (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
          'originalFilename': path.basename(sec.sourcePath),
          'primaryRelativePathInOutput': primaryRel,
          'albumRelativePathUnderAlbums': albumRel,
        });
      }
    }
  }

  @override
  Future<List<MediaEntityMovingResult>> finalize(
    final MovingContext context,
    final List<MediaEntity> processedEntities,
  ) async {
    final String jsonPath =
        _pathService.generateAlbumsInfoJsonPath(context.outputDirectory);
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
/// - Move **primary** to ALL_PHOTOS.
/// - For each album membership, create shortcuts in Albums pointing to the moved primary.
/// - For each **secondary non-canonical**, also create album shortcuts pointing to the moved primary.
/// - Update FileEntity:
///   - primary: targetPath = moved path; isShortcut=false
///   - each secondary that we represent as an album shortcut: targetPath = shortcut path; isShortcut=true
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
    // 1) Move primary to ALL_PHOTOS
    final Directory allPhotosDir = _pathService.generateTargetDirectory(
      null,
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );

    final sw = Stopwatch()..start();
    File movedPrimary;
    try {
      movedPrimary = await _fileService.moveFile(
        entity.primaryFile.asFile(),
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      entity.primaryFile.targetPath = movedPrimary.path;
      entity.primaryFile.isShortcut = false;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: entity.primaryFile.asFile(),
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
          sourceFile: entity.primaryFile.asFile(),
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move primary file: $e',
        duration: elapsed,
      );
      return;
    }

    // 2) Create album shortcuts for primary + secondary non-canonical (all point to movedPrimary)
    for (final albumName in entity.albumNames) {
      final Directory albumDir = _pathService.generateTargetDirectory(
        albumName,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnershared,
      );

      // Shortcut for album view (primary)
      {
        final ssw = Stopwatch()..start();
        try {
          final File shortcut = await _symlinkService.createSymlink(
            albumDir,
            movedPrimary,
          );
          ssw.stop();

          // We don't have a dedicated FileEntity for a "primary-in-album" view.
          // The model only tracks primary+secondaries; we keep primary pointing to moved file.
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
            errorMessage: 'Failed to create album shortcut: $e',
            duration: elapsed,
          );
        }
      }

      // Shortcuts for non-canonical secondaries that belong to this album
      for (final sec in entity.secondaryFiles) {
        if (sec.isCanonical == true) continue;
        if (!_secondaryBelongsToAlbum(entity, sec, albumName)) continue;

        final ssw = Stopwatch()..start();
        try {
          final File shortcut = await _symlinkService.createSymlink(
            albumDir,
            movedPrimary,
          );
          ssw.stop();

          sec.targetPath = shortcut.path;
          sec.isShortcut = true;

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
  }

  @override
  void validateContext(final MovingContext context) {}

  bool _secondaryBelongsToAlbum(
    final MediaEntity e,
    final FileEntity sec,
    final String albumName,
  ) {
    final info = e.belongToAlbums[albumName];
    if (info == null || info.sourceDirectories.isEmpty) return false;
    final secDir = path.dirname(sec.sourcePath);
    for (final src in info.sourceDirectories) {
      if (_isSubPath(secDir, src)) return true;
    }
    return false;
  }

  bool _isSubPath(final String child, final String parent) {
    final c = path.normalize(child).replaceAll('\\', '/');
    final pth = path.normalize(parent).replaceAll('\\', '/');
    return c == pth || c.startsWith('$pth/');
  }
}



/// Reverse-Shortcut strategy:
/// - Move **all non-canonical** files (primary and/or secondaries) physically into Albums/<Album>.
/// - Create **one** shortcut in ALL_PHOTOS pointing to the **best-ranked non-canonical** moved file.
/// - If there are **no non-canonicals**, move the canonical primary to ALL_PHOTOS.
/// - After this operation:
///   - The chosen non-canonical becomes the primary (if different);
///   - The old primary becomes a secondary (its FileEntity can represent the reverse shortcut in ALL_PHOTOS).
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
    // Gather non-canonical files
    final nonCanonicals = <FileEntity>[];
    if (!(entity.primaryFile.isCanonical == true)) nonCanonicals.add(entity.primaryFile);
    for (final s in entity.secondaryFiles) {
      if (!(s.isCanonical == true)) nonCanonicals.add(s);
    }

    if (nonCanonicals.isNotEmpty) {
      // 1) Move all non-canonical files to their album folder
      final Map<FileEntity, File> moved = <FileEntity, File>{};

      for (final fe in nonCanonicals) {
        final String albumName =
            _inferAlbumForFile(entity, fe) ?? (entity.albumNames.isNotEmpty ? entity.albumNames.first : 'Unknown Album');
        final Directory albumDir = _pathService.generateTargetDirectory(
          albumName,
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnershared,
        );

        final sw = Stopwatch()..start();
        try {
          final File m = await _fileService.moveFile(
            fe.asFile(),
            albumDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          fe.targetPath = m.path;     // physically placed in Albums
          fe.isShortcut = false;

          moved[fe] = m;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: fe.asFile(),
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            resultFile: m,
            duration: sw.elapsed,
          );
        } catch (e) {
          final elapsed = sw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: fe.asFile(),
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to move non-canonical file: $e',
            duration: elapsed,
          );
        }
      }

      // 2) Choose best-ranked non-canonical to point ALL_PHOTOS reverse shortcut
      final FileEntity best = _chooseBestRanked(nonCanonicals);
      final File? bestMoved = moved[best];

      if (bestMoved != null) {
        final Directory allPhotosDir = _pathService.generateTargetDirectory(
          null,
          entity.dateTaken,
          context,
          isPartnerShared: entity.partnershared,
        );

        final ssw = Stopwatch()..start();
        try {
          final File shortcut = await _symlinkService.createSymlink(
            allPhotosDir,
            bestMoved,
          );
          ssw.stop();

          // The old canonical primary (if different) can represent the shortcut in ALL_PHOTOS.
          // Mark the current primary as the shortcut holder when it's not the chosen best.
          if (!identical(entity.primaryFile, best)) {
            entity.primaryFile.targetPath = shortcut.path;
            entity.primaryFile.isShortcut = true;
          }

          // Make the chosen "best" the conceptual primary (model-wise we keep same objects;
          // primary pointer change happens at collection level outside strategies if needed).
          // Since FileEntity is mutable and already updated with targetPath, we are done here.

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: bestMoved,
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
              sourceFile: bestMoved,
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
      // No non-canonicals → move canonical primary to ALL_PHOTOS
      final Directory allPhotosDir = _pathService.generateTargetDirectory(
        null,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnershared,
      );

      final sw = Stopwatch()..start();
      try {
        final moved = await _fileService.moveFile(
          entity.primaryFile.asFile(),
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        entity.primaryFile.targetPath = moved.path;
        entity.primaryFile.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: entity.primaryFile.asFile(),
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
            sourceFile: entity.primaryFile.asFile(),
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
    files.sort((a, b) {
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

  String? _inferAlbumForFile(final MediaEntity e, final FileEntity fe) {
    final feDir = path.dirname(fe.sourcePath);
    for (final entry in e.belongToAlbums.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (_isSubPath(feDir, src)) return entry.key;
      }
    }
    return e.albumNames.isNotEmpty ? e.albumNames.first : null;
  }

  bool _isSubPath(final String child, final String parent) {
    final c = path.normalize(child).replaceAll('\\', '/');
    final pth = path.normalize(parent).replaceAll('\\', '/');
    return c == pth || c.startsWith('$pth/');
  }
}


/// Duplicate-Copy strategy:
/// - Move canonical primary to ALL_PHOTOS.
/// - Copy the canonical into each album folder.
/// - Copy each **secondary non-canonical** into its album folder.
/// - Update FileEntity for all created/moved items (targetPath, isShortcut=false).
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
    final Directory allPhotosDir = _pathService.generateTargetDirectory(
      null,
      entity.dateTaken,
      context,
      isPartnerShared: entity.partnershared,
    );

    // 1) Move primary to ALL_PHOTOS
    final sw = Stopwatch()..start();
    File canonical;
    try {
      canonical = await _fileService.moveFile(
        entity.primaryFile.asFile(),
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      entity.primaryFile.targetPath = canonical.path;
      entity.primaryFile.isShortcut = false;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: entity.primaryFile.asFile(),
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        resultFile: canonical,
        duration: sw.elapsed,
      );
    } catch (e) {
      final elapsed = sw.elapsed;
      yield MediaEntityMovingResult.failure(
        operation: MediaEntityMovingOperation(
          sourceFile: entity.primaryFile.asFile(),
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to establish canonical file: $e',
        duration: elapsed,
      );
      return;
    }

    // 2) Copy canonical to each album folder
    for (final albumName in entity.albumNames) {
      final Directory albumDir = _pathService.generateTargetDirectory(
        albumName,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnershared,
      );

      final csw = Stopwatch()..start();
      try {
        final File copied = await _fileService.copyFile(
          canonical,
          albumDir,
          dateTaken: entity.dateTaken,
        );
        csw.stop();

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: canonical,
            targetDirectory: albumDir,
            operationType: MediaEntityOperationType.copy,
            mediaEntity: entity,
            albumKey: albumName,
          ),
          resultFile: copied,
          duration: csw.elapsed,
        );
      } catch (e) {
        final elapsed = csw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: canonical,
            targetDirectory: albumDir,
            operationType: MediaEntityOperationType.copy,
            mediaEntity: entity,
            albumKey: albumName,
          ),
          errorMessage: 'Failed to copy to album: $e',
          duration: elapsed,
        );
      }
    }

    // 3) Copy each secondary non-canonical into its album folder
    for (final sec in entity.secondaryFiles) {
      if (sec.isCanonical == true) continue;

      final String albumName =
          _inferAlbumForSecondary(entity, sec) ?? (entity.albumNames.isNotEmpty ? entity.albumNames.first : 'Unknown Album');
      final Directory albumDir = _pathService.generateTargetDirectory(
        albumName,
        entity.dateTaken,
        context,
        isPartnerShared: entity.partnershared,
      );

      final ssw = Stopwatch()..start();
      try {
        final File copied = await _fileService.copyFile(
          sec.asFile(),
          albumDir,
          dateTaken: entity.dateTaken,
        );
        ssw.stop();

        sec.targetPath = copied.path;
        sec.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: sec.asFile(),
            targetDirectory: albumDir,
            operationType: MediaEntityOperationType.copy,
            mediaEntity: entity,
            albumKey: albumName,
          ),
          resultFile: copied,
          duration: ssw.elapsed,
        );
      } catch (e) {
        final elapsed = ssw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: sec.asFile(),
            targetDirectory: albumDir,
            operationType: MediaEntityOperationType.copy,
            mediaEntity: entity,
            albumKey: albumName,
          ),
          errorMessage: 'Failed to copy secondary to album: $e',
          duration: elapsed,
        );
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}

  String? _inferAlbumForSecondary(final MediaEntity e, final FileEntity sec) {
    final secDir = path.dirname(sec.sourcePath);
    for (final entry in e.belongToAlbums.entries) {
      for (final src in entry.value.sourceDirectories) {
        if (_isSubPath(secDir, src)) return entry.key;
      }
    }
    return e.albumNames.isNotEmpty ? e.albumNames.first : null;
  }

  bool _isSubPath(final String child, final String parent) {
    final c = path.normalize(child).replaceAll('\\', '/');
    final pth = path.normalize(parent).replaceAll('\\', '/');
    return c == pth || c.startsWith('$pth/');
  }
}
