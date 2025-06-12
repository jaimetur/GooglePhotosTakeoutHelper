import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:path/path.dart' as p;
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import '../extras.dart' as extras;
import '../utils.dart';

/// Finds corresponding json file with info from media file and gets 'photoTakenTime' from it
Future<DateTime?> jsonDateTimeExtractor(
  final File file, {
  final bool tryhard = false,
}) async {
  final File? jsonFile = await jsonForFile(file, tryhard: tryhard);
  if (jsonFile == null) return null;
  try {
    final dynamic data = jsonDecode(await jsonFile.readAsString());
    final int epoch = int.parse(data['photoTakenTime']['timestamp'].toString());
    return DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
  } on FormatException catch (_) {
    // this is when json is bad
    return null;
  } on FileSystemException catch (_) {
    // this happens for issue #143
    // "Failed to decode data using encoding 'utf-8'"
    // maybe this will self-fix when dart itself support more encodings
    return null;
  } on NoSuchMethodError catch (_) {
    // this is when tags like photoTakenTime aren't there
    return null;
  }
}

/// Attempts to find the corresponding JSON file for a media file
///
/// Tries multiple strategies to locate JSON files, including handling
/// filename truncation, bracket swapping, and extra format removal.
/// Strategies are ordered from least to most aggressive (issue #29).
///
/// [file] Media file to find JSON for
/// [tryhard] If true, uses more aggressive matching strategies
/// Returns the JSON file if found, null otherwise
Future<File?> jsonForFile(
  final File file, {
  required final bool tryhard,
}) async {
  final Directory dir = Directory(p.dirname(file.path));
  final String name = p.basename(file.path);

  // Basic strategies (always applied) - ordered from least to most aggressive
  final basicStrategies = <String Function(String s)>[
    // Strategy 1: No modification (most conservative)
    (final String s) => s,

    // Strategy 2: Filename shortening (conservative, addresses filesystem limits)
    _shortenName,

    // Strategy 3: Bracket number swapping (conservative, known pattern)
    _bracketSwap,

    // Strategy 4: Remove file extension (moderate, handles Google's extension addition)
    _noExtension,

    // Strategy 5: Remove known complete extra formats (moderate, safe list)
    _removeExtraComplete,
  ];

  // Aggressive strategies (only with tryhard=true) - ordered from least to most aggressive
  final aggressiveStrategies = <String Function(String s)>[
    // Strategy 6: Remove partial extra formats (moderate to aggressive, truncation handling)
    _removeExtraPartial,

    // Strategy 7: Extension restoration after partial removal (aggressive, reconstruction)
    _removeExtraPartialWithExtensionRestore,

    // Strategy 8: Edge case pattern removal (very aggressive, heuristic-based)
    _removeExtraEdgeCase,

    // Strategy 9: Remove digit patterns (most aggressive, broad pattern matching)
    _removeDigit,
  ];

  // Combine strategies based on tryhard setting
  final allStrategies = [
    ...basicStrategies,
    if (tryhard) ...aggressiveStrategies,
  ];

  // Try each strategy in order of increasing aggressiveness
  for (final String Function(String s) method in allStrategies) {
    final String processedName = method(name);

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

/// Removes file extension from filename
///
/// Handles cases where original file had no extension but Google added one.
///
/// [filename] Original filename
/// Returns filename without extension
String _noExtension(final String filename) =>
    p.basenameWithoutExtension(File(filename).path);

/// Removes digit patterns like "(1)" from filenames
///
/// [filename] Original filename
/// Returns filename with digit patterns removed
String _removeDigit(final String filename) =>
    filename.replaceAll(RegExp(r'\(\d\)\.'), '.');

/// Removes "extra" format suffixes safely using predefined list
///
/// Only removes suffixes from the known safe list in extraFormats.
/// This is the safe, conservative approach that only matches known formats.
/// Handles Unicode normalization for cross-platform compatibility.
///
/// [filename] Original filename
/// Returns filename with extra formats removed
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
///
/// [filename] Original filename
/// Returns filename with partial suffixes removed
String _removeExtraPartial(final String filename) =>
    extras.removePartialExtraFormats(filename);

/// Removes partial extra formats and restores truncated extensions
///
/// Combines partial suffix removal with extension restoration for cases
/// where both the suffix and extension were truncated due to filename limits.
///
/// [filename] Original filename
/// Returns filename with partial suffixes removed and extension restored
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
///
/// [filename] Original filename
/// Returns filename with edge case patterns removed
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

// this resolves years of bugs and head-scratches 😆
// f.e: https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/8#issuecomment-736539592
String _shortenName(final String filename) => '$filename.json'.length > 51
    ? filename.substring(0, 51 - '.json'.length)
    : filename;

// thanks @casualsailo and @denouche for bringing attention!
// https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/188
// and https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/175
/// Handles bracket number swapping in filenames
///
/// Some files have patterns like "image(11).jpg" with JSON "image.jpg(11).json"
/// This function swaps the bracket position to match.
///
/// [filename] Original filename
/// Returns filename with brackets repositioned
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

/// This is to get coordinates from the json file. Expects media file and finds json.
Future<DMSCoordinates?> jsonCoordinatesExtractor(
  final File file, {
  final bool tryhard = false,
}) async {
  final File? jsonFile = await jsonForFile(file, tryhard: tryhard);
  if (jsonFile == null) return null;
  try {
    final Map<String, dynamic> data = jsonDecode(await jsonFile.readAsString());
    final double lat = data['geoData']['latitude'] as double;
    final double long = data['geoData']['longitude'] as double;
    //var alt = double.tryParse(data['geoData']['altitude']); //Info: Altitude is not used.
    if (lat == 0.0 || long == 0.0) {
      return null;
    } else {
      final DDCoordinates ddcoords = DDCoordinates(
        latitude: lat,
        longitude: long,
      );
      final DMSCoordinates dmscoords = DMSCoordinates.fromDD(ddcoords);
      return dmscoords;
    }
  } on FormatException catch (_) {
    // this is when json is bad
    return null;
  } on FileSystemException catch (_) {
    // this happens for issue #143
    // "Failed to decode data using encoding 'utf-8'"
    // maybe this will self-fix when dart itself support more encodings
    return null;
  } on NoSuchMethodError catch (_) {
    // this is when tags like photoTakenTime aren't there
    return null;
  }
}
