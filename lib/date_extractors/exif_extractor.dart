// ignore_for_file: non_constant_identifier_names

import 'dart:io';
import 'dart:math' as math;
import 'package:mime/mime.dart';
import '../exiftoolInterface.dart';
import '../utils.dart';
import 'package:exif_reader/exif_reader.dart';

/// DateTime from exif data *potentially* hidden within a [file]
///
/// You can try this with *any* file, it either works or not 🤷
/// It will either use exiftool if available or the exif_read library
Future<DateTime?> exifDateTimeExtractor(final File file) async {
  //If file is >maxFileSize - return null. https://github.com/brendan-duncan/image/issues/457#issue-1549020643
  if (await file.length() > maxFileSize && enforceMaxFileSize) {
    log(
      '[Step 4/8] The file is larger than the maximum supported file size of ${maxFileSize.toString()} bytes. File: ${file.path}',
      level: 'error',
    );
    return null;
  }

  //Getting mimeType.
  final String? mimeType = lookupMimeType(file.path);

  // Use exiftool if available and file is an image or video
  if (exifToolInstalled &&
      mimeType != null &&
      (mimeType.startsWith('image/') ||
          mimeType.startsWith('video/') ||
          mimeType == 'model/vnd.mts')) {
    return _exifToolExtractor(file);
    // Use dart library exif_reader limited to images if exiftool is not available
  } else if (!exifToolInstalled &&
      mimeType != null &&
      mimeType.startsWith('image/')) {
    return _nativeExif_readerExtractor(file);
  }
  //This logic below is only to give a tailored error message because if you get here, something is wrong.
  if (exifToolInstalled) {
    log(
      "This is a weird file format! Please create an issue if you get this error message, we currently don't hadle it. File type: $mimeType",
      level: 'error',
    );
  } else {
    log(
      '$mimeType skipped. Reading from this file format is only supported with exiftool.',
      level: 'warning',
    );
  }
  return null; //If unsupported
}

///Extracts DateTime from File through ExifTool library
Future<DateTime?> _exifToolExtractor(final File file) async {
  try {
    final tags = await exiftool!.readExif(file);
    String? datetime =
        tags['DateTimeOriginal'] ??
        tags['DateTimeDigitized'] ??
        tags['DateTime'];
    if (datetime == null) {
      return null;
    }
    // Normalize separators and parse
    datetime = datetime
        .replaceAll('-', ':')
        .replaceAll('/', ':')
        .replaceAll('.', ':')
        .replaceAll('\\', ':')
        .replaceAll(': ', ':0')
        .substring(0, math.min(datetime.length, 19))
        .replaceFirst(':', '-')
        .replaceFirst(':', '-');

    final DateTime? parsedDateTime = DateTime.tryParse(datetime);

    if (parsedDateTime == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
      //we keep this for safety for this edge case: https://ffmpeg.org/pipermail/ffmpeg-user/2023-April/056265.html
      log(
        '[Step 4/8] Extracted DateTime before January 1st 1970 from EXIF for ${file.path}. Therefore the DateTime from other extractors is not being changed.',
        level: 'warning',
      );
      return null;
    } else {
      log(
        '[Step 4/8] Sucessfully extracted DateTime from EXIF for ${file.path}',
      );
      return parsedDateTime;
    }
  } catch (e) {
    log('[Step 4/8] exiftool read failed: ${e.toString()}', level: 'error');
    return null;
  }
}

///Extracts DateTime from File through Exif_reader library
Future<DateTime?> _nativeExif_readerExtractor(final File file) async {
  final bytes = await file.readAsBytes();
  // this returns empty {} if file doesn't have exif so don't worry
  final tags = await readExifFromBytes(bytes);
  String? datetime;
  // try if any of these exists
  datetime ??= tags['Image DateTime']?.printable;
  datetime ??= tags['EXIF DateTimeOriginal']?.printable;
  datetime ??= tags['EXIF DateTimeDigitized']?.printable;
  if (datetime == null) return null;
  // Normalize separators and parse
  datetime = datetime
      .replaceAll('-', ':')
      .replaceAll('/', ':')
      .replaceAll('.', ':')
      .replaceAll('\\', ':')
      .replaceAll(': ', ':0')
      .substring(0, math.min(datetime.length, 19))
      .replaceFirst(':', '-')
      .replaceFirst(':', '-');

  final DateTime? parsedDateTime = DateTime.tryParse(datetime);

  if (parsedDateTime == DateTime.parse('2036-01-01T23:59:59.000000Z')) {
    //we keep this for safety for this edge case: https://ffmpeg.org/pipermail/ffmpeg-user/2023-April/056265.html
    log(
      '[Step 4/8] Extracted DateTime before January 1st 1970 from EXIF for ${file.path}. Therefore the DateTime from other extractors is not being changed.',
      level: 'warning',
    );
    return null;
  } else {
    log('[Step 4/8] Sucessfully extracted DateTime from EXIF for ${file.path}');
    return parsedDateTime;
  }
}
