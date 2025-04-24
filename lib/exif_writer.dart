import 'dart:io';
import 'package:mime/mime.dart';
import 'package:coordinate_converter/coordinate_converter.dart';
import 'package:image/image.dart';
import 'package:intl/intl.dart';

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

bool writeDateTimeToExif(DateTime dateTime, File file) {
  if (isSupportedToWriteToExif(file)) {
    //Check if the file format supports writing to exif
    Image? image;
    try {
      image = decodeNamedImage(
          file.path, file.readAsBytesSync()); //Decode the image
    } catch (e) {
      return false; // Ignoring errors during image decoding as it may not be a valid image file
    }
    if (image != null && image.hasExif) {
      final exifFormat = DateFormat("yyyy:MM:dd HH:mm:ss");
      image.exif.imageIfd['DateTime'] = exifFormat.format(dateTime);
      image.exif.exifIfd['DateTimeOriginal'] = exifFormat.format(dateTime);
      image.exif.exifIfd['DateTimeDigitized'] = exifFormat.format(dateTime);
      final newbytes = encodeNamedImage(file.path,
          image); //This overwrites the original file with the new Exif data. TODO: This whole thing is too slow and not sufficiently tested.  Code needs to be optimized.
          if (newbytes != null) {
        file.writeAsBytesSync(newbytes);
        return true;
      } else {
        return false; // Failed to encode image while writing DateTime.
      }
    }
      return false;
  }
  return false;
}

bool writeGpsToExif(DMSCoordinates coordinates, File file) {
  //Check if the file format supports writing to exif
  Image? image;
  try {
    image =
        decodeNamedImage(file.path, file.readAsBytesSync()); //Decode the image
  } catch (e) {
    return false; // Ignoring errors during image decoding as it may not be a valid image file
  }
  if (image!.hasExif) {
    image.exif.gpsIfd.gpsLatitude = coordinates.latSeconds;
    image.exif.gpsIfd.gpsLongitude = coordinates.longSeconds;
    image.exif.gpsIfd.gpsLatitudeRef = coordinates.latDirection.abbreviation;
    image.exif.gpsIfd.gpsLongitudeRef = coordinates.longDirection.abbreviation;
    final newbytes = encodeNamedImage(file.path,
        image); //This overwrites the original file with the new Exif data. TODO: This whole thing is too slow and not sufficiently tested.  Code needs to be optimized.
    if (newbytes != null) {
      file.writeAsBytesSync(newbytes);
    } else {
      return false;
    }
  }
  return false;
}
