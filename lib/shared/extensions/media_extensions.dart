import 'dart:io';
import '../../domain/services/file_system_service.dart';

/// Extensions for filtering file system entities by media type
///
/// Extracted from utils.dart to provide clean, reusable extensions
/// for working with photo and video files throughout the application.
extension MediaFilterExtensions on Iterable<FileSystemEntity> {
  /// Easy extension allowing you to filter for files that are photo or video
  ///
  /// Filters the iterable to only include File objects that are identified
  /// as photos or videos based on MIME type and file extension.
  Iterable<File> wherePhotoVideo() {
    const fileSystemService = FileSystemService();
    return whereType<File>().where(fileSystemService.isPhotoOrVideo);
  }
}

extension MediaFilterStreamExtensions on Stream<FileSystemEntity> {
  /// Easy extension allowing you to filter for files that are photo or video
  ///
  /// Filters the stream to only include File objects that are identified
  /// as photos or videos based on MIME type and file extension.
  Stream<File> wherePhotoVideo() {
    const fileSystemService = FileSystemService();
    return whereType<File>().where(fileSystemService.isPhotoOrVideo);
  }
}

/// Utility extension for type filtering in streams
extension StreamTypeExtensions on Stream {
  /// Filters stream elements to only include instances of type T
  Stream<T> whereType<T>() => where((final e) => e is T).cast<T>();
}
