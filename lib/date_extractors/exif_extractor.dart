import 'dart:io';
import 'dart:math' as math;

import 'package:mime/mime.dart';

import '../exiftoolInterface.dart';
import '../utils.dart';

/// DateTime from exif data *potentially* hidden within a [file]
///
/// You can try this with *any* file, it either works or not 🤷
/// You should only use this function after checking wherePhotoVideo() on the File(s) for performance reasons.
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
        log('[Step 4/8] Sucessfully extracted DateTime from EXIF for ${file.path}');
        return parsedDateTime;
      }
    } catch (e) {
      log('[Step 4/8] exiftool read failed: ${e.toString()}', level: 'error');
      return null;
    }
  }
  return null;
}
