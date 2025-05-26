import 'dart:io';
import 'package:path/path.dart' as p;

import 'utils.dart';

/// Internal helper function to check if a single text component contains emoji characters.
///
/// [text] The text string to check for emoji characters
/// Returns true if the text contains any emoji (including BMP and surrogate pairs)
bool _hasUnicodeSurrogatesInText(final String text) {
  // This regex matches emoji characters more precisely
  final emojiRegex = RegExp(
    r'[\u{1F300}-\u{1F9FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F000}-\u{1FAFF}]|[\u{1F600}-\u{1F64F}]|[\u{2122}\u{2139}\u{2194}-\u{2199}\u{21A9}-\u{21AA}\u{231A}-\u{231B}\u{2328}\u{23CF}\u{23E9}-\u{23F3}\u{23F8}-\u{23FA}\u{24C2}\u{25AA}-\u{25AB}\u{25B6}\u{25C0}\u{25FB}-\u{25FE}\u{2600}-\u{2604}\u{260E}\u{2611}\u{2614}-\u{2615}\u{2618}\u{261D}\u{2620}\u{2622}-\u{2623}\u{2626}\u{262A}\u{262E}-\u{262F}\u{2638}-\u{263A}\u{2640}\u{2642}\u{2648}-\u{2653}\u{265F}-\u{2660}\u{2663}\u{2665}-\u{2666}\u{2668}\u{267B}\u{267E}-\u{267F}\u{2692}-\u{2697}\u{2699}\u{269B}-\u{269C}\u{26A0}-\u{26A1}\u{26AA}-\u{26AB}\u{26B0}-\u{26B1}\u{26BD}-\u{26BE}\u{26C4}-\u{26C5}\u{26C8}\u{26CE}-\u{26CF}\u{26D1}\u{26D3}-\u{26D4}\u{26E9}-\u{26EA}\u{26F0}-\u{26F5}\u{26F7}-\u{26FA}\u{26FD}\u{2702}\u{2705}\u{2708}-\u{270D}\u{270F}]',
    unicode: true,
  );
  return emojiRegex.hasMatch(text);
}

/// Encodes emoji characters in the album directory name to hex representation and renames the folder on disk if needed.
///
/// [albumDir] The Directory whose name may contain emoji characters.
/// Returns the new (possibly hex-encoded) directory.
Directory encodeAndRenameAlbumIfEmoji(final Directory albumDir) {
  final String originalName = p.basename(albumDir.path);
  if (!_hasUnicodeSurrogatesInText(originalName)) {
    return Directory(originalName);
  }

  log('Found an emoji in ${albumDir.path}. Encoding it to hex.');
  final String parentPath = albumDir.parent.path;
  final StringBuffer cleanName = StringBuffer();

  for (int i = 0; i < originalName.length; i++) {
    final int codeUnit = originalName.codeUnitAt(i);
    final String char = String.fromCharCode(codeUnit);

    // Handle surrogate pairs
    if (codeUnit >= 0xD800 &&
        codeUnit <= 0xDBFF &&
        i + 1 < originalName.length) {
      final int nextCodeUnit = originalName.codeUnitAt(i + 1);
      if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
        final int emoji =
            ((codeUnit - 0xD800) << 10) + (nextCodeUnit - 0xDC00) + 0x10000;
        cleanName.write('_0x${emoji.toRadixString(16)}_');
        i++;
        continue;
      }
    }

    // Handle BMP emoji
    if (_hasUnicodeSurrogatesInText(char)) {
      cleanName.write('_0x${codeUnit.toRadixString(16)}_');
    } else {
      cleanName.write(char);
    }
  }

  final String newPath = p.join(parentPath, cleanName.toString());
  if (albumDir.path != newPath) {
    albumDir.renameSync(newPath);
  }
  return Directory(newPath);
}

/// Decodes hex-encoded emoji sequences back to emoji characters.
///
/// [encodedPath] The path with hex-encoded emojis in the last segment.
/// Returns the path with emojis restored, or the original path if no encoding present.
String decodeAndRestoreAlbumEmoji(final String encodedPath) {
  final List<String> parts = encodedPath.split(p.separator);
  if (parts.isEmpty) return encodedPath;

  // Only decode if hex-encoded emoji is present in the last segment
  if (RegExp(r'_0x[0-9a-fA-F]+_').hasMatch(parts.last)) {
    log(
      'Found a hex encoded emoji in $encodedPath. Decoding it back to emoji.',
    );
    parts[parts.length - 1] = _decodeEmojiComponent(parts.last);
    return parts.join(p.separator);
  }
  return encodedPath;
}

/// Internal helper function to decode hex-encoded emoji characters back to UTF-8.
///
/// [component] A string potentially containing hex-encoded emojis
/// Returns the string with all hex-encoded emojis converted back to UTF-8
String _decodeEmojiComponent(final String component) {
  final RegExp emojiPattern = RegExp(r'_0x([0-9a-fA-F]+)_');
  return component.replaceAllMapped(emojiPattern, (final Match match) {
    final int codePoint = int.parse(match.group(1)!, radix: 16);
    return String.fromCharCode(codePoint);
  });
}
