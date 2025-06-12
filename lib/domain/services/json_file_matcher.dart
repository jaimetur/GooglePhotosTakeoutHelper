import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../../extras.dart' as extras;
import '../../utils.dart';

/// Service for finding corresponding JSON metadata files for media files
///
/// Implements multiple strategies to locate JSON files, handling various
/// edge cases from Google Photos Takeout exports including filename
/// truncation, bracket swapping, and extra format removal.
///
/// Strategies are ordered from least to most aggressive to minimize
/// false matches while maximizing success rate.
class JsonFileMatcher {
  /// Attempts to find the corresponding JSON file for a media file
  ///
  /// Tries multiple strategies to locate JSON files, including handling
  /// filename truncation, bracket swapping, and extra format removal.
  /// Strategies are ordered from least to most aggressive (issue #29).
  ///
  /// [file] Media file to find JSON for
  /// [tryhard] If true, uses more aggressive matching strategies
  /// Returns the JSON file if found, null otherwise
  static Future<File?> findJsonForFile(
    final File file, {
    required final bool tryhard,
  }) async {
    final Directory dir = Directory(p.dirname(file.path));
    final String name = p.basename(file.path);

    // Get strategies based on tryhard setting
    final strategies = tryhard
        ? [..._basicStrategies, ..._aggressiveStrategies]
        : _basicStrategies;

    // Try each strategy in order of increasing aggressiveness
    for (final strategy in strategies) {
      final String processedName = strategy.transform(name);

      // First try supplemental-metadata format
      final File supplementalJsonFile = File(
        p.join(dir.path, '$processedName.supplemental-metadata.json'),
      );
      if (await supplementalJsonFile.exists()) return supplementalJsonFile;

      // Then try standard JSON format
      final File jsonFile = File(p.join(dir.path, '$processedName.json'));
      if (await jsonFile.exists()) return jsonFile;
    }
    return null;
  }

  /// Basic strategies (always applied) - ordered from least to most aggressive
  static final List<JsonMatchingStrategy> _basicStrategies = [
    // Strategy 1: No modification (most conservative)
    JsonMatchingStrategy(
      name: 'No modification',
      description: 'Direct filename match without any transformation',
      transform: (final filename) => filename,
    ),

    // Strategy 2: Filename shortening (conservative, addresses filesystem limits)
    const JsonMatchingStrategy(
      name: 'Filename shortening',
      description: 'Handles filename truncation due to filesystem limits',
      transform: _shortenName,
    ),

    // Strategy 3: Bracket number swapping (conservative, known pattern)
    const JsonMatchingStrategy(
      name: 'Bracket number swapping',
      description: 'Swaps bracket position for files like "image(11).jpg"',
      transform: _bracketSwap,
    ),

    // Strategy 4: Remove file extension (moderate, handles Google's extension addition)
    const JsonMatchingStrategy(
      name: 'Remove file extension',
      description: 'Removes extension for cases where Google added one',
      transform: _noExtension,
    ),

    // Strategy 5: Remove known complete extra formats (moderate, safe list)
    const JsonMatchingStrategy(
      name: 'Remove complete extra formats',
      description: 'Removes known editing suffixes like "-edited"',
      transform: _removeExtraComplete,
    ),
  ];

  /// Aggressive strategies (only with tryhard=true) - ordered from least to most aggressive
  static final List<JsonMatchingStrategy> _aggressiveStrategies = [
    // Strategy 6: Remove partial extra formats (moderate to aggressive, truncation handling)
    const JsonMatchingStrategy(
      name: 'Remove partial extra formats',
      description: 'Removes truncated editing suffixes like "-ed"',
      transform: _removeExtraPartial,
    ),

    // Strategy 7: Extension restoration after partial removal (aggressive, reconstruction)
    const JsonMatchingStrategy(
      name: 'Extension restoration after partial removal',
      description: 'Combines partial removal with extension restoration',
      transform: _removeExtraPartialWithExtensionRestore,
    ),

    // Strategy 8: Edge case pattern removal (very aggressive, heuristic-based)
    const JsonMatchingStrategy(
      name: 'Edge case pattern removal',
      description: 'Heuristic-based removal of edge case patterns',
      transform: _removeExtraEdgeCase,
    ),

    // Strategy 9: Remove digit patterns (most aggressive, broad pattern matching)
    const JsonMatchingStrategy(
      name: 'Remove digit patterns',
      description: 'Removes digit patterns like "(1)" from filenames',
      transform: _removeDigit,
    ),
  ];

  /// Gets all available strategies for debugging/testing purposes
  static List<JsonMatchingStrategy> getAllStrategies({
    required final bool includeAggressive,
  }) => includeAggressive
      ? [..._basicStrategies, ..._aggressiveStrategies]
      : _basicStrategies;
}

/// Represents a single JSON file matching strategy
class JsonMatchingStrategy {
  const JsonMatchingStrategy({
    required this.name,
    required this.description,
    required this.transform,
  });

  /// Human-readable name of the strategy
  final String name;

  /// Description of what this strategy does
  final String description;

  /// Function that transforms the filename
  final String Function(String filename) transform;
}

// Strategy Implementation Functions

/// Shortens filename to handle filesystem length limits
///
/// This resolves years of bugs and head-scratches 😆
/// e.g: https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/8#issuecomment-736539592
String _shortenName(final String filename) => '$filename.json'.length > 51
    ? filename.substring(0, 51 - '.json'.length)
    : filename;

/// Handles bracket number swapping in filenames
///
/// Thanks @casualsailo and @denouche for bringing attention!
/// https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/188
/// and https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/175
///
/// Some files have patterns like "image(11).jpg" with JSON "image.jpg(11).json"
/// This function swaps the bracket position to match.
String _bracketSwap(final String filename) {
  // this is with the dot - more probable that it's just before the extension
  final RegExpMatch? match = RegExp(
    r'\(\d+\)\.',
  ).allMatches(filename).lastOrNull;
  if (match == null) return filename;
  final String bracket = match.group(0)!.replaceAll('.', ''); // remove dot
  // remove only last to avoid errors with filenames like:
  // 'image(3).(2)(3).jpg' <- "(3)." repeats twice
  final String withoutBracket = filename.replaceLast(bracket, '');
  return '$withoutBracket$bracket';
}

/// Removes file extension from filename
///
/// Handles cases where original file had no extension but Google added one.
String _noExtension(final String filename) =>
    p.basenameWithoutExtension(File(filename).path);

/// Removes "extra" format suffixes safely using predefined list
///
/// Only removes suffixes from the known safe list in extraFormats.
/// This is the safe, conservative approach that only matches known formats.
/// Handles Unicode normalization for cross-platform compatibility.
String _removeExtraComplete(final String filename) {
  // MacOS uses NFD that doesn't work with our accents 🙃🙃
  // https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/pull/247
  final String normalizedFilename = unorm.nfc(filename);
  final String ext = p.extension(normalizedFilename);
  final String nameWithoutExt = p.basenameWithoutExtension(normalizedFilename);

  for (final String extra in extras.extraFormats) {
    // Check for exact suffix match with optional digit pattern
    final RegExp exactPattern = RegExp(
      RegExp.escape(extra) + r'(\(\d+\))?$',
      caseSensitive: false,
    );

    if (exactPattern.hasMatch(nameWithoutExt)) {
      final String cleanedName = nameWithoutExt.replaceAll(exactPattern, '');
      return cleanedName + ext;
    }
  }
  return normalizedFilename;
}

/// Removes partial extra format suffixes for truncated cases
///
/// Handles cases where filename truncation results in partial suffix matches.
/// Only removes partial matches of known extra formats from extraFormats list.
String _removeExtraPartial(final String filename) =>
    extras.removePartialExtraFormats(filename);

/// Removes partial extra formats and restores truncated extensions
///
/// Combines partial suffix removal with extension restoration for cases
/// where both the suffix and extension were truncated due to filename limits.
String _removeExtraPartialWithExtensionRestore(final String filename) {
  final String originalExt = p.extension(filename);
  final String cleanedFilename = extras.removePartialExtraFormats(filename);

  if (cleanedFilename != filename) {
    log(
      '$filename was renamed to $cleanedFilename by the removePartialExtraFormats function.',
    );

    // Try to restore truncated extension
    final String restoredFilename = extras.restoreFileExtension(
      cleanedFilename,
      originalExt,
    );

    if (restoredFilename != cleanedFilename) {
      log(
        'Extension restored from ${p.extension(cleanedFilename)} to ${p.extension(restoredFilename)} for file: $restoredFilename',
      );
      return restoredFilename;
    }

    return cleanedFilename;
  }

  return filename;
}

/// Removes edge case extra format patterns as last resort
///
/// Handles edge cases where other strategies might miss truncated patterns.
/// Uses heuristic-based pattern matching for missed truncated suffixes.
String _removeExtraEdgeCase(final String filename) {
  final String? result = extras.removeEdgeCaseExtraFormats(filename);
  if (result != null) {
    log(
      'Truncated suffix detected and removed by edge case handling: $filename -> $result',
    );
    return result;
  }
  return filename;
}

/// Removes digit patterns like "(1)" from filenames
String _removeDigit(final String filename) =>
    filename.replaceAll(RegExp(r'\(\d\)\.'), '.');
