import 'dart:io';
import 'package:mime/mime.dart';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';

void writeDateTimeToExif(DateTime dateTime, File file) async {
  if (isSupportedToWriteToExif(file)) {
    //Check if the file format supports writing to exif//Find the decoder for the image format
    Image? image = await decodeImageFile(file.path); //Decode the image
    if (image!.hasExif) {
      final exifFormat = DateFormat("yyyy:MM:dd HH:mm:ss");
      image.exif.imageIfd['DateTime'] = exifFormat.format(dateTime);
      image.exif.exifIfd['DateTimeOriginal'] = exifFormat.format(dateTime);
      image.exif.exifIfd['DateTimeDigitized'] = exifFormat.format(dateTime);
      await encodeImageFile(file.path,
          image); //This overwrites the original file with the new Exif data. TODO: Check if this changes last modified
    }
  }
}

void writeGpsToExif(DMSCoordinates coordinates, File file) async {
  //Check if the file format supports writing to exif
  if (isSupportedToWriteToExif(file)) {
    Image? image = await decodeImageFile(file.path); //Decode the image
    if (image!.hasExif) {
      image.exif.gpsIfd.gpsLatitude = coordinates.latSeconds;
      image.exif.gpsIfd.gpsLongitude = coordinates.longSeconds;
      image.exif.gpsIfd.gpsLatitudeRef = coordinates.latDirection.toString();
      image.exif.gpsIfd.gpsLongitudeRef = coordinates.longDirection.toString();
      await encodeImageFile(file.path,
          image); //This overwrites the original file with the new Exif data. TODO: Check if this changes last modified
    }
  }
}

//Check if it is a supported file format by the Image library to write to EXIF.
//Currently supported formats are: JPG, PNG/Animated APNG, GIF/Animated GIF, BMP, TIFF, TGA, PVR, ICO (Image 4.5.4)
bool isSupportedToWriteToExif(File file) {
  String? mimetype = lookupMimeType(file.path);
  if (mimetype != null) {
    String? extension = extensionFromMime(mimetype);

    switch (extension) {
      case 'jpg':
        return true;
      case 'jpeg':
        return true;
      case 'png':
        return true;
      case 'gif':
        return true;
      case 'bmp':
        return true;
      case 'tiff':
        return true;
      case 'tga':
        return true;
      case 'pvr':
        return true;
      case 'ico':
        return true;
      default:
        return false;
    }
  }
  return false;
}
