import 'dart:io';
import 'dart:math';

import 'package:exif/exif.dart';
import 'package:gpth/utils.dart';
import 'package:mime/mime.dart';

/// DateTime from exif data *potentially* hidden within a [file]
///
/// You can try this with *any* file, it either works or not 🤷
Future<DateTime?> exifDateTimeExtractor(File file) async {
  // if file is not image or >32MiB - DO NOT crash :D https://github.com/brendan-duncan/image/issues/457#issue-1549020643 TODO: Fix this in the future
  if (!(lookupMimeType(file.path)?.startsWith('image/') ?? false) ||
      await file.length() > maxFileSize) {
    return null;
  }
  final tags = await readExifFromFile(file);
  String? datetime;
  // try if any of these exists
  datetime ??= tags['Image DateTime']?.printable;
  datetime ??= tags['EXIF DateTimeOriginal']?.printable;
  datetime ??= tags['EXIF DateTimeDigitized']?.printable;
  if (datetime == null) return null;
  // replace all shitty separators that are sometimes met
  datetime = datetime
      .replaceAll('-', ':')
      .replaceAll('/', ':')
      .replaceAll('.', ':')
      .replaceAll('\\', ':')
      .replaceAll(': ', ':0')
      .substring(0, min(datetime.length, 19))
      .replaceFirst(':', '-') // replace two : year/month to comply with iso
      .replaceFirst(':', '-');
  // now date is like: "1999-06-23 23:55"
  return DateTime.tryParse(datetime);
}
