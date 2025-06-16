import '../../../infrastructure/consolidated_disk_space_service.dart';
import '../../../infrastructure/exiftool_service.dart';
import '../media/album_relationship_service.dart';
import '../media/duplicate_detection_service.dart';
import '../user_interaction/user_interaction_service.dart';
import 'formatting_service.dart';
import 'global_config_service.dart';

/// Service container for dependency injection
///
/// Manages the lifecycle of all application services and provides
/// centralized configuration and initialization.
class ServiceContainer {
  ServiceContainer._();
  // Use nullable fields instead of late final to allow re-initialization
  GlobalConfigService? _globalConfig;
  FormattingService? _utilityService;
  ConsolidatedDiskSpaceService? _diskSpaceService;
  ConsolidatedInteractiveService? _interactiveService;
  DuplicateDetectionService? _duplicateDetectionService;
  AlbumRelationshipService? _albumRelationshipService;
  ExifToolService? exifTool;

  bool _isInitialized = false;

  static ServiceContainer? _instance;

  /// Get the singleton service container
  static ServiceContainer get instance {
    _instance ??= ServiceContainer._();
    return _instance!;
  }

  /// Getters with null checks
  GlobalConfigService get globalConfig {
    if (_globalConfig == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _globalConfig!;
  }

  FormattingService get utilityService {
    if (_utilityService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _utilityService!;
  }

  ConsolidatedDiskSpaceService get diskSpaceService {
    if (_diskSpaceService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _diskSpaceService!;
  }

  ConsolidatedInteractiveService get interactiveService {
    if (_interactiveService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _interactiveService!;
  }

  DuplicateDetectionService get duplicateDetectionService {
    if (_duplicateDetectionService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _duplicateDetectionService!;
  }

  AlbumRelationshipService get albumRelationshipService {
    if (_albumRelationshipService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _albumRelationshipService!;
  }

  /// Initialize all services
  Future<void> initialize() async {
    // Prevent concurrent initialization attempts
    if (_isInitialized) {
      return; // Already initialized, no-op
    }

    // Set flag early to prevent race conditions
    _isInitialized = true;

    // Initialize core services first
    _globalConfig = GlobalConfigService();
    _utilityService = const FormattingService();
    _diskSpaceService = ConsolidatedDiskSpaceService();

    // Initialize media processing services
    _duplicateDetectionService = DuplicateDetectionService();
    _albumRelationshipService = AlbumRelationshipService();

    // Initialize interactive service with dependencies
    _interactiveService = ConsolidatedInteractiveService(
      globalConfig: _globalConfig!,
    );

    // Try to find and initialize ExifTool
    exifTool = await ExifToolService.find();
    if (exifTool != null) {
      await exifTool!.startPersistentProcess();
      _globalConfig!.exifToolInstalled = true;
    } else {
      _globalConfig!.exifToolInstalled = false;
    }

    _isInitialized = true;
  }

  /// Dispose of all services and cleanup resources
  Future<void> dispose() async {
    if (exifTool != null) {
      await exifTool!.dispose();
      exifTool = null;
    } // Reset initialization state
    _isInitialized = false;
    _globalConfig = null;
    _utilityService = null;
    _diskSpaceService = null;
    _interactiveService = null;
    _duplicateDetectionService = null;
    _albumRelationshipService = null;
  }

  /// Reset the service container (primarily for testing)
  static Future<void> reset() async {
    await _instance?.dispose();
    _instance = null;
  }
}
