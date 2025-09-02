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
///
/// EXTENDED MODEL (FileEntity-based):
/// - `primaryFile` is now a `FileEntity` (not a File)
/// - `secondaryFiles` is now a `List<FileEntity>`
/// - New: `duplicatesFiles` is a `List<FileEntity>` representing same-directory
///   duplicates (worse ranked) compared to the best-ranked file in that folder.
///
/// Ranking rules (lower ranking = better):
/// 1) Files under a year folder (e.g., /.../2020/...) outrank files under album folders
/// 2) On ties, shorter basename outranks longer basename
/// 3) On ties, shorter full path outranks longer full path
///
/// Primary/secondaries/duplicates selection:
/// - The best-ranked file across the entity becomes `primaryFile`
/// - Files in *different* directories than the primary become `secondaryFiles`
/// - Files in the *same* directory as another better-ranked file become `duplicatesFiles`
///
/// NOTE: Rankings are now **sequential per entity**: after ordering by the rules,
/// each file receives rank `1..N` where `1` is the highest priority.
class MediaEntity {
  /// Creates a new media entity.
  ///
  /// NOTE: This public factory normalizes ranking and splits files into primary,
  /// secondary, and duplicates according to the rules described above.
  factory MediaEntity({
    required final FileEntity primaryFile,
    List<FileEntity>? secondaryFiles,
    List<FileEntity>? duplicatesFiles,
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
    final bool partnershared = false,
    Map<String, AlbumInfo>? belongToAlbums,
  }) {
    final all = <FileEntity>[
      primaryFile,
      ...?secondaryFiles,
      ...?duplicatesFiles,
    ];

    final normalized = _normalizeAndSplit(all);

    return MediaEntity._internal(
      primaryFile: normalized.primary,
      secondaryFiles: normalized.secondaries,
      duplicatesFiles: normalized.duplicates,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnerShared: partnershared,
      belongToAlbums: belongToAlbums ?? const {},
    );
  }

  /// Convenience factory for a single-file entity.
  factory MediaEntity.single({
    required final FileEntity file,
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
    final bool partnershared = false,
    Map<String, AlbumInfo>? belongToAlbums,
  }) =>
      MediaEntity(
        primaryFile: file,
        secondaryFiles: const <FileEntity>[],
        duplicatesFiles: const <FileEntity>[],
        dateTaken: dateTaken,
        dateAccuracy: dateAccuracy,
        dateTimeExtractionMethod: dateTimeExtractionMethod,
        partnershared: partnershared,
        belongToAlbums: belongToAlbums,
      );

  /// Private internal constructor used after normalization.
  const MediaEntity._internal({
    required this.primaryFile,
    required this.secondaryFiles,
    required this.duplicatesFiles,
    this.dateTaken,
    this.dateAccuracy,
    this.dateTimeExtractionMethod,
    this.partnerShared = false,
    required this.belongToAlbums,
  });

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
  final bool partnerShared;

  /// Canonical (primary) file for this media entity.
  final FileEntity primaryFile;

  /// Original physical paths of all secondary duplicates across *different* folders.
  final List<FileEntity> secondaryFiles;

  /// Duplicates that live in the *same* folder as a better-ranked file.
  final List<FileEntity> duplicatesFiles;

  /// Backward-compat convenience getter (integer accuracy).
  int? get dateTakenAccuracy => dateAccuracy?.value;

  /// Whether this media is associated with any album.
  bool get hasAlbumAssociations => belongToAlbums.isNotEmpty;

  /// All album names where this media belongs to.
  Set<String> get albumNames => belongToAlbums.keys.toSet();

  /// Returns true if any path (primary or secondary/duplicate) lives inside a “year-based” folder.
  ///
  /// Heuristics:
  /// - Pure year directory: `2020`, `2015`, ...
  /// - Localized folder names: `Photos from 2019`, `Fotos de 2019` (case-insensitive)
  bool get hasYearBasedFiles {
    if (_pathIsInYearFolder(primaryFile.sourcePath)) return true;
    for (final f in secondaryFiles) {
      if (_pathIsInYearFolder(f.sourcePath)) return true;
    }
    for (final f in duplicatesFiles) {
      if (_pathIsInYearFolder(f.sourcePath)) return true;
    }
    return false;
  }

  // ────────────────────────────────────────────────────────────────────────────
  // External accessors (requested API)
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns the number of secondary files.
  int get secondaryCount => secondaryFiles.length;

  /// Returns the number of duplicate files (same-folder duplicates).
  int get duplicatesCount => duplicatesFiles.length;

  /// Returns all secondary files.
  List<FileEntity> getSecondaries() => List<FileEntity>.unmodifiable(secondaryFiles);

  /// Returns all duplicate files.
  List<FileEntity> getDuplicates() => List<FileEntity>.unmodifiable(duplicatesFiles);

  /// Returns the total number of files in the entity.
  int get totalFilesCount => 1 + secondaryFiles.length + duplicatesFiles.length;

  /// Returns all files in the entity, including the primary one.
  List<FileEntity> getAllFiles() =>
      <FileEntity>[primaryFile, ...secondaryFiles, ...duplicatesFiles];

  /// Returns the best-ranked file (i.e., the current primary).
  FileEntity getBestRankedFile() => primaryFile;

  /// Returns a copy swapping the given `secondary` with the current `primary`.
  /// The former primary becomes a secondary; normalization is applied afterward.
  MediaEntity swapPrimaryWithSecondary(final FileEntity secondary) {
    if (!secondaryFiles.any((f) => _sameIdentity(f, secondary))) return this;
    final all = getAllFiles();
    // Promote the provided secondary by lowering its ranking to beat all others.
    final promoted = _withRankingAdjusted(secondary, -1);
    final replacedAll = all
        .map((f) => _sameIdentity(f, secondary) ? promoted : f)
        .toList(growable: false);
    final normalized = _normalizeAndSplit(replacedAll);
    return _copyWithFiles(normalized);
  }

  // ────────────────────────────────────────────────────────────────────────────
  // Mutators (immutable-by-copy) — keep existing API adapted to FileEntity
  // ────────────────────────────────────────────────────────────────────────────

  /// Returns a copy with updated date/accuracy/method.
  MediaEntity withDate({
    final DateTime? dateTaken,
    final DateAccuracy? dateAccuracy,
    final DateTimeExtractionMethod? dateTimeExtractionMethod,
  }) =>
      MediaEntity._internal(
        primaryFile: primaryFile,
        secondaryFiles: secondaryFiles,
        duplicatesFiles: duplicatesFiles,
        dateTaken: dateTaken ?? this.dateTaken,
        dateAccuracy: dateAccuracy ?? this.dateAccuracy,
        dateTimeExtractionMethod:
            dateTimeExtractionMethod ?? this.dateTimeExtractionMethod,
        partnerShared: partnerShared,
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

    return MediaEntity._internal(
      primaryFile: primaryFile,
      secondaryFiles: secondaryFiles,
      duplicatesFiles: duplicatesFiles,
      dateTaken: dateTaken,
      dateAccuracy: dateAccuracy,
      dateTimeExtractionMethod: dateTimeExtractionMethod,
      partnerShared: partnerShared,
      belongToAlbums: next,
    );
  }

  /// Returns a copy adding a secondary-like file. It will be ranked and the
  /// entity will be normalized, so it might become primary or duplicate.
  MediaEntity withSecondaryFile(final FileEntity file) {
    final all = getAllFiles();
    if (all.any((f) => _sameIdentity(f, file))) return this;

    final rankedNew = _withRankingComputed(file, all);
    final normalized = _normalizeAndSplit([...all, rankedNew]);
    return _copyWithFiles(normalized);
  }

  /// Returns a copy promoting `newPrimary` to primary in an immutable way.
  ///
  /// NOTE: With ranking normalization, this method will force `newPrimary`
  /// to become the best-ranked candidate before splitting again.
  MediaEntity withPrimaryFile(final FileEntity newPrimary) {
    final all = getAllFiles();
    if (!all.any((f) => _sameIdentity(f, newPrimary))) return this;
    final forcedBest = _withRankingAdjusted(newPrimary, -1);
    final replacedAll =
        all.map((f) => _sameIdentity(f, newPrimary) ? forcedBest : f).toList();
    final normalized = _normalizeAndSplit(replacedAll);
    return _copyWithFiles(normalized);
  }

  /// Merges this entity with another:
  /// - Merges album metadata (deep merge).
  /// - Selects the best date/accuracy/method.
  /// - Accumulates files (deduplicated by identity) then re-ranks and normalizes.
  ///
  /// The final primary is selected by ranking rules across the merged set.
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

    // 3) Merge files by identity (sourcePath + targetPath + isShortcut)
    final mergedAll = <FileEntity>[];
    void addUnique(final FileEntity f) {
      if (!mergedAll.any((x) => _sameIdentity(x, f))) mergedAll.add(f);
    }

    for (final f in getAllFiles()) addUnique(f);
    for (final f in other.getAllFiles()) addUnique(f);

    final normalized = _normalizeAndSplit(mergedAll);

    return MediaEntity._internal(
      primaryFile: normalized.primary,
      secondaryFiles: normalized.secondaries,
      duplicatesFiles: normalized.duplicates,
      dateTaken: bestDate,
      dateAccuracy: bestAccuracy,
      dateTimeExtractionMethod: bestMethod,
      partnerShared: partnerShared || other.partnerShared,
      belongToAlbums: mergedAlbums,
    );
  }

  @override
  bool operator ==(final Object other) {
    if (identical(this, other)) return true;
    if (other is! MediaEntity) return false;

    // Primary identity comparison
    if (!_sameIdentity(other.primaryFile, primaryFile)) return false;

    final samePartner = other.partnerShared == partnerShared;
    final sameDate = other.dateTaken == dateTaken &&
        other.dateAccuracy == dateAccuracy &&
        other.dateTimeExtractionMethod == dateTimeExtractionMethod;

    // Compare album keys only (cheap structural equality)
    final aKeys = belongToAlbums.keys.toSet();
    final bKeys = other.belongToAlbums.keys.toSet();
    final sameAlbumKeys = aKeys.length == bKeys.length && aKeys.containsAll(bKeys);

    // Compare secondaries and duplicates by identity sets
    bool listEq(final List<FileEntity> a, final List<FileEntity> b) {
      final sa = a.map(_fileIdentityKey).toSet();
      final sb = b.map(_fileIdentityKey).toSet();
      return sa.length == sb.length && sa.containsAll(sb);
    }

    final sameSecondaries = listEq(secondaryFiles, other.secondaryFiles);
    final sameDuplicates = listEq(duplicatesFiles, other.duplicatesFiles);

    return samePartner && sameDate && sameAlbumKeys && sameSecondaries && sameDuplicates;
  }

  @override
  int get hashCode => Object.hash(
        _fileIdentityKey(primaryFile),
        dateTaken,
        dateAccuracy,
        dateTimeExtractionMethod,
        partnerShared,
        Object.hashAllUnordered(belongToAlbums.keys),
        Object.hashAllUnordered(secondaryFiles.map(_fileIdentityKey)),
        Object.hashAllUnordered(duplicatesFiles.map(_fileIdentityKey)),
      );

  @override
  String toString() {
    final dateInfo = dateTaken != null ? ', dateTaken: $dateTaken' : '';
    final accuracyInfo =
        dateAccuracy != null ? ' (${dateAccuracy!.description})' : '';
    final partnerInfo = partnerShared ? ', partnershared: true' : '';
    final albumsCount = albumNames.length;
    final secondaries = secondaryFiles.length;
    final duplicates = duplicatesFiles.length;
    return 'MediaEntity(${primaryFile.sourcePath}$dateInfo$accuracyInfo, '
        'albums: $albumsCount, secondaries: $secondaries, duplicates: $duplicates$partnerInfo)';
  }

  // ===== Private helpers =====

  /// Normalizes ranking for all candidates and splits into primary/secondary/duplicates.
  static _SplitResult _normalizeAndSplit(final List<FileEntity> allRaw) {
    // 1) Deduplicate by identity
    final all = <FileEntity>[];
    for (final f in allRaw) {
      if (!all.any((x) => _sameIdentity(x, f))) all.add(f);
    }

    // 2) Compute preliminary ranking for shape-compat (not decisive anymore).
    final prelim = all.map((f) => _withRankingComputed(f, all)).toList(growable: false);

    // 3) Determine final order:
    //    - Any negative `ranking` means "force to the front" (used by withPrimaryFile)
    //    - Then apply the canonical/basename/path-length rules
    final ordered = _orderForRanking(prelim);

    // 4) Assign sequential rankings 1..N (1 = highest priority)
    final ranked = <FileEntity>[];
    for (var i = 0; i < ordered.length; i++) {
      final f = ordered[i];
      ranked.add(FileEntity(
        sourcePath: f.sourcePath,
        targetPath: f.targetPath,
        isShortcut: f.isShortcut,
        dateAccuracy: f.dateAccuracy,
        ranking: i + 1,
      ));
    }

    // 5) Select primary (rank 1 wins)
    final primary = ranked.first;

    // 6) Partition by folder:
    //    - same-folder worse-ranked files → duplicates
    //    - different-folder files → secondaries
    final primaryDir = _dirOf(primary.sourcePath);
    final secondaries = <FileEntity>[];
    final duplicates = <FileEntity>[];

    // Build per-folder best to determine duplicates within each folder
    final byFolder = <String, List<FileEntity>>{};
    for (final f in ranked) {
      final dir = _dirOf(f.sourcePath);
      (byFolder[dir] ??= <FileEntity>[]).add(f);
    }
    final bestPerFolder = <String, FileEntity>{};
    for (final e in byFolder.entries) {
      e.value.sort(_byRankingThenPath);
      bestPerFolder[e.key] = e.value.first;
    }

    for (final f in ranked.skip(1)) {
      final dir = _dirOf(f.sourcePath);
      final bestInDir = bestPerFolder[dir]!;
      if (_sameIdentity(f, bestInDir)) {
        // if it's the best in its folder but not the global best, it is a secondary (different folder than primary)
        if (dir == primaryDir) {
          // same folder as primary but not better than primary → duplicate
          duplicates.add(f);
        } else {
          secondaries.add(f);
        }
      } else {
        // not best in its own folder → duplicate
        duplicates.add(f);
      }
    }

    return _SplitResult(primary: primary, secondaries: secondaries, duplicates: duplicates);
  }

  /// Compute or refresh ranking for `file` against the full set `all`.
  static FileEntity _withRankingComputed(final FileEntity file, final List<FileEntity> all) {
    final rank = _computeRanking(file);
    // produce a new FileEntity with updated ranking (keeping all other fields)
    return FileEntity(
      sourcePath: file.sourcePath,
      targetPath: file.targetPath,
      isShortcut: file.isShortcut,
      dateAccuracy: file.dateAccuracy,
      ranking: rank,
    );
    // `isCanonical` is automatically recalculated by FileEntity on construction
  }

  /// Adjust ranking to a specific value (used to force a promotion).
  static FileEntity _withRankingAdjusted(final FileEntity file, final int ranking) {
    return FileEntity(
      sourcePath: file.sourcePath,
      targetPath: file.targetPath,
      isShortcut: file.isShortcut,
      dateAccuracy: file.dateAccuracy,
      ranking: ranking,
    );
  }

  /// Ranking calculation:
  /// - Prefer year-folder (canonical) over album-folder
  /// - On tie, shorter basename wins
  /// - On tie, shorter full path wins
  ///
  /// IMPORTANT: This function now returns a **provisional** value only.
  /// Final ranks are assigned **sequentially (1..N)** inside `_normalizeAndSplit`.
  static int _computeRanking(final FileEntity f) {
    // Keep returning 0 to avoid leaking an absolute score. Ordering is decided later.
    return 0;
  }

  /// Comparator: by ranking, then by path (stable)
  static int _byRankingThenPath(final FileEntity a, final FileEntity b) {
    final r = a.ranking.compareTo(b.ranking);
    if (r != 0) return r;
    return a.sourcePath.compareTo(b.sourcePath);
  }

  /// Orders files for ranking assignment:
  /// 1) Files with negative `ranking` first (explicit promotion)
  /// 2) Canonical (year-folder) before album-folder
  /// 3) Shorter basename first
  /// 4) Shorter full path first
  /// 5) Stable tie-breaker by lowercase path
  static List<FileEntity> _orderForRanking(final List<FileEntity> files) {
    final forced = <FileEntity>[];
    final regular = <FileEntity>[];
    for (final f in files) {
      if (f.ranking < 0) {
        forced.add(f);
      } else {
        regular.add(f);
      }
    }
    int cmp(final FileEntity a, final FileEntity b) {
      final ac = _pathIsInYearFolder(a.sourcePath) ? 0 : 1;
      final bc = _pathIsInYearFolder(b.sourcePath) ? 0 : 1;
      if (ac != bc) return ac - bc;

      final ab = _basenameOf(a.sourcePath).length;
      final bb = _basenameOf(b.sourcePath).length;
      if (ab != bb) return ab - bb;

      final ap = a.sourcePath.length;
      final bp = b.sourcePath.length;
      if (ap != bp) return ap - bp;

      return a.sourcePath.toLowerCase().compareTo(b.sourcePath.toLowerCase());
    }

    forced.sort(cmp);
    regular.sort(cmp);
    return <FileEntity>[...forced, ...regular];
  }

  static bool _sameIdentity(final FileEntity a, final FileEntity b) {
    return a.sourcePath == b.sourcePath &&
        a.targetPath == b.targetPath &&
        a.isShortcut == b.isShortcut;
  }

  static String _fileIdentityKey(final FileEntity f) =>
      '${f.isShortcut ? 'S' : 'F'}|${f.targetPath ?? ''}|${f.sourcePath}';

  static String _dirOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? '' : normalized.substring(0, idx);
  }

  static String _basenameOf(final String p) {
    final normalized = p.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? normalized : normalized.substring(idx + 1);
  }

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

  MediaEntity _copyWithFiles(final _SplitResult norm) => MediaEntity._internal(
        primaryFile: norm.primary,
        secondaryFiles: norm.secondaries,
        duplicatesFiles: norm.duplicates,
        dateTaken: dateTaken,
        dateAccuracy: dateAccuracy,
        dateTimeExtractionMethod: dateTimeExtractionMethod,
        partnerShared: partnerShared,
        belongToAlbums: belongToAlbums,
      );
}

/// Helper container for normalized split.
class _SplitResult {
  const _SplitResult({
    required this.primary,
    required this.secondaries,
    required this.duplicates,
  });

  final FileEntity primary;
  final List<FileEntity> secondaries;
  final List<FileEntity> duplicates;
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
