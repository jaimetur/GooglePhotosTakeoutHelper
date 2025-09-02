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
  static bool _calculateCanonical(final String source, final String? target) {
    final yearPattern = RegExp(
      r'(?:^|[/\\])Photos from (?:19|20)\d{2}\)?[^/\\]*(?:$|[/\\])',
    );
    final allPhotosPattern = RegExp(r'(?:^|[/\\])ALL_PHOTOS(?:$|[/\\])');

    final fromYearFolder = yearPattern.hasMatch(source);
    final toAllPhotos = target != null && allPhotosPattern.hasMatch(target);

    return fromYearFolder || toAllPhotos;
  }

  @override
  String toString() => 'FileEntity(sourcePath=$_sourcePath, targetPath=$_targetPath, '
        'path=$path, isCanonical=$_isCanonical, isShortcut=$_isShortcut, '
        'dateAccuracy=$_dateAccuracy, ranking=$_ranking)';
}
