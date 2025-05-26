import 'dart:io';

/// Checks if a file path contains emoji characters (Unicode surrogate pairs) in either
/// the immediate parent directory name or the filename.
///
/// [path] The full path to check for emoji characters
/// Returns true if an emoji is found in the parent directory name or filename
bool _hasUnicodeSurrogatesInAlbumNameOrImageName(final String path) {
  final Directory dir = Directory(path).parent;
  final String parentDirName = dir.path.split(Platform.pathSeparator).last;
  final String fileName = path.split(Platform.pathSeparator).last;

  // Only check parent directory name and filename
  return _hasUnicodeSurrogatesInText(parentDirName) ||
      _hasUnicodeSurrogatesInText(fileName);
}

/// Internal helper function to check if a single text component contains emoji characters.
///
/// [text] The text string to check for emoji characters
/// Returns true if the text contains any emoji (Unicode surrogate pairs)
bool _hasUnicodeSurrogatesInText(final String text) {
  for (int i = 0; i < text.length; i++) {
    final int codeUnit = text.codeUnitAt(i);
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
      if (i + 1 < text.length) {
        final int nextCodeUnit = text.codeUnitAt(i + 1);
        if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
          return true;
        }
      }
    }
  }
  return false;
}

/// Encodes emoji characters in filename and immediate parent directory to hex representation
String getEmojiCleanedFilePath(final String path) {
  final Directory dir = Directory(path).parent;
  final String parentDirName = dir.path.split(Platform.pathSeparator).last;
  final String fileName = path.split(Platform.pathSeparator).last;
  final StringBuffer cleanName = StringBuffer();

  // Create a temporary directory for processing
  final String tempBasePath =
      '${dir.parent.path}${Platform.pathSeparator}.temp_exif';
  Directory(tempBasePath).createSync(recursive: true);

  // Process parent directory name if it contains emoji
  final StringBuffer cleanParent = StringBuffer();
  if (_hasUnicodeSurrogatesInText(parentDirName)) {
    for (int i = 0; i < parentDirName.length; i++) {
      final int codeUnit = parentDirName.codeUnitAt(i);
      if (codeUnit >= 0xD800 &&
          codeUnit <= 0xDBFF &&
          i + 1 < parentDirName.length) {
        final int nextCodeUnit = parentDirName.codeUnitAt(i + 1);
        if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
          final int emoji =
              ((codeUnit - 0xD800) << 10) + (nextCodeUnit - 0xDC00) + 0x10000;
          cleanParent.write('_0x${emoji.toRadixString(16)}_');
          i++; // Skip low surrogate
          continue;
        }
      }
      cleanParent.write(String.fromCharCode(codeUnit));
    }
  } else {
    cleanParent.write(parentDirName);
  }

  // Process filename if it contains emoji
  if (_hasUnicodeSurrogatesInText(fileName)) {
    for (int i = 0; i < fileName.length; i++) {
      final int codeUnit = fileName.codeUnitAt(i);
      if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF && i + 1 < fileName.length) {
        final int nextCodeUnit = fileName.codeUnitAt(i + 1);
        if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
          final int emoji =
              ((codeUnit - 0xD800) << 10) + (nextCodeUnit - 0xDC00) + 0x10000;
          cleanName.write('_0x${emoji.toRadixString(16)}_');
          i++; // Skip low surrogate
          continue;
        }
      }
      cleanName.write(String.fromCharCode(codeUnit));
    }
  } else {
    cleanName.write(fileName);
  }

  return '$tempBasePath${Platform.pathSeparator}$cleanParent${Platform.pathSeparator}$cleanName';
}

/// Converts a temporary path with hex-encoded emojis back to the original path with UTF-8 emojis.
///
/// [tempPath] The temporary path containing hex-encoded emojis (e.g., "_0x1f60a_")
/// Returns the original path with proper UTF-8 emoji characters, or the input path if it's not a temp path
String getOriginalPathFromTemp(final String tempPath) {
  final String baseTempDir =
      '${Platform.pathSeparator}.temp_exif${Platform.pathSeparator}';
  if (!tempPath.contains(baseTempDir)) return tempPath;

  final parts = tempPath.split(baseTempDir);
  if (parts.length != 2) return tempPath;

  final String parentDir = parts[0];
  final String remainingPath = parts[1];
  final List<String> components = remainingPath.split(Platform.pathSeparator);
  if (components.length != 2) return tempPath;

  final cleanParent = _decodeEmojiComponent(components[0]);
  final cleanName = _decodeEmojiComponent(components[1]);

  return '$parentDir${Platform.pathSeparator}$cleanParent${Platform.pathSeparator}$cleanName';
}

/// Internal helper function to decode hex-encoded emoji characters back to UTF-8.
///
/// [component] A string potentially containing hex-encoded emojis (e.g., "_0x1f60a_")
/// Returns the string with all hex-encoded emojis converted back to UTF-8 characters
String _decodeEmojiComponent(final String component) {
  final RegExp emojiPattern = RegExp(r'_0x([0-9a-fA-F]+)_');
  return component.replaceAllMapped(emojiPattern, (final Match match) {
    final int codePoint = int.parse(match.group(1)!, radix: 16);
    return String.fromCharCode(codePoint);
  });
}
