import '../../infrastructure/exiftool_service.dart';
import 'global_config_service.dart';

/// Service container for dependency injection
///
/// Manages the lifecycle of all application services and provides
/// centralized configuration and initialization.
class ServiceContainer {
  ServiceContainer._();

  late final GlobalConfigService globalConfig;
  ExifToolService? exifTool;

  static ServiceContainer? _instance;

  /// Get the singleton service container
  static ServiceContainer get instance {
    _instance ??= ServiceContainer._();
    return _instance!;
  }

  /// Initialize all services
  Future<void> initialize() async {
    // Initialize global config service
    globalConfig = GlobalConfigService();

    // Try to find and initialize ExifTool
    exifTool = await ExifToolService.find();
    if (exifTool != null) {
      await exifTool!.startPersistentProcess();
    }
  }

  /// Dispose of all services and cleanup resources
  Future<void> dispose() async {
    if (exifTool != null) {
      await exifTool!.dispose();
      exifTool = null;
    }
  }

  /// Reset the service container (primarily for testing)
  static Future<void> reset() async {
    await _instance?.dispose();
    _instance = null;
  }
}
