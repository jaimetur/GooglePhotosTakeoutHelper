import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:gpth/gpth-lib.dart';

/// Service responsible for generating file and directory paths
///
/// This service handles all path generation logic for the moving operations,
/// including date-based folder structures and album-specific paths.
class PathGeneratorService {
  /// Generates the target directory for a file based on album and date information
  ///
  /// [albumKey] The album name (null for ALL_PHOTOS)
  /// [dateTaken] The date the photo was taken
  /// [context] The moving context with configuration
  /// [isPartnerShared] Whether the media is from partner sharing
  /// Returns the target directory path
  Directory generateTargetDirectory(
    final String? albumKey,
    final DateTime? dateTaken,
    final MovingContext context, {
    final bool isPartnerShared = false,
  }) {
    // If partner shared separation is enabled and this is partner shared media
    if (context.dividePartnerShared && isPartnerShared) {
      final String folderName = albumKey?.trim() ?? 'PARTNER_SHARED';

      // Apply date division to partner shared folder if it's the main folder
      final String dateFolder = albumKey == null
          ? _generateDateFolder(dateTaken, context.dateDivision)
          : '';

      return Directory(
        path.join(context.outputDirectory.path, folderName, dateFolder),
      );
    }

    // Original logic for non-partner-shared media
    // final String folderName = albumKey?.trim() ?? 'ALL_PHOTOS';
    final String folderName = albumKey != null
    ? path.join('Albums', albumKey.trim()) // Now All Album's folders will be moved to 'Albums'
    : 'ALL_PHOTOS';


    // Only apply date division to ALL_PHOTOS, not to Albums
    final String dateFolder = albumKey == null
        ? _generateDateFolder(dateTaken, context.dateDivision)
        : '';

    return Directory(
      path.join(context.outputDirectory.path, folderName, dateFolder),
    );
  }

  /// Generates the date-based folder structure
  String _generateDateFolder(
    final DateTime? date,
    final DateDivisionLevel divideToDates,
  ) {
    if (divideToDates == DateDivisionLevel.none) {
      return '';
    }

    if (date == null) {
      return 'date-unknown';
    }

    switch (divideToDates) {
      case DateDivisionLevel.day:
        return path.join(
          '${date.year}',
          date.month.toString().padLeft(2, '0'),
          date.day.toString().padLeft(2, '0'),
        );
      case DateDivisionLevel.month:
        return path.join('${date.year}', date.month.toString().padLeft(2, '0'));
      case DateDivisionLevel.year:
        return '${date.year}';
      case DateDivisionLevel.none:
        return '';
    }
  }

  /// Generates the albums-info.json file path
  String generateAlbumsInfoJsonPath(final Directory outputDirectory) =>
      path.join(outputDirectory.path, 'albums-info.json');

  /// Generates ALL_PHOTOS directory path
  Directory generateAllPhotosDirectory(final Directory outputDirectory) =>
      Directory(path.join(outputDirectory.path, 'ALL_PHOTOS'));

  /// Sanitizes a filename to ensure cross-platform compatibility
  String sanitizeFileName(final String fileName) => fileName
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Gets the target file path for a specific file in a directory
  String generateTargetFilePath(
    final File sourceFile,
    final Directory targetDirectory,
  ) {
    final sanitizedName = sanitizeFileName(path.basename(sourceFile.path));
    return path.join(targetDirectory.path, sanitizedName);
  }
}
