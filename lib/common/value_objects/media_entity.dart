import 'dart:io';
import 'package:gpth/gpth-lib.dart';

/// Immutable domain entity representing a media file (photo or video).
///
/// This is the core domain model for media files, designed to be immutable
/// and thread-safe. All “modifications” return new instances instead of
/// mutating existing state.
///
/// UPDATED MODEL:
/// - Replaces the previous `MediaFilesCollection files` with:
///   - `primaryFile`: canonical file path (chosen by accuracy/name-length and
///     year-folder preference on ties)
///   - `secondaryFiles`: original paths of redundant duplicates (kept only as
///     metadata after Step 3)
///   - `belongToAlbums`: album membership metadata
class MediaEntity {
  /// Creates a new media entity.
  const MediaEntity({
    required this.primaryFile,
    List<File>? secondaryFiles,
    this.dateTaken,
    this.dateAccuracy,
    this.dateTimeExtractionMethod,
    this.partnershared = false,
    Map<String, AlbumInfo>? belongToAlbums,
  })  : secondaryFiles = secondaryFiles ?? const <File>[],
        belongToAlbums = belongToAlbums ?? const {};

  /// Convenience factory for a single-file entity.
  factory MediaEntity.single({
    required final File file,
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
    final bool partnershared = false,
    Map<String, AlbumInfo>? belongToAlbums,
  }) =>
      MediaEntity(
        primaryFile: file,
        secondaryFiles: const <File>[],
        dateTaken: dateTaken,
        dateAccuracy: dateAccuracy,
        dateTimeExtractionMethod: dateTimeExtractionMethod,
        partnershared: partnershared,
        belongToAlbums: belongToAlbums,
      );

  /// Album metadata: album name → AlbumInfo.
  /// This is used to reconstruct album relationships later in the pipeline.
  final Map<String, AlbumInfo> belongToAlbums;

  /// Capture/creation datetime (best-known).
  final DateTime? dateTaken;

  /// Date extraction accuracy.
  final DateAccuracy? dateAccuracy;

  /// How the date/time information was extracted.
  final DateTimeExtractionMethod? dateTimeExtractionMethod;

  /// Whether this media was shared by a partner (Google Photos partner sharing).
  final bool partnershared;

  /// Canonical (primary) file for this media entity.
  final File primaryFile;

  /// Original physical paths of all secondary duplicates (metadata only after Step 3).
  final List<File> secondaryFiles;

  /// Backward-compat convenience getter (integer accuracy).
  int? get dateTakenAccuracy => dateAccuracy?.value;

  /// Whether this media is associated with any album.
  bool get hasAlbumAssociations => belongToAlbums.isNotEmpty;

  /// All album names where this media belongs to.
  Set<String> get albumNames => belongToAlbums.keys.toSet();

  /// Returns true if any path (primary or secondary) lives inside a “year-based” folder.
  ///
  /// Heuristics:
  /// - Pure year directory: `2020`, `2015`, ...
  /// - Localized folder names: `Photos from 2019`, `Fotos de 2019` (case-insensitive)
  bool get hasYearBasedFiles {
    if (_pathIsInYearFolder(primaryFile.path)) return true;
    for (final f in secondaryFiles) {
      if (_pathIsInYearFolder(f.path)) return true;
    }
    return false;
  }

  /// Returns a copy with updated date/accuracy/method.
  MediaEntity withDate({
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) =>
      MediaEntity(
        primaryFile: primaryFile,
        secondaryFiles: secondaryFiles,
        dateTaken: dateTaken ?? this.dateTaken,
        dateAccuracy: dateAccuracy ?? this.dateAccuracy,
        dateTimeExtractionMethod:
            dateTimeExtractionMethod ?? this.dateTimeExtractionMethod,
        partnershared: partnershared,
        belongToAlbums: belongToAlbums,
      );

  /// Returns a copy with album membership updated/added (metadata only).
  MediaEntity withAlbumInfo(final String albumName, {final String? sourceDir}) {
    if (albumName.isEmpty) return this;
    final existing = belongToAlbums[albumName];
    final updated = (existing == null)
        ? AlbumInfo(
            name: albumName,
            sourceDirectories:
                sourceDir != null && sourceDir.isNotEmpty ? {sourceDir} : const {},
          )
        : (sourceDir != null && sourceDir.isNotEmpty
            ? existing.addSourceDir(sourceDir)
            : existing);

    final next = Map<String, AlbumInfo>.from(belongToAlbums)
      ..[albumName] = updated;

    return MediaEntity(
      primaryFile: primaryFile,
      secondaryFiles: secondaryFiles,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnershared: partnershared,
      belongToAlbums: next,
    );
  }

  /// Returns a copy adding a secondary file (skips if already present).
  MediaEntity withSecondaryFile(final File file) {
    if (file.path == primaryFile.path ||
        secondaryFiles.any((f) => f.path == file.path)) {
      return this;
    }
    final next = List<File>.from(secondaryFiles)..add(file);
    return MediaEntity(
      primaryFile: primaryFile,
      secondaryFiles: next,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnershared: partnershared,
      belongToAlbums: belongToAlbums,
    );
  }

  /// Returns a copy promoting `newPrimary` to primary in an immutable way.
  ///
  /// - The previous `primaryFile` becomes a secondary.
  /// - If `newPrimary` already existed in `secondaryFiles`, it is removed from there.
  MediaEntity withPrimaryFile(final File newPrimary) {
    if (newPrimary.path == primaryFile.path) return this;

    final nextSecondaries = <File>[];

    // Old primary becomes secondary if it differs from the new primary.
    if (primaryFile.path != newPrimary.path) {
      nextSecondaries.add(primaryFile);
    }

    // Keep current secondaries except the one promoted to primary.
    for (final f in secondaryFiles) {
      if (f.path != newPrimary.path) nextSecondaries.add(f);
    }

    return MediaEntity(
      primaryFile: newPrimary,
      secondaryFiles: nextSecondaries,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnershared: partnershared,
      belongToAlbums: belongToAlbums,
    );
  }

  /// Merges this entity with another:
  /// - Merges album metadata (deep merge).
  /// - Selects the best date/accuracy/method.
  /// - Accumulates secondary files (deduplicated by path).
  ///
  /// The `primaryFile` of *this* instance is preserved by design; callers should
  /// choose which entity keeps the primary before merging.
  MediaEntity mergeWith(final MediaEntity other) {
    // 1) Merge album metadata
    final Map<String, AlbumInfo> mergedAlbums = <String, AlbumInfo>{};
    for (final e in belongToAlbums.entries) {
      mergedAlbums[e.key] = e.value;
    }
    for (final e in other.belongToAlbums.entries) {
      final existing = mergedAlbums[e.key];
      mergedAlbums[e.key] = existing == null ? e.value : existing.merge(e.value);
    }

    // 2) Pick the best date/accuracy/method
    final DateTime? bestDate;
    final DateAccuracy? bestAccuracy;
    final DateTimeExtractionMethod? bestMethod;

    if (dateAccuracy == null && other.dateAccuracy == null) {
      bestDate = dateTaken ?? other.dateTaken;
      bestAccuracy = null;
      bestMethod = dateTimeExtractionMethod ?? other.dateTimeExtractionMethod;
    } else if (dateAccuracy == null) {
      bestDate = other.dateTaken;
      bestAccuracy = other.dateAccuracy;
      bestMethod = other.dateTimeExtractionMethod;
    } else if (other.dateAccuracy == null) {
      bestDate = dateTaken;
      bestAccuracy = dateAccuracy;
      bestMethod = dateTimeExtractionMethod;
    } else {
      if (dateAccuracy!.isBetterThan(other.dateAccuracy!)) {
        bestDate = dateTaken;
        bestAccuracy = dateAccuracy;
        bestMethod = dateTimeExtractionMethod;
      } else {
        bestDate = other.dateTaken;
        bestAccuracy = other.dateAccuracy;
        bestMethod = other.dateTimeExtractionMethod;
      }
    }

    // 3) Merge secondaries (add other's primary + secondaries, dedup by path)
    final List<File> mergedSecondary = <File>[];
    mergedSecondary.addAll(secondaryFiles);

    if (other.primaryFile.path != primaryFile.path &&
        !mergedSecondary.any((f) => f.path == other.primaryFile.path)) {
      mergedSecondary.add(other.primaryFile);
    }
    for (final f in other.secondaryFiles) {
      if (f.path != primaryFile.path &&
          !mergedSecondary.any((x) => x.path == f.path)) {
        mergedSecondary.add(f);
      }
    }

    return MediaEntity(
      primaryFile: primaryFile,
      secondaryFiles: mergedSecondary,
      dateTaken: bestDate,
      dateAccuracy: bestAccuracy,
      dateTimeExtractionMethod: bestMethod,
      partnershared: partnershared || other.partnershared,
      belongToAlbums: mergedAlbums,
    );
  }

  @override
  bool operator ==(final Object other) {
    if (identical(this, other)) return true;
    if (other is! MediaEntity) return false;

    if (other.primaryFile.path != primaryFile.path) return false;

    final samePartner = other.partnershared == partnershared;
    final sameDate = other.dateTaken == dateTaken &&
        other.dateAccuracy == dateAccuracy &&
        other.dateTimeExtractionMethod == dateTimeExtractionMethod;

    // Compare album keys only (cheap structural equality)
    final aKeys = belongToAlbums.keys.toSet();
    final bKeys = other.belongToAlbums.keys.toSet();
    final sameAlbumKeys = aKeys.length == bKeys.length && aKeys.containsAll(bKeys);

    // Compare secondary files by path sets
    final aSec = secondaryFiles.map((f) => f.path).toSet();
    final bSec = other.secondaryFiles.map((f) => f.path).toSet();
    final sameSecondaries = aSec.length == bSec.length && aSec.containsAll(bSec);

    return samePartner && sameDate && sameAlbumKeys && sameSecondaries;
  }

  @override
  int get hashCode => Object.hash(
        primaryFile.path,
        dateTaken,
        dateAccuracy,
        dateTimeExtractionMethod,
        partnershared,
        Object.hashAllUnordered(belongToAlbums.keys),
        Object.hashAllUnordered(secondaryFiles.map((f) => f.path)),
      );

  @override
  String toString() {
    final dateInfo = dateTaken != null ? ', dateTaken: $dateTaken' : '';
    final accuracyInfo =
        dateAccuracy != null ? ' (${dateAccuracy!.description})' : '';
    final partnerInfo = partnershared ? ', partnershared: true' : '';
    final albumsCount = albumNames.length;
    final secondaries = secondaryFiles.length;
    return 'MediaEntity(${primaryFile.path}$dateInfo$accuracyInfo, '
        'albums: $albumsCount, secondaries: $secondaries$partnerInfo)';
  }

  // ===== Private helpers =====

  static bool _pathIsInYearFolder(String p) {
    final normalized = p.replaceAll('\\', '/');
    final segments = normalized.split('/');

    final pureYear = RegExp(r'^(19|20)\d{2}$');
    final localizedYear = RegExp(
      r'^(photos\s+from|fotos\s+de)\s+(19|20)\d{2}$',
      caseSensitive: false,
    );

    for (final seg in segments) {
      final s = seg.trim();
      if (pureYear.hasMatch(s)) return true;
      if (localizedYear.hasMatch(s.toLowerCase())) return true;
    }
    return false;
  }
}

/// Strongly-typed album metadata for a media entity.
/// Kept minimal on purpose but easily extensible (cover, description, id, etc.).
class AlbumInfo {
  const AlbumInfo({
    required this.name,
    Set<String>? sourceDirectories,
  }) : sourceDirectories = sourceDirectories ?? const {};

  /// Album display/name key (already sanitized by the discovery layer).
  final String name;

  /// Directories in the Takeout where a physical file for this album existed.
  /// Useful for diagnostics and reliable album reconstruction.
  final Set<String> sourceDirectories;

  /// Returns a new `AlbumInfo` with `dir` added to `sourceDirectories`.
  AlbumInfo addSourceDir(final String dir) {
    if (dir.isEmpty) return this;
    final next = Set<String>.from(sourceDirectories)..add(dir);
    return AlbumInfo(name: name, sourceDirectories: next);
  }

  /// Merges two AlbumInfo objects with the same album name.
  AlbumInfo merge(final AlbumInfo other) {
    if (other.name != name) return this;
    if (other.sourceDirectories.isEmpty) return this;
    final next = Set<String>.from(sourceDirectories)..addAll(other.sourceDirectories);
    return AlbumInfo(name: name, sourceDirectories: next);
  }

  @override
  String toString() => 'AlbumInfo(name: $name, dirs: ${sourceDirectories.length})';
}
