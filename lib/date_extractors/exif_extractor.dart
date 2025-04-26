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
/// You should only use this function after checking wherePhotoVideo() on the File(s) for performance reasons.
Future<DateTime?> exifDateTimeExtractor(final File file) async {
  // if file is not image or >32MiB - DO NOT crash :D https://github.com/brendan-duncan/image/issues/457#issue-1549020643 
  if (!(lookupMimeType(file.path)?.startsWith('image/') ?? false) ||
      await file.length() > maxFileSize) {
    //Getting CreationDateTime of video files through ffprobe https://flutter-bounty-hunters.github.io/ffmpeg_cli/. MTS is handled in a special way because of https://github.com/TheLastGimbus/GooglePhotosTakeoutHelper/issues/223
    if ((lookupMimeType(file.path)?.startsWith('video/') ?? false) || (lookupMimeType(file.path)?.startsWith('model/vnd.mts') ?? false) || 
      await file.length() > maxFileSize) { // FIXME As videos are usually larger, the maxFileSize check is quite limiting. We need to give the user the control (depending on if the script is run on a NAS or on a beefy computer). I suggest not limiting the file size by default but giving the option to set a maxFileSize through a CLI argument. Implemented the check for now to keep support for shitty computers
      //running ffprobe
      FfprobeResult? ffprobeResult;
      try {
        ffprobeResult = await Ffprobe.run(file.path);
      } catch (e) {
        log(
          '[Step 4/8] [Error] Extracting DateTimeCreated EXIF value with ffprobe failed. Is ffprobe present locally and in \$PATH variable? Error: ${e.toString()}'
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
          '[Step 4/8] [Info] Extracted DateTime from EXIF through ffprobe for ${file.path}',
        );
        return videoCreationDateTime;
      }
    }
    print(
      '[Step 4/8] [Error] MimeType ${lookupMimeType(file.path)} is not an image but also no supported video file format or larger than the maximum file size of ${maxFileSize.toString()} bytes. Please create an issue if you encounter this error, as we should handle whatever you got there. This happened for file: ${file.path}', //Satisfies wherePhotoVideo() but is not image/ or video/ mime type. //TODO rewrite when maxFileSize is exposed as arg
    );
    return null; //if it's not an image or video.
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
