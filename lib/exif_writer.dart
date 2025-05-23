import 'dart:io';

import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:intl/intl.dart';
import 'date_extractors/exif_extractor.dart';
import 'exiftoolInterface.dart';
import 'utils.dart';

Future<bool> writeDateTimeToExif(
  final DateTime dateTime,
  final File file,
) async {
  //Check if the file already has a dateTime in its EXIF data. If function returns a DateTime, there is no necessity toi write it. Skip.
  if (await exifDateTimeExtractor(file) != null) {
    return false;
  }

  final exifFormat = DateFormat('yyyy:MM:dd HH:mm:ss');
  final String dt = exifFormat.format(dateTime);
  final success = await exiftool!.writeExifBatch(file, {
    'DateTimeOriginal': '"$dt"',
    'DateTimeDigitized': '"$dt"',
    'DateTime': '"$dt"',
  });
  if (success) {
    log('[Step 5/8] New DateTime written $dt to EXIF (exiftool): ${file.path}');
    return true;
  } else {
    log(
      '[Step 5/8] DateTime could not be written to EXIF: ${file.path}',
      level: 'error',
    );
    return false;
  }
}

Future<bool> writeGpsToExif(
  final DMSCoordinates coordinates,
  final File file,
) async {
  //Check if the file already has EXIF data and if yes, skip.
  final Map coordinatesMap = await exiftool!.readExifBatch(file, [
    'GPSLatitude',
    'GPSLongitude',
  ]);
  final bool filehasExifCoordinates = coordinatesMap.values.isNotEmpty;
  if (!filehasExifCoordinates) {
    log(
      '[Step 5/8] Found coordinates in json, but missing in EXIF for file: ${file.path}',
    );

    final success = await exiftool!.writeExifBatch(file, {
      'GPSLatitude': coordinates.toDD().latitude.toString(),
      'GPSLongitude': coordinates.toDD().longitude.toString(),
      'GPSLatitudeRef': coordinates.latDirection.abbreviation.toString(),
      'GPSLongitudeRef': coordinates.longDirection.abbreviation.toString(),
    });
    if (success) {
      log('[Step 5/8] New coordinates written to EXIF: ${file.path}');
      return true;
    } else {
      log(
        '[Step 5/8] Coordinates could not be written to EXIF: ${file.path}',
        level: 'error',
      );
      return false;
    }
  }
  //Found coords in json but already present in exif. Skip.
  return false;
}
