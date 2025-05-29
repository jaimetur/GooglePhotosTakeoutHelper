/// This file contains utils for determining type of a folder
/// Whether it's a legendary "year folder", album, trash, etc
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'utils.dart';

/// Determines if a directory is a Google Photos year folder
///
/// Checks if the folder name matches the pattern "Photos from YYYY"
/// where YYYY is a year from 1800-2099.
///
/// [dir] Directory to check
/// Returns true if it's a year folder
bool isYearFolder(final Directory dir) =>
    RegExp(r'^Photos from (20|19|18)\d{2}$').hasMatch(p.basename(dir.path));

/// Determines if a directory is an album folder
///
/// An album folder is one that exists alongside year folders in the same
/// parent directory structure.
///
/// [dir] Directory to check
/// Returns true if it's an album folder
Future<bool> isAlbumFolder(final Directory dir) =>
    dir.parent.list().whereType<Directory>().any(isYearFolder);
