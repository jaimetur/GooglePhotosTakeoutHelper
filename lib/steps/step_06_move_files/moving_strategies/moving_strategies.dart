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
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    // Move primary
    {
      final sw = Stopwatch()..start();
      final File src = entity.primaryFile.asFile(); // <-- capture pre-move
      try {
        final moved = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        // Update FileEntity (mutable setters)
        entity.primaryFile.targetPath = moved.path;
        entity.primaryFile.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: src, // <-- use the src captured above
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
            sourceFile: src, // <-- use the src captured above
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
      final File src = sec.asFile(); // <-- capture pre-move
      try {
        final moved = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        sec.targetPath = moved.path;
        sec.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: src, // <-- use the src captured above
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
            sourceFile: src, // use the src captured above
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
/// - Move all **primary** files to ALL_PHOTOS (date-structured if needed).
/// - Do NOT move secondaries.
/// - Build a JSON with entries for **primary non-canonical (original)** and **secondary non-canonical**,
///   per album they belonged to (based on belongToAlbums' sourceDirectories):
///   {
///     originalFilename,
///     primaryRelativePathInOutput,      // ALWAYS with forward slashes
///     albumRelativePathUnderAlbums      // Albums/<Album>/<originalFilename> with forward slashes
///   }
/// - No symlinks are created by this strategy.
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

    // Capture original canonicality BEFORE moving
    final bool primaryWasCanonical = entity.primaryFile.isCanonical;

    // Move primary to ALL_PHOTOS
    final sw = Stopwatch()..start();
    final File src = entity.primaryFile.asFile(); // <-- capture pre-move
    File movedPrimary;
    try {
      movedPrimary = await _fileService.moveFile(
        src,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      // Update FileEntity
      entity.primaryFile.targetPath = movedPrimary.path;
      entity.primaryFile.isShortcut = false;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: src, // <-- use the src captured above
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
          sourceFile: src, // <-- use the src captured above
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move primary: $e',
        duration: elapsed,
      );
      return;
    }

    // Build JSON entries: primary (if originally non-canonical and belonged to album) + non-canonical secondaries.
    final String primaryRel = path
        .relative(movedPrimary.path, from: outDir.path)
        .replaceAll('\\', '/');

    for (final albumName in entity.albumNames) {
      final Directory albumDir = MovingStrategyUtils.albumDir(
        _pathService,
        albumName,
        entity,
        context,
      );
      final String albumRel = path
          .relative(albumDir.path, from: outDir.path)
          .replaceAll('\\', '/');

      // Primary entry if non-canonical originally and belonged to this album
      if (!primaryWasCanonical &&
          MovingStrategyUtils.fileBelongsToAlbum(
            entity,
            entity.primaryFile,
            albumName,
          )) {
        final String originalBase = path.basename(
          entity.primaryFile.sourcePath,
        );
        final String albumPathWithFile = '$albumRel/$originalBase';
        (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
          'originalFilename': originalBase,
          'primaryRelativePathInOutput': primaryRel,
          'albumRelativePathUnderAlbums': albumPathWithFile,
        });
      }

      // Secondary entries (only non-canonical that belonged to this album)
      for (final sec in entity.secondaryFiles) {
        if (sec.isCanonical == true) continue;
        if (!MovingStrategyUtils.fileBelongsToAlbum(entity, sec, albumName)) {
          continue;
        }

        final String secBase = path.basename(sec.sourcePath);
        final String albumPathWithFile = '$albumRel/$secBase';
        (_albumInfo[albumName] ??= <Map<String, String>>[]).add({
          'originalFilename': secBase,
          'primaryRelativePathInOutput': primaryRel,
          'albumRelativePathUnderAlbums': albumPathWithFile,
        });
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
/// - Move **primary** to ALL_PHOTOS.
/// - For each album membership:
///   - If primary was originally non-canonical and belonged to that album, create one shortcut
///     (named with the original primary basename) pointing to the moved primary.
///   - For each secondary non-canonical that belonged to that album, create one shortcut
///     (named with that secondary original basename) pointing to the moved primary.
/// - Update FileEntity:
///   - primary: targetPath = moved path; isShortcut=false
///   - each secondary that is represented as an album shortcut: targetPath = shortcut path; isShortcut=true
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
    // Capture original canonicality BEFORE moving
    final bool primaryWasCanonical = entity.primaryFile.isCanonical;

    // 1) Move primary to ALL_PHOTOS (canonical physical location)
    final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
      _pathService,
      entity,
      context,
    );

    final sw = Stopwatch()..start();
    final File src = entity.primaryFile.asFile(); // <-- capture pre-move
    File movedPrimary;
    try {
      movedPrimary = await _fileService.moveFile(
        src,
        allPhotosDir,
        dateTaken: entity.dateTaken,
      );
      sw.stop();

      entity.primaryFile.targetPath = movedPrimary.path;
      entity.primaryFile.isShortcut = false;

      yield MediaEntityMovingResult.success(
        operation: MediaEntityMovingOperation(
          sourceFile: src, // <-- use the src captured above
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
          sourceFile: src, // <-- use the src captured above
          targetDirectory: allPhotosDir,
          operationType: MediaEntityOperationType.move,
          mediaEntity: entity,
        ),
        errorMessage: 'Failed to move primary file: $e',
        duration: elapsed,
      );
      return;
    }

    // We’ll collect synthetic secondaries here to avoid mutating the list while iterating.
    final List<FileEntity> pendingShortcutSecondaries = <FileEntity>[];

    // 2) For each album, create shortcuts only for non-canonical files that belonged to that album
    for (final albumName in entity.albumNames) {
      final Directory albumDir = MovingStrategyUtils.albumDir(
        _pathService,
        albumName,
        entity,
        context,
      );

      // Primary shortcut only if originally non-canonical AND it belonged to this album
      if (!primaryWasCanonical &&
          MovingStrategyUtils.fileBelongsToAlbum(
            entity,
            entity.primaryFile,
            albumName,
          )) {
        final String desiredName = path.basename(entity.primaryFile.sourcePath);
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

          // Add a synthetic secondary for this primary shortcut
          pendingShortcutSecondaries.add(
            _buildShortcutClone(entity.primaryFile, shortcut.path),
          );

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

      // Shortcuts for non-canonical secondaries that belonged to this album
      for (final sec in entity.secondaryFiles) {
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
            // First album that represents this secondary → use the existing FileEntity
            sec.targetPath = shortcut.path;
            sec.isShortcut = true;
          } else {
            // This secondary already represents another album; clone a new one for this shortcut
            pendingShortcutSecondaries.add(
              _buildShortcutClone(sec, shortcut.path),
            );
          }

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

    // Append synthetic shortcut secondaries after loops (safe)
    if (pendingShortcutSecondaries.isNotEmpty) {
      entity.secondaryFiles.addAll(pendingShortcutSecondaries);
    }
  }

  @override
  void validateContext(final MovingContext context) {}

  // Builds a brand-new FileEntity representing a shortcut on output.
  // Uses your real constructor exactly (canonicality will be auto-recomputed from targetPath).
  FileEntity _buildShortcutClone(
    final FileEntity src,
    final String shortcutPath,
  ) => FileEntity(
      sourcePath: src.sourcePath, // keep original source
      targetPath: shortcutPath, // symlink path in Albums
      isShortcut: true, // mark as shortcut
      dateAccuracy: src.dateAccuracy, // preserve metadata if relevant
      ranking: src.ranking, // keep ranking
    );
}

/// Reverse-Shortcut strategy:
/// - Move **all non-canonical** files (primary and/or secondaries) physically into Albums/<Album>.
/// - Create **one** shortcut in ALL_PHOTOS pointing to the **best-ranked non-canonical** moved file.
/// - If there are **no non-canonicals**, move the canonical primary to ALL_PHOTOS.
/// - After this operation:
///   - The chosen non-canonical becomes the primary (if different);
///   - The old primary becomes a secondary (pointer swap handled by the caller if required).
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
    final nonCanonicals = <FileEntity>[];
    if (!(entity.primaryFile.isCanonical == true)) {
      nonCanonicals.add(entity.primaryFile);
    }
    for (final s in entity.secondaryFiles) {
      if (!(s.isCanonical == true)) nonCanonicals.add(s);
    }

    if (nonCanonicals.isNotEmpty) {
      final Map<FileEntity, File> moved = <FileEntity, File>{};

      for (final fe in nonCanonicals) {
        final String feDir = path.dirname(fe.sourcePath);
        final String albumName =
            MovingStrategyUtils.inferAlbumForSourceDir(entity, feDir) ??
            (entity.albumNames.isNotEmpty
                ? entity.albumNames.first
                : 'Unknown Album');
        final Directory albumDir = MovingStrategyUtils.albumDir(
          _pathService,
          albumName,
          entity,
          context,
        );

        final sw = Stopwatch()..start();
        final File src = fe.asFile(); // <-- capture pre-move
        try {
          final File m = await _fileService.moveFile(
            src,
            albumDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          fe.targetPath = m.path; // physically placed in Albums
          fe.isShortcut = false;

          moved[fe] = m;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: src, // <-- use the src captured above
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
              sourceFile: src, // <-- use the src captured above
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

      final FileEntity best = _chooseBestRanked(nonCanonicals);
      final File? bestMoved = moved[best];

      if (bestMoved != null) {
        final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
          _pathService,
          entity,
          context,
        );

        final ssw = Stopwatch()..start();
        try {
          final File shortcut = await _symlinkService.createSymlink(
            allPhotosDir,
            bestMoved,
          );
          ssw.stop();

          // ❗ En lugar de modificar el primary para que apunte al symlink,
          //    añadimos un secondary sintético que representa el atajo creado en ALL_PHOTOS.
          entity.secondaryFiles.add(
            FileEntity(
              sourcePath:
                  best.sourcePath, // conserva el origen original del "best"
              targetPath: shortcut.path, // ruta real del symlink creado
              isShortcut: true, // marcar como atajo
              dateAccuracy: best.dateAccuracy,
              ranking: best.ranking,
            ),
          );

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
      final Directory allPhotosDir = MovingStrategyUtils.allPhotosDir(
        _pathService,
        entity,
        context,
      );

      final sw = Stopwatch()..start();
      final File src = entity.primaryFile.asFile(); // <-- capture pre-move
      try {
        final moved = await _fileService.moveFile(
          src,
          allPhotosDir,
          dateTaken: entity.dateTaken,
        );
        sw.stop();

        entity.primaryFile.targetPath = moved.path;
        entity.primaryFile.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: src, // <-- use the src captured above
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
            sourceFile: src, // <-- use the src captured above
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
/// - For each file (primary + secondaries):
///   - If **canonical**:
///       - Move it to ALL_PHOTOS (date-structured if needed). **No album copies**.
///   - If **non-canonical**:
///       - Ensure there is a copy in ALL_PHOTOS **with the same basename**.
///         Copy only if there is NOT already a file in ALL_PHOTOS with the **same basename AND same size**.
///         If there is a name collision with different size, copy using a unique basename.
///       - Move the original file to one album it belonged to (deterministic choice).
///       - If it belonged to more albums, copy into those other album folders as well.
/// - Always update `targetPath` (to the final physical location of that file) and `isShortcut = false`.
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
    final List<FileEntity> files = <FileEntity>[
      entity.primaryFile,
      ...entity.secondaryFiles,
    ];

    // Local helper: create a unique-named copy in [destDir] preserving extension if collision occurs.
    Future<File> copyWithCollisionResolution(
      final File src,
      final Directory destDir,
    ) async {
      final File copied = await _fileService.copyFile(
        src,
        destDir,
        dateTaken: entity.dateTaken,
      );
      return copied; // FileOperationService is expected to avoid overwrites; keep returned path.
    }

    for (final fe in files) {
      if (fe.isCanonical == true) {
        // CANONICAL: move to ALL_PHOTOS only.
        final sw = Stopwatch()..start();
        final File src = fe.asFile(); // <-- capture pre-move
        try {
          final File moved = await _fileService.moveFile(
            src,
            allPhotosDir,
            dateTaken: entity.dateTaken,
          );
          sw.stop();

          fe.targetPath = moved.path;
          fe.isShortcut = false;

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: src, // <-- use the src captured above
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
              sourceFile: src, // <-- use the src captured above
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.move,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to move canonical file: $e',
            duration: elapsed,
          );
        }
        continue;
      }

      // NON-CANONICAL
      // 1) Ensure a copy exists in ALL_PHOTOS with same basename when needed.
      bool mustCopyToAllPhotos = true;
      final String baseName = path.basename(fe.sourcePath);
      final File candidate = File('${allPhotosDir.path}/$baseName');
      try {
        if (candidate.existsSync()) {
          final int existingSize = candidate.lengthSync();
          final int srcSize = fe.asFile().lengthSync();
          if (existingSize == srcSize) {
            mustCopyToAllPhotos =
                false; // same name and same size already present → skip copy
          }
        }
      } catch (_) {
        mustCopyToAllPhotos = true;
      }

      if (mustCopyToAllPhotos) {
        final csw = Stopwatch()..start();
        try {
          final File copied = await copyWithCollisionResolution(
            fe.asFile(),
            allPhotosDir,
          );
          csw.stop();

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: fe.asFile(),
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
            ),
            resultFile: copied,
            duration: csw.elapsed,
          );
        } catch (e) {
          final elapsed = csw.elapsed;
          yield MediaEntityMovingResult.failure(
            operation: MediaEntityMovingOperation(
              sourceFile: fe.asFile(),
              targetDirectory: allPhotosDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
            ),
            errorMessage: 'Failed to copy non-canonical file to ALL_PHOTOS: $e',
            duration: elapsed,
          );
        }
      }

      // 2) Determine album memberships for this file
      final List<String> albumsForThisFile = MovingStrategyUtils.albumsForFile(
        entity,
        fe,
      );
      final String primaryAlbum = albumsForThisFile.isNotEmpty
          ? albumsForThisFile.first
          : (entity.albumNames.isNotEmpty
                ? entity.albumNames.first
                : 'Unknown Album');

      // 3) Move original to the primary album
      final Directory primaryAlbumDir = MovingStrategyUtils.albumDir(
        _pathService,
        primaryAlbum,
        entity,
        context,
      );
      final msw = Stopwatch()..start();
      final File srcMove = fe.asFile(); // <-- capture pre-move
      File movedToAlbum;
      try {
        movedToAlbum = await _fileService.moveFile(
          srcMove,
          primaryAlbumDir,
          dateTaken: entity.dateTaken,
        );
        msw.stop();

        fe.targetPath = movedToAlbum.path;
        fe.isShortcut = false;

        yield MediaEntityMovingResult.success(
          operation: MediaEntityMovingOperation(
            sourceFile: srcMove, // <-- use the src captured above
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          resultFile: movedToAlbum,
          duration: msw.elapsed,
        );
      } catch (e) {
        final elapsed = msw.elapsed;
        yield MediaEntityMovingResult.failure(
          operation: MediaEntityMovingOperation(
            sourceFile: srcMove, // <-- use the src captured above
            targetDirectory: primaryAlbumDir,
            operationType: MediaEntityOperationType.move,
            mediaEntity: entity,
            albumKey: primaryAlbum,
          ),
          errorMessage: 'Failed to move non-canonical file to album: $e',
          duration: elapsed,
        );
        continue;
      }

      // 4) Copy into any remaining albums it belonged to (exact one per album)
      for (final albumName in albumsForThisFile.skip(1)) {
        final Directory albumDir = MovingStrategyUtils.albumDir(
          _pathService,
          albumName,
          entity,
          context,
        );
        final csw = Stopwatch()..start();
        try {
          final File copied = await _fileService.copyFile(
            movedToAlbum,
            albumDir,
            dateTaken: entity.dateTaken,
          );
          csw.stop();

          yield MediaEntityMovingResult.success(
            operation: MediaEntityMovingOperation(
              sourceFile: movedToAlbum,
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
              sourceFile: movedToAlbum,
              targetDirectory: albumDir,
              operationType: MediaEntityOperationType.copy,
              mediaEntity: entity,
              albumKey: albumName,
            ),
            errorMessage: 'Failed to copy non-canonical file to album: $e',
            duration: elapsed,
          );
        }
      }
    }
  }

  @override
  void validateContext(final MovingContext context) {}
}
