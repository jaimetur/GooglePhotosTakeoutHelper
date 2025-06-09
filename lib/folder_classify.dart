/// This file contains utils for determining type of a folder
/// Whether it's a legendary "year folder", album, trash, etc
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'utils.dart';

/// Determines if a directory is a Google Photos year folder
///
/// Checks if the folder name matches the pattern "Photos from YYYY" where YYYY is a year from 1800 to 2099.
/// This is a strict match and does not cover all possible year folder naming conventions.
///
/// [dir] Directory to check
/// Returns true if it's a year folder
bool isYearFolder(final Directory dir) =>
    RegExp(r'^Photos from (20|19|18)\d{2}$').hasMatch(p.basename(dir.path));

/// Determines if a directory is an album folder
///
/// An album folder is one that contains at least one media file
/// (photo or video). Uses the wherePhotoVideo extension to check
/// for supported media formats.
///
/// [dir] Directory to check
/// Returns true if it's an album folder
Future<bool> isAlbumFolder(final Directory dir) async {
  try {
    await for (final entity in dir.list()) {
      if (entity is File) {
        // Check if it's a media file using the existing extension
        final mediaFiles = [entity].wherePhotoVideo();
        if (mediaFiles.isNotEmpty) {
          return true;
        }
      }
    }
    return false;
  } catch (e) {
    // Handle permission denied or other errors
    return false;
  }
}
