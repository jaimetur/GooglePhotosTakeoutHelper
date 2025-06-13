// ignore_for_file: file_names

/// ExifTool interface - Direct use of infrastructure service
///
/// This file provides a clean interface to the ExifTool infrastructure service
library;

import 'dart:io';

import 'infrastructure/exiftool_service.dart';

// Re-export for convenience
export 'infrastructure/exiftool_service.dart';

/// Global ExifTool service instance
ExifToolService? exiftool;

/// Initialize ExifTool service
///
/// Attempts to find and initialize exiftool, updating the global config
/// accordingly. Also starts the persistent process for improved performance.
///
/// Returns true if exiftool was found and initialized successfully
Future<bool> initExiftool() async {
  exiftool = await ExifToolService.initialize();
  return exiftool != null;
}

/// Cleanup function to stop the persistent ExifTool process
/// Should be called when the application is shutting down
Future<void> cleanupExiftool() async {
  await ExifToolService.cleanup();
  exiftool = null;
}

/// ExifTool interface class - simplified to direct service usage
class ExiftoolInterface {
  ExiftoolInterface._(this._service);

  final ExifToolService _service;

  /// Find and create ExifTool interface
  static Future<ExiftoolInterface?> find() async {
    final service = await ExifToolService.find();
    return service != null ? ExiftoolInterface._(service) : null;
  }

  /// Start persistent process for better performance
  Future<void> startPersistentProcess() async {
    await _service.startPersistentProcess();
  }

  /// Read EXIF data from file
  Future<Map<String, dynamic>> readExif(final File file) async =>
      _service.readExifData(file);

  /// Write EXIF data to file
  Future<void> writeExif(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    await _service.writeExifData(file, exifData);
  }

  /// Dispose of resources
  Future<void> dispose() async {
    await _service.dispose();
  }
}
