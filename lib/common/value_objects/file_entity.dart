import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';

/// Represents a single file entity within GPTH.
/// Encapsulates source and target paths, canonicality, shortcut status,
/// date accuracy, and ranking information.
///
/// A FileEntity can represent:
/// - The primary file of a MediaEntity (lowest ranking value)
/// - A secondary file (higher ranking values)
/// - A shortcut created during Step 7 (isShortcut = true)
class FileEntity {
  FileEntity({
    required final String sourcePath,
    final String? targetPath,
    final bool isShortcut = false,
    final DateAccuracy? dateAccuracy,
    final int ranking = 0,
  }) : _sourcePath = sourcePath,
       _targetPath = targetPath,
       _isShortcut = isShortcut,
       _dateAccuracy = dateAccuracy,
       _ranking = ranking,
       _isCanonical = _calculateCanonical(sourcePath, targetPath);

  String _sourcePath;
  String? _targetPath;
  bool _isCanonical;
  bool _isShortcut;
  DateAccuracy? _dateAccuracy;
  int _ranking;

  // ────────────────────────────────────────────────────────────────
  // Getters
  // ────────────────────────────────────────────────────────────────

  /// Original source path (where the file was discovered).
  String get sourcePath => _sourcePath;

  /// Final target path (where the file is moved/copied to), or null if not moved.
  String? get targetPath => _targetPath;

  /// Effective path: returns targetPath if not null (file moved), otherwise sourcePath.
  String get path => _targetPath ?? _sourcePath;

  /// Whether this file is considered canonical (see _calculateCanonical).
  bool get isCanonical => _isCanonical;

  /// True when Step 7 strategy placed this file as a shortcut to the entity primary.
  bool get isShortcut => _isShortcut;

  /// Date accuracy associated to this file (if any).
  DateAccuracy? get dateAccuracy => _dateAccuracy;

  /// Ranking score (lower is better). The best-ranked file becomes the primary.
  int get ranking => _ranking;

  /// Convenience: obtain a dart:io File for the effective path (target if present).
  File asFile() => File(path);

  // ────────────────────────────────────────────────────────────────
  // Setters
  // ────────────────────────────────────────────────────────────────

  set sourcePath(final String value) {
    _sourcePath = value;
    _isCanonical = _calculateCanonical(_sourcePath, _targetPath);
  }

  set targetPath(final String? value) {
    _targetPath = value;
    _isCanonical = _calculateCanonical(_sourcePath, _targetPath);
  }

  set isShortcut(final bool value) {
    _isShortcut = value;
  }

  set dateAccuracy(final DateAccuracy? accuracy) {
    _dateAccuracy = accuracy;
  }

  set ranking(final int value) {
    _ranking = value;
  }

  // ────────────────────────────────────────────────────────────────
  // Internal logic
  // ────────────────────────────────────────────────────────────────

  /// Canonicality rules:
  /// - Canonical if sourcePath resides under a folder segment that starts with "Photos from YYYY)" where YYYY is 19xx or 20xx (suffix allowed until next separator), OR
  /// - Canonical if targetPath points to ALL_PHOTOS (versus Albums folders).
  ///
  /// Additional rules (extended as requested):
  /// - For the source: if the *parent folder name* contains "Photos from YYYY" (case-insensitive, where YYYY is a valid year 19xx/20xx), OR if the parent folder name is exactly "YYYY".
  /// - For the target: look at the *directory path* (excluding the filename) and return true if it contains:
  ///     * "ALL_PHOTOS" anywhere, OR
  ///     * a segment "YYYY", OR
  ///     * a structure "YYYY/MM", OR
  ///     * a segment "YYYY-MM"  (YYYY is 19xx/20xx and MM is 01..12).
  static bool _calculateCanonical(final String source, final String? target) {
    // Normalize separators to work uniformly with /.
    String _norm(final String p) => p.replaceAll('\\', '/');

    // Extract parent folder name of the file from a full path.
    String _parentName(final String p) {
      final n = _norm(p);
      final lastSlash = n.lastIndexOf('/');
      if (lastSlash < 0) return '';
      final dir = n.substring(0, lastSlash);
      final prevSlash = dir.lastIndexOf('/');
      return prevSlash < 0 ? dir : dir.substring(prevSlash + 1);
    }

    // Extract directory path (exclude filename) from a full path.
    String _dirPath(final String p) {
      final n = _norm(p);
      final lastSlash = n.lastIndexOf('/');
      return lastSlash < 0 ? '' : n.substring(0, lastSlash);
    }

    // ── Source parent folder checks ────────────────────────────────
    final parent = _parentName(source);
    final yearOnlyRe = RegExp(r'^(?:19|20)\d{2}$'); // exact folder "YYYY"
    final photosFromRe = RegExp(r'photos\s+from\s+(?:19|20)\d{2}', caseSensitive: false); // contains "Photos from YYYY"

    final fromYearFolder = yearOnlyRe.hasMatch(parent) || photosFromRe.hasMatch(parent);

    // ── Target directory checks (exclude filename) ─────────────────
    bool toAllPhotos = false;
    bool toYearStructures = false;

    if (target != null && target.isNotEmpty) {
      final dir = _dirPath(target);

      // ALL_PHOTOS anywhere in the path (directory context only)
      final allPhotosPattern = RegExp(r'(?:^|/)ALL_PHOTOS(?:/|$)');
      toAllPhotos = allPhotosPattern.hasMatch(dir);

      // Year-only segment: .../YYYY/...
      final yearOnlySegment = RegExp(r'(?:^|/)(?:19|20)\d{2}(?:/|$)');

      // Year/Month structure: .../YYYY/MM/...
      final yearMonthSlash = RegExp(r'(?:^|/)(?:19|20)\d{2}/(?:0[1-9]|1[0-2])(?:/|$)');

      // Year-Month segment: .../YYYY-MM/...
      final yearMonthDash = RegExp(r'(?:^|/)(?:19|20)\d{2}-(?:0[1-9]|1[0-2])(?:/|$)');

      toYearStructures = yearOnlySegment.hasMatch(dir) ||
                         yearMonthSlash.hasMatch(dir) ||
                         yearMonthDash.hasMatch(dir);
    }

    return fromYearFolder || toAllPhotos || toYearStructures;
  }

  @override
  String toString() => 'FileEntity(sourcePath=$_sourcePath, targetPath=$_targetPath, '
        'path=$path, isCanonical=$_isCanonical, isShortcut=$_isShortcut, '
        'dateAccuracy=$_dateAccuracy, ranking=$_ranking)';
}
