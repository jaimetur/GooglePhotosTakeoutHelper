import '../../../infrastructure/consolidated_disk_space_service.dart';
import '../../../infrastructure/exiftool_service.dart';
import '../media/album_relationship_service.dart';
import '../media/duplicate_detection_service.dart';
import '../media/media_hash_service.dart';
import '../user_interaction/user_interaction_service.dart';
import 'formatting_service.dart';
import 'global_config_service.dart';
import 'logging_service.dart';

/// Service container for dependency injection
///
/// Manages the lifecycle of all application services and provides
/// centralized configuration and initialization.
class ServiceContainer {
  ServiceContainer._();
  // Use nullable fields instead of late final to allow re-initialization
  GlobalConfigService? _globalConfig;
  LoggingService? _loggingService;
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

  LoggingService get loggingService {
    if (_loggingService == null) {
      throw StateError(
        'ServiceContainer not initialized. Call initialize() first.',
      );
    }
    return _loggingService!;
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
  Future<void> initialize({final LoggingService? loggingService}) async {
    // Prevent concurrent initialization attempts
    if (_isInitialized && loggingService == null) {
      return; // Already initialized and no new logger provided, no-op
    }

    // If a new logger is provided, we need to reinitialize
    if (_isInitialized && loggingService != null) {
      await dispose(); // Clean up existing services first
    }

    // Set flag early to prevent race conditions
    _isInitialized = true;

    // Initialize core services first
    _globalConfig = GlobalConfigService();
    _loggingService = loggingService ?? LoggingService();
    _utilityService = const FormattingService();
    _diskSpaceService =
        ConsolidatedDiskSpaceService(); // Initialize media processing services with shared logging
    final mediaHashService = MediaHashService()..logger = _loggingService!;
    _duplicateDetectionService = DuplicateDetectionService(
      hashService: mediaHashService,
    )..logger = _loggingService!;
    _albumRelationshipService = AlbumRelationshipService()
      ..logger = _loggingService!;

    // Initialize interactive service with dependencies
    _interactiveService = ConsolidatedInteractiveService(
      globalConfig: _globalConfig!,
    )..logger = _loggingService!;

    // Try to find and initialize ExifTool
    exifTool = await ExifToolService.find();
    if (exifTool != null) {
      await exifTool!.startPersistentProcess();
      _globalConfig!.exifToolInstalled = true;
    } else {
      _globalConfig!.exifToolInstalled = false;
    }

    // Initialize logging service
    _loggingService = LoggingService();

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
    _loggingService = null;
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
