/// Service for calculating processing metrics and file counts
///
/// Extracted from utils.dart to provide focused functionality for
/// calculating expected outputs and processing statistics.
library;

import '../../media.dart';

/// Service for calculating processing metrics
class ProcessingMetricsService {
  /// Creates a new processing metrics service
  const ProcessingMetricsService();

  /// Calculates total number of output files based on album behavior
  ///
  /// [media] List of media objects
  /// [albumOption] Album handling option ('shortcut', 'duplicate-copy', etc.)
  /// Returns expected number of output files
  int calculateOutputFileCount(
    final List<Media> media,
    final String albumOption,
  ) {
    switch (albumOption) {
      case 'shortcut':
      case 'duplicate-copy':
      case 'reverse-shortcut':
        return media.fold(
          0,
          (final int prev, final Media e) => prev + e.files.length,
        );
      case 'json':
        return media.length;
      case 'nothing':
        return media.where((final Media e) => e.files.containsKey(null)).length;
      default:
        throw ArgumentError.value(
          albumOption,
          'albumOption',
          'Unknown album option. Valid options are: shortcut, duplicate-copy, reverse-shortcut, json, nothing',
        );
    }
  }

  /// Calculates processing statistics
  ///
  /// Returns a map with various metrics about the media collection
  Map<String, dynamic> calculateStatistics(final List<Media> media) {
    final stats = <String, dynamic>{};

    stats['totalMedia'] = media.length;
    stats['mediaWithDates'] = media
        .where((final m) => m.dateTaken != null)
        .length;
    stats['mediaWithAlbums'] = media
        .where((final m) => m.entity.hasAlbumAssociations)
        .length;
    stats['totalFiles'] = media.fold(
      0,
      (final sum, final m) => sum + m.files.length,
    );

    // Calculate by album options
    for (final option in ['shortcut', 'duplicate-copy', 'json', 'nothing']) {
      stats['outputCount_$option'] = calculateOutputFileCount(media, option);
    }

    return stats;
  }
}
