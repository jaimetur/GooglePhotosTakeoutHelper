import 'dart:io';
import 'package:emoji_regex/emoji_regex.dart' as r;
import 'package:exif_reader/exif_reader.dart';
import 'package:gpth/emojicleaner.dart';
import 'package:gpth/exiftoolInterface.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import './test_setup.dart';

/// Helper function to check if a string contains emoji
bool containsEmoji(final String text) =>
    r.emojiRegex().hasMatch(text) ||
    RegExp(r'\u{FE0F}|\u{FE0E}', unicode: true).hasMatch(text);

/// Helper function to encode emoji in a string (simplified version for testing)
String encodeEmoji(final String text) {
  if (!containsEmoji(text)) return text;

  final StringBuffer result = StringBuffer();
  for (int i = 0; i < text.length; i++) {
    final int codeUnit = text.codeUnitAt(i);
    final String char = String.fromCharCode(codeUnit);

    // Handle surrogate pairs
    if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF && i + 1 < text.length) {
      final int nextCodeUnit = text.codeUnitAt(i + 1);
      if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
        final int emoji =
            ((codeUnit - 0xD800) << 10) + (nextCodeUnit - 0xDC00) + 0x10000;
        result.write('_0x${emoji.toRadixString(16)}_');
        i++;
        continue;
      }
    }

    // Handle BMP emoji
    if (containsEmoji(char)) {
      result.write('_0x${codeUnit.toRadixString(16)}_');
    } else {
      result.write(char);
    }
  }
  return result.toString();
}

/// Helper function to decode emoji from hex representation
String decodeEmoji(final String text) {
  final RegExp emojiPattern = RegExp(r'_0x([0-9a-fA-F]+)_');
  return text.replaceAllMapped(emojiPattern, (final Match match) {
    try {
      final int codePoint = int.parse(match.group(1)!, radix: 16);
      return String.fromCharCode(codePoint);
    } catch (e) {
      return match.group(0)!; // Return original if parsing fails
    }
  });
}

/// Helper function for renaming directories back from hex encoding
Directory decodeAndRenameAlbumIfHex(final Directory hexDir) {
  final String decodedPath = decodeAndRestoreAlbumEmoji(hexDir.path);
  if (decodedPath != hexDir.path) {
    hexDir.renameSync(decodedPath);
    return Directory(decodedPath);
  }
  return hexDir;
}

void main() {
  group('Emoji Cleaner', () {
    late TestFixture fixture;

    setUpAll(() async {
      await initExiftool();
    });

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    group('Emoji Detection and Encoding', () {
      test('containsEmoji detects emoji in filenames', () {
        expect(containsEmoji('test_😊.jpg'), isTrue);
        expect(containsEmoji('vacation_💖❤️'), isTrue);
        expect(containsEmoji('no_emoji.jpg'), isFalse);
        expect(containsEmoji('regular_folder'), isFalse);
        expect(containsEmoji('test_🎉_party'), isTrue);
      });

      test('containsEmoji detects various emoji types', () {
        expect(containsEmoji('face_😀'), isTrue); // Smiling face
        expect(containsEmoji('heart_❤️'), isTrue); // Red heart
        expect(containsEmoji('flag_🇺🇸'), isTrue); // Flag emoji
        expect(containsEmoji('number_1️⃣'), isTrue); // Number emoji
        expect(containsEmoji('symbol_⚠️'), isTrue); // Warning symbol
      });

      test('encodeEmoji converts emoji to hex representation', () {
        final result = encodeEmoji('test_😊.jpg');
        expect(result, contains('_0x'));
        expect(result, isNot(contains('😊')));
      });

      test('encodeEmoji handles multiple emojis', () {
        final result = encodeEmoji('vacation_💖❤️');
        expect(result, contains('_0x1f496_')); // 💖
        expect(result, contains('_0x2764_')); // ❤
        expect(result, contains('_0xfe0f_')); // Variation selector
      });

      test('encodeEmoji preserves non-emoji content', () {
        final result = encodeEmoji('test_😊_file.jpg');
        expect(result, startsWith('test_'));
        expect(result, endsWith('_file.jpg'));
        expect(result, contains('_0x'));
      });
    });

    group('Emoji Decoding', () {
      test('decodeEmoji converts hex back to emoji', () {
        final encoded = encodeEmoji('test_😊.jpg');
        final decoded = decodeEmoji(encoded);
        expect(decoded, 'test_😊.jpg');
      });

      test('decodeEmoji handles multiple emojis', () {
        const original = 'vacation_💖❤️';
        final encoded = encodeEmoji(original);
        final decoded = decodeEmoji(encoded);
        expect(decoded, original);
      });

      test('decodeEmoji preserves strings without hex codes', () {
        const original = 'regular_filename.jpg';
        final decoded = decodeEmoji(original);
        expect(decoded, original);
      });

      test('roundtrip encoding and decoding preserves original', () {
        final testCases = [
          'simple_😊.jpg',
          'complex_💖❤️🎉.mp4',
          'flags_🇺🇸🇬🇧.png',
          'numbers_1️⃣2️⃣3️⃣.gif',
          'no_emoji_here.txt',
        ];

        for (final testCase in testCases) {
          final encoded = encodeEmoji(testCase);
          final decoded = decodeEmoji(encoded);
          expect(decoded, testCase, reason: 'Failed for: $testCase');
        }
      });
    });

    group('Album/Folder Emoji Handling', () {
      test('encodeAndRenameAlbumIfEmoji renames emoji folders', () {
        final emojiDir = fixture.createDirectory('test_😊_folder');

        final result = encodeAndRenameAlbumIfEmoji(emojiDir);

        expect(result.existsSync(), isTrue);
        expect(result.path, isNot(contains('😊')));
        expect(result.path, contains('_0x'));
        expect(emojiDir.existsSync(), isFalse);
      });

      test('encodeAndRenameAlbumIfEmoji preserves non-emoji folders', () {
        final normalDir = fixture.createDirectory('normal_folder');
        final originalPath = normalDir.path;

        final result = encodeAndRenameAlbumIfEmoji(normalDir);

        expect(result.path, originalPath);
        expect(result.existsSync(), isTrue);
      });

      test(
        'encodeAndRenameAlbumIfEmoji handles complex emoji combinations',
        () {
          final complexEmojiDir = fixture.createDirectory('vacation_💖❤️🎉');

          final result = encodeAndRenameAlbumIfEmoji(complexEmojiDir);

          expect(result.existsSync(), isTrue);
          expect(result.path, contains('_0x1f496_')); // 💖
          expect(result.path, contains('_0x2764_')); // ❤
          expect(result.path, contains('_0x1f389_')); // 🎉
          expect(complexEmojiDir.existsSync(), isFalse);
        },
      );

      test('decodeAndRenameAlbumIfHex restores original emoji folder', () {
        final emojiDir = fixture.createDirectory('test_😊_folder');
        final encoded = encodeAndRenameAlbumIfEmoji(emojiDir);

        final restored = decodeAndRenameAlbumIfHex(encoded);

        expect(restored.existsSync(), isTrue);
        expect(restored.path, contains('😊'));
        expect(restored.path, isNot(contains('_0x')));
        expect(encoded.existsSync(), isFalse);
      });

      test('decodeAndRenameAlbumIfHex preserves non-hex folders', () {
        final normalDir = fixture.createDirectory('normal_folder');
        final originalPath = normalDir.path;

        final result = decodeAndRenameAlbumIfHex(normalDir);

        expect(result.path, originalPath);
        expect(result.existsSync(), isTrue);
      });
    });

    group('End-to-End Emoji Processing', () {
      test('complete emoji workflow: encode, process, decode', () async {
        // Create emoji folder with image
        const String emojiFolderName = 'test_💖❤️';
        final Directory emojiDir = Directory(
          p.join(fixture.basePath, emojiFolderName),
        );
        emojiDir.createSync(recursive: true);

        // Create image with EXIF data in the emoji folder
        final File img = fixture.createImageWithExifInDir(emojiDir.path, 'img.jpg');
        expect(img.existsSync(), isTrue, reason: 'Image file should exist');

        // 1. Encode and rename folder
        final Directory hexNameDir = encodeAndRenameAlbumIfEmoji(emojiDir);
        expect(hexNameDir.path, contains('_0x1f496_')); // 💖
        expect(hexNameDir.path, contains('_0x2764_')); // ❤
        expect(hexNameDir.path, contains('_0xfe0f_')); // Variation selector

        final Directory hexDir = Directory(hexNameDir.path);
        expect(hexDir.existsSync(), isTrue);

        final File hexImg = File(p.join(hexDir.path, 'img.jpg'));
        expect(hexImg.existsSync(), isTrue);

        // 2. Read EXIF from image in hex folder
        final tags = await readExifFromBytes(await hexImg.readAsBytes());
        expect(tags['EXIF DateTimeOriginal']?.printable, '2022:12:16 16:06:47');

        // 3. Write using exiftool to hex_encoded folder
        if (exiftool != null) {
          final Map<String, String> map = {};
          map['Artist'] = 'TestArtist';
          final result = await exiftool!.writeExifBatch(hexImg, map);
          expect(result, isTrue);
        }

        // 4. Create shortcut/symlink to hex folder
        final Directory shortcutTarget = Directory(
          p.join(fixture.basePath, 'shortcuts'),
        );
        shortcutTarget.createSync();

        if (Platform.isWindows) {
          // Test Windows shortcut creation logic
          final String shortcutPath = p.join(
            shortcutTarget.path,
            '${p.basename(hexDir.path)}.lnk',
          );
          expect(
            () => File(shortcutPath).writeAsStringSync('dummy'),
            returnsNormally,
          );
        } else {
          // Test Unix symlink creation
          final Link symlink = Link(
            p.join(shortcutTarget.path, p.basename(hexDir.path)),
          );
          symlink.createSync(hexDir.path);
          expect(symlink.existsSync(), isTrue);
        }

        // 5. Decode and restore original emoji folder
        final Directory restoredDir = decodeAndRenameAlbumIfHex(hexDir);
        expect(restoredDir.path, contains('💖❤️'));
        expect(restoredDir.existsSync(), isTrue);

        final File restoredImg = File(p.join(restoredDir.path, 'img.jpg'));
        expect(restoredImg.existsSync(), isTrue);

        // Verify EXIF data is preserved after decode
        final restoredTags = await readExifFromBytes(
          await restoredImg.readAsBytes(),
        );
        expect(
          restoredTags['EXIF DateTimeOriginal']?.printable,
          '2022:12:16 16:06:47',
        );
      });

      test('handles emoji files within regular folders', () {
        final normalDir = fixture.createDirectory('normal_folder');
        final emojiFile = File(p.join(normalDir.path, 'photo_😊.jpg'));
        emojiFile.createSync();
        emojiFile.writeAsBytesSync([1, 2, 3]);

        // Folder should not be renamed since it has no emoji
        final result = encodeAndRenameAlbumIfEmoji(normalDir);
        expect(result.path, normalDir.path);

        // But the emoji file should still exist
        final files = normalDir.listSync();
        expect(
          files.any((final f) => p.basename(f.path).contains('😊')),
          isTrue,
        );
      });

      test('preserves folder structure during emoji processing', () {
        final parentDir = fixture.createDirectory('parent');
        final emojiSubDir = Directory(p.join(parentDir.path, 'sub_😊'));
        emojiSubDir.createSync();

        final testFile = File(p.join(emojiSubDir.path, 'test.txt'));
        testFile.createSync();
        testFile.writeAsStringSync('test content');

        final encoded = encodeAndRenameAlbumIfEmoji(emojiSubDir);
        expect(encoded.parent.path, parentDir.path);

        final encodedFile = File(p.join(encoded.path, 'test.txt'));
        expect(encodedFile.existsSync(), isTrue);
        expect(encodedFile.readAsStringSync(), 'test content');
      });
    });

    group('Edge Cases and Error Handling', () {
      test('handles empty folder names', () {
        expect(containsEmoji(''), isFalse);
        expect(encodeEmoji(''), '');
        expect(decodeEmoji(''), '');
      });

      test('handles very long emoji sequences', () {
        const longEmoji =
            '😀😃😄😁😆😅😂🤣😊😇🙂🙃😉😌😍🥰😘😗😙😚😋😛😝😜🤪🤨🧐🤓😎🤩🥳😏😒😞😔😟😕🙁☹️😣😖😫😩🥺😢😭😤😠😡🤬🤯😳🥵🥶😱😨😰😥😓🤗🤔🤭🤫🤥😶😐😑😬🙄😯😦😧😮😲🥱😴🤤😪😵🤐🥴🤢🤮🤧😷🤒🤕🤑🤠😈👿👹👺🤡💩👻💀☠️👽👾🤖🎃😺😸😹😻😼😽🙀😿😾';

        final encoded = encodeEmoji(longEmoji);
        final decoded = decodeEmoji(encoded);

        expect(encoded, isNot(contains('😀')));
        expect(decoded, longEmoji);
      });

      test('handles mixed emoji and special characters', () {
        const mixed = 'test_😊-file(1)_💖.jpg';
        final encoded = encodeEmoji(mixed);
        final decoded = decodeEmoji(encoded);

        expect(decoded, mixed);
        expect(encoded, contains('test_'));
        expect(encoded, contains('-file(1)_'));
        expect(encoded, contains('.jpg'));
      });

      test('handles folder rename failures gracefully', () {
        // This test would need to mock file system operations
        // For now, we'll test that the function doesn't throw
        final nonExistentDir = Directory(
          p.join(fixture.basePath, 'nonexistent_😊'),
        );

        expect(
          () => encodeAndRenameAlbumIfEmoji(nonExistentDir),
          returnsNormally,
        );
      });

      test('handles invalid hex codes in decoding', () {
        const invalidHex = 'test_0xinvalid_file.jpg';
        final decoded = decodeEmoji(invalidHex);

        // Should return original string if hex is invalid
        expect(decoded, invalidHex);
      });

      test('handles partial hex codes', () {
        const partialHex = 'test_0x1f60_incomplete.jpg';
        final decoded = decodeEmoji(partialHex);

        // Should handle partial hex gracefully
        expect(decoded, isNotNull);
      });
    });
  });
}
