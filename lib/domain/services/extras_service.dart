import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../shared/constants/extra_formats.dart';
import '../entities/media_entity.dart';
import '../models/media_entity_collection.dart';

/// Service for handling "extra" format files (edited versions)
///
/// This service provides functionality to identify and remove edited versions
/// of photos and videos, such as files ending with "-edited", "-bearbeitet", etc.
class ExtrasService {
  /// Creates a new extras service
  const ExtrasService();

  /// Removes media files that match "extra" format patterns (edited versions)
  ///
  /// Filters out files with names ending in language-specific "edited" suffixes
  /// like "-edited", "-bearbeitet", "-modifié", etc. Uses Unicode normalization
  /// to handle accented characters correctly on macOS.
  ///
  /// [collection] MediaEntityCollection to filter
  /// Returns new collection with extras removed and count of removed items
  ({MediaEntityCollection collection, int removedCount}) removeExtras(
    final MediaEntityCollection collection,
  ) {
    final List<MediaEntity> filteredEntities = [];
    int removedCount = 0;

    for (final MediaEntity entity in collection.media) {
      final String name = p
          .withoutExtension(p.basename(entity.files.firstFile.path))
          .toLowerCase();
      final String normalizedName = unorm.nfc(name);

      bool isExtra = false;
      for (final String extra in extraFormats) {
        if (normalizedName.endsWith(extra)) {
          isExtra = true;
          break;
        }
      }

      if (isExtra) {
        removedCount++;
      } else {
        filteredEntities.add(entity);
      }
    }

    return (
      collection: MediaEntityCollection(filteredEntities),
      removedCount: removedCount,
    );
  }

  /// Removes "extra" format suffixes from filenames
  ///
  /// Uses multiple strategies to identify and remove edited format suffixes:
  /// 1. Direct suffix matching
  /// 2. Partial suffix matching for truncated names
  /// 3. Cross-extension pattern matching
  /// 4. Edge case pattern matching
  ///
  /// [filename] Original filename
  /// Returns filename with extra formats removed, or original if no match
  // ignore: prefer_expression_function_bodies
  String removeExtraFormats(final String filename) {
    // Try each strategy in order of specificity
    return removeCompleteExtraFormats(filename) ??
        removePartialExtraFormats(filename) ??
        removeCrossExtensionExtraFormats(filename) ??
        removeEdgeCaseExtraFormats(filename) ??
        filename;
  }

  /// Strategy 1: Direct matching against complete extra format list
  ///
  /// Most conservative strategy that only removes suffixes that exactly
  /// match known patterns from the extraFormats list.
  ///
  /// [filename] Original filename
  /// Returns filename with complete extra formats removed, or null if no match
  String? removeCompleteExtraFormats(final String filename) {
    // MacOS uses NFD that doesn't work with our accents 🙃🙃
    final String normalizedFilename = unorm.nfc(filename);
    final String originalExt = p.extension(normalizedFilename);
    final String nameWithoutExt = p.basenameWithoutExtension(
      normalizedFilename,
    );

    for (final String suffix in extraFormats) {
      if (nameWithoutExt.toLowerCase().endsWith(suffix)) {
        final String cleanName = nameWithoutExt.substring(
          0,
          nameWithoutExt.length - suffix.length,
        );
        final String dirname = p.dirname(normalizedFilename);
        return dirname == '.'
            ? '$cleanName$originalExt'
            : p.join(dirname, '$cleanName$originalExt');
      }
    }
    return null;
  }

  /// Strategy 2: Partial matching for truncated extra formats
  ///
  /// Handles cases where filenames were truncated but still contain
  /// recognizable parts of editing suffixes.
  ///
  /// [filename] Original filename
  /// Returns filename with partial extra formats removed, or null if no match
  String? removePartialExtraFormats(final String filename) {
    // MacOS uses NFD that doesn't work with our accents 🙃🙃
    final String normalizedFilename = unorm.nfc(filename);
    final String originalExt = p.extension(normalizedFilename);

    final RegExpMatch? lastDashMatch = RegExp(
      r'-[a-zA-ZÀ-ÖØ-öø-ÿ]*$',
    ).firstMatch(p.basenameWithoutExtension(normalizedFilename));

    if (lastDashMatch == null) return null;

    final String beforeDash = p
        .basenameWithoutExtension(normalizedFilename)
        .substring(0, lastDashMatch.start);
    final String afterDash = lastDashMatch.group(0)!;

    // Check if this could be a truncated version of any extra format
    for (final String suffix in extraFormats) {
      if (suffix.toLowerCase().startsWith(afterDash.toLowerCase()) &&
          afterDash.length >= 3) {
        // At least 3 chars to avoid false positives like "-ed"
        final String dirname = p.dirname(normalizedFilename);
        return dirname == '.'
            ? '$beforeDash$originalExt'
            : p.join(dirname, '$beforeDash$originalExt');
      }
    }

    return null;
  }

  /// Strategy 3: Cross-extension pattern matching
  ///
  /// Handles cases where file extensions were changed but editing
  /// suffixes remain in the base name.
  ///
  /// [filename] Original filename
  /// Returns filename with cross-extension patterns removed, or null if no match
  String? removeCrossExtensionExtraFormats(final String filename) {
    // Check for patterns like "photo-edited.mp4" -> "photo.jpg"
    final String normalizedFilename = unorm.nfc(filename);
    final String nameWithoutExt = p.basenameWithoutExtension(
      normalizedFilename,
    );
    final String ext = p.extension(normalizedFilename);

    // Look for cross-extension patterns where editing suffixes exist
    // but the extension might have changed
    for (final String suffix in extraFormats) {
      if (nameWithoutExt.toLowerCase().endsWith(suffix)) {
        final String baseName = nameWithoutExt.substring(
          0,
          nameWithoutExt.length - suffix.length,
        );

        // For video extensions, try common photo extensions
        if (['.mp4', '.mov', '.avi'].contains(ext.toLowerCase())) {
          final String dirname = p.dirname(normalizedFilename);
          return dirname == '.'
              ? '$baseName.jpg'
              : p.join(dirname, '$baseName.jpg');
        }
      }
    }

    return null;
  }

  /// Strategy 4: Last resort pattern matching for edge cases
  ///
  /// Handles edge cases where other strategies might miss truncated patterns.
  /// Looks for any pattern ending with dash and partial text that could be
  /// a truncated "edited" suffix.
  ///
  /// [filename] Original filename
  /// Returns filename with edge case patterns removed, or null if no match
  String? removeEdgeCaseExtraFormats(final String filename) {
    // MacOS uses NFD that doesn't work with our accents 🙃🙃
    final String normalizedFilename = unorm.nfc(filename);
    final String originalExt = p.extension(normalizedFilename);

    final RegExpMatch? lastDashMatch = RegExp(
      r'-[a-zA-ZÀ-ÖØ-öø-ÿ\s]*(\(\d+\))?$',
    ).firstMatch(p.basenameWithoutExtension(normalizedFilename));

    if (lastDashMatch == null) return null;

    final String beforeDash = p
        .basenameWithoutExtension(normalizedFilename)
        .substring(0, lastDashMatch.start);
    final String afterDash = lastDashMatch.group(0)!;

    // Check if the text after dash could be a truncated "edited" suffix
    for (final String suffix in extraFormats) {
      // Remove the leading dash for comparison
      final String suffixWithoutDash = suffix.substring(1);
      final String afterDashClean = afterDash
          .replaceAll(RegExp(r'\(\d+\)'), '')
          .substring(1);

      // If what comes after dash could be start of any extra format
      if (suffixWithoutDash.toLowerCase().startsWith(
            afterDashClean.toLowerCase(),
          ) &&
          afterDashClean.length >= 2) {
        // At least 2 chars to avoid false positives
        final String dirname = p.dirname(normalizedFilename);
        return dirname == '.'
            ? '$beforeDash$originalExt'
            : p.join(dirname, '$beforeDash$originalExt');
      }
    }

    return null;
  }
}
