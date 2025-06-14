import '../../infrastructure/consolidated_disk_space_service.dart';
import '../../infrastructure/exiftool_service.dart';
import 'consolidated_interactive_service.dart';
import 'consolidated_utility_service.dart';
import 'global_config_service.dart';

/// Service container for dependency injection
///
/// Manages the lifecycle of all application services and provides
/// centralized configuration and initialization.
class ServiceContainer {
  ServiceContainer._();

  late final GlobalConfigService globalConfig;
  late final ConsolidatedUtilityService utilityService;
  late final ConsolidatedDiskSpaceService diskSpaceService;
  late final ConsolidatedInteractiveService interactiveService;
  ExifToolService? exifTool;

  static ServiceContainer? _instance;

  /// Get the singleton service container
  static ServiceContainer get instance {
    _instance ??= ServiceContainer._();
    return _instance!;
  }

  /// Initialize all services
  Future<void> initialize() async {
    // Initialize core services
    globalConfig = GlobalConfigService();
    utilityService = const ConsolidatedUtilityService();
    diskSpaceService = ConsolidatedDiskSpaceService();

    // Initialize interactive service with dependencies
    interactiveService = ConsolidatedInteractiveService(
      globalConfig: globalConfig,
    ); // Try to find and initialize ExifTool
    exifTool = await ExifToolService.find();
    if (exifTool != null) {
      await exifTool!.startPersistentProcess();
      globalConfig.exifToolInstalled = true;
    } else {
      globalConfig.exifToolInstalled = false;
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
