/// ExifTool interface - Direct use of infrastructure service
///
/// This file provides a clean interface to the ExifTool infrastructure service
library;

import 'dart:io';

import '../domain/services/service_container.dart';
import 'exiftool_service.dart';

// Re-export for convenience
export 'exiftool_service.dart';

/// Global ExifTool service instance
ExifToolService? exiftool;

/// Initialize ExifTool service
///
/// Attempts to find and initialize exiftool, updating the global config
/// accordingly. Also starts the persistent process for improved performance.
///
/// Returns true if exiftool was found and initialized successfully
Future<bool> initExiftool() async {
  exiftool = ServiceContainer.instance.exifTool;
  return exiftool != null;
}

/// Cleanup function to stop the persistent ExifTool process
/// Should be called when the application is shutting down
Future<void> cleanupExiftool() async {
  await ServiceContainer.instance.dispose();
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

  /// Stop persistent process
  Future<void> stopPersistentProcess() async {
    await _service.dispose();
  }

  /// Read metadata from file
  Future<Map<String, dynamic>> readMetadata(final File file) async =>
      _service.readExifData(file);

  /// Write metadata to file
  Future<void> writeMetadata(
    final File file,
    final Map<String, String> metadata,
  ) async {
    await _service.writeExifData(file, metadata);
  }

  /// Execute ExifTool command
  Future<String> executeCommand(final List<String> args) async =>
      _service.executeCommand(args);
}
