import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;
import 'package:exif_reader/exif_reader.dart';
import 'package:ffmpeg_cli/ffmpeg_cli.dart';
import 'package:mime/mime.dart';
import '../utils.dart';

/// DateTime from exif data *potentially* hidden within a [file]
///
/// You can try this with *any* file, it either works or not 🤷
Future<DateTime?> exifDateTimeExtractor(final File file) async {
  // if file is not image or >32MiB - DO NOT crash :D https://github.com/brendan-duncan/image/issues/457#issue-1549020643 TODO: Fix this in the future
  if (!(lookupMimeType(file.path)?.startsWith('image/') ?? false) ||
      await file.length() > maxFileSize) {
    //Getting CreationDateTime of video files through ffprobe https://flutter-bounty-hunters.github.io/ffmpeg_cli/
    if (lookupMimeType(file.path)?.startsWith('video/') ?? false) {
      //running ffprobe
      FfprobeResult? ffprobeResult;
      try {
        ffprobeResult = await Ffprobe.run(file.path);
      } catch (e) {
        log(
          '[Step 4/8] [Error] Extracting DateTimeCreated EXIF value with ffprobe failed. Is ffprobe present locally and in \$PATH variable? Error: ${e.toString()}',
        );
        return null;
      }
      final String? videoCreationString =
          ffprobeResult.format?.tags?.creationTime;
      if (videoCreationString != null) {
        final DateTime videoCreationDateTime = DateTime.parse(
          videoCreationString,
        );
        log(
          '[Step 4/8] Extracted DateTime from EXIF through ffprobe for ${file.path}',
        );
        return videoCreationDateTime;
      }
    }
    return null;
  }
  final Map<String, IfdTag> tags = await readExifFromFile(file);
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
      .substring(0, math.min(datetime.length, 19))
      .replaceFirst(':', '-') // replace two : year/month to comply with iso
      .replaceFirst(':', '-');
  // now date is like: "1999-06-23 23:55"
  return DateTime.tryParse(datetime);
}
