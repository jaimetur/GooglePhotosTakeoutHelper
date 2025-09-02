import 'package:gpth/gpth_lib_exports.dart';

/// Service for calculating processing metrics
class ProcessingMetricsService {
  /// Creates a new processing metrics service
  const ProcessingMetricsService();

  /// Calculates total number of output artifacts based on album behavior.
  ///
  /// New immutable model semantics:
  /// - "shortcut" / "duplicate-copy" / "reverse-shortcut":
  ///   1 output for the primary + one artifact per album membership.
  /// - "json": one record per entity.
  /// - "nothing": only entities that originally lived in year-based folders.
  int calculateOutputFileCount(
    final MediaEntityCollection collection,
    final String albumOption,
  ) {
    switch (albumOption) {
      case 'shortcut':
      case 'duplicate-copy':
      case 'reverse-shortcut':
        {
          int total = 0;
          for (final MediaEntity e in collection.media) {
            total += 1 + e.albumNames.length;
          }
          return total;
        }
      case 'json':
        return collection.media.length;

      case 'nothing':
        {
          int total = 0;
          for (final MediaEntity e in collection.media) {
            if (_entityHasYearBasedFiles(e)) total++;
          }
          return total;
        }

      default:
        throw ArgumentError.value(
          albumOption,
          'albumOption',
          'Unknown album option. Valid options: shortcut, duplicate-copy, reverse-shortcut, json, nothing',
        );
    }
  }

  /// Calculates basic statistics for the current collection.
  ///
  /// totalFiles = primary (1) + count of secondary files for each entity (physical inputs).
  Map<String, dynamic> calculateStatistics(
    final MediaEntityCollection collection,
  ) {
    final stats = <String, dynamic>{};

    // Totals
    stats['totalMedia'] = collection.media.length;

    // Media with a date assigned
    int mediaWithDates = 0;
    for (final m in collection.media) {
      if (m.dateTaken != null) mediaWithDates++;
    }
    stats['mediaWithDates'] = mediaWithDates;

    // Media with any album association
    int mediaWithAlbums = 0;
    for (final m in collection.media) {
      if (m.hasAlbumAssociations) mediaWithAlbums++;
    }
    stats['mediaWithAlbums'] = mediaWithAlbums;

    // Physical input files tracked by the model (primary + secondaries)
    int totalFiles = 0;
    for (final m in collection.media) {
      totalFiles += 1 + m.secondaryFiles.length;
    }
    stats['totalFiles'] = totalFiles;

    // Output counts by album options
    for (final option in const [
      'shortcut',
      'duplicate-copy',
      'reverse-shortcut',
      'json',
      'nothing',
    ]) {
      stats['outputCount_$option'] = calculateOutputFileCount(
        collection,
        option,
      );
    }

    return stats;
  }

  // --------------------------------------------------------------------------
  // Helpers (kept local so this file does not depend on MediaEntity extensions)
  // --------------------------------------------------------------------------

  /// Heuristic: returns true if any of the entity's paths look like a Google
  /// Takeout year-based folder (e.g., ".../Photos from 2019/...").
  bool _entityHasYearBasedFiles(final MediaEntity e) {
    if (_pathLooksYearBased(e.primaryFile.path)) return true;
    for (final f in e.secondaryFiles) {
      if (_pathLooksYearBased(f.path)) return true;
    }
    return false;
  }

  bool _pathLooksYearBased(final String p) {
    final s = p.replaceAll('\\', '/').toLowerCase();
    // Common localized patterns for Google Takeout year folders
    if (RegExp(r'/photos from \d{4}/').hasMatch(s)) return true; // English
    if (RegExp(r'/fotos de \d{4}/').hasMatch(s)) return true; // Spanish
    if (RegExp(r'/fotos del \d{4}/').hasMatch(s)) return true; // Spanish alt.
    if (RegExp(r'/fotos desde \d{4}/').hasMatch(s)) return true; // Spanish alt.
    return false;
  }
}
