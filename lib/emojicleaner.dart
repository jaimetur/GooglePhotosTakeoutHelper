import 'dart:io';
import 'package:path/path.dart' as p;

import 'utils.dart';

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

/// Encodes emoji characters in the album (parent) directory name to hex representation and renames the folder on disk if needed.
///
/// [albumDir] The Directory whose name may contain emoji characters.
/// Returns the new (possibly hex-encoded) directory name as a String.
String encodeAndRenameAlbumIfEmoji(final Directory albumDir) {
  final String originalName = p.basename(albumDir.path);
  // Return early if no emoji in the album directory name
  if (!_hasUnicodeSurrogatesInText(originalName)) {
    return originalName;
  }
  log('Found an emoji in ${albumDir.path}. Encoding it to hex.');
  final String parentPath = albumDir.parent.path;
  final StringBuffer cleanName = StringBuffer();
  for (int i = 0; i < originalName.length; i++) {
    final int codeUnit = originalName.codeUnitAt(i);
    if (codeUnit >= 0xD800 &&
        codeUnit <= 0xDBFF &&
        i + 1 < originalName.length) {
      final int nextCodeUnit = originalName.codeUnitAt(i + 1);
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
  final String newPath = p.join(parentPath, cleanName.toString());
  if (albumDir.path != newPath) {
    albumDir.renameSync(newPath);
  }
  return cleanName.toString();
}

/// Decodes hex-encoded emoji sequences (e.g., _0x1f60a_) in the last segment of the path back to emoji characters, only if such encoding is present.
///
/// [encodedPath] The path with hex-encoded emojis in the last segment.
/// Returns the path with emojis restored in the last segment, or the original path if no encoding is present.
String decodeAndRestoreAlbumEmoji(final String encodedPath) {
  final String separator = Platform.pathSeparator;
  final List<String> parts = encodedPath.split(separator);
  if (parts.isEmpty) return encodedPath;
  // Only decode if hex-encoded emoji is present in the last segment
  if (RegExp(r'_0x[0-9a-fA-F]+_').hasMatch(parts.last)) {
    log(
      'Found a hex encoded emoji in $encodedPath. Decoding it back to emoji.',
    );
    parts[parts.length - 1] = _decodeEmojiComponent(parts.last);
    return parts.join(separator);
  }
  return encodedPath;
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
