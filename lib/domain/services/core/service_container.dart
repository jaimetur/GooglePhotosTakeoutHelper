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
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _globalConfig!;
  }

  LoggingService get loggingService {
    if (_loggingService == null) {
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _loggingService!;
  }

  FormattingService get utilityService {
    if (_utilityService == null) {
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _utilityService!;
  }

  ConsolidatedDiskSpaceService get diskSpaceService {
    if (_diskSpaceService == null) {
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _diskSpaceService!;
  }

  ConsolidatedInteractiveService get interactiveService {
    if (_interactiveService == null) {
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _interactiveService!;
  }

  DuplicateDetectionService get duplicateDetectionService {
    if (_duplicateDetectionService == null) {
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _duplicateDetectionService!;
  }

  AlbumRelationshipService get albumRelationshipService {
    if (_albumRelationshipService == null) {
      throw StateError('ServiceContainer not initialized. Call initialize() first.');
    }
    return _albumRelationshipService!;
  }

  /// Initialize all services
  ///
  /// If [loggingService] is provided, we reinitialize to attach the new logger.
  Future<void> initialize({final LoggingService? loggingService}) async {
    // Prevent concurrent initialization attempts
    if (_isInitialized && loggingService == null) {
      return; // Already initialized and no new logger provided, no-op
    }

    // If a new logger is provided, we need to reinitialize cleanly
    if (_isInitialized && loggingService != null) {
      await dispose(); // Clean up existing services first
    }

    // Set flag early to prevent race conditions
    _isInitialized = true;

    // Core services
    _globalConfig = GlobalConfigService();
    _loggingService = loggingService ?? LoggingService();
    _utilityService = const FormattingService();
    _diskSpaceService = ConsolidatedDiskSpaceService();

    // Media-related services with shared logger
    final mediaHashService = MediaHashService()..logger = _loggingService!;
    _duplicateDetectionService = DuplicateDetectionService(
      hashService: mediaHashService,
    )..logger = _loggingService!;
    _albumRelationshipService = AlbumRelationshipService()..logger = _loggingService!;

    // Interactive service
    _interactiveService = ConsolidatedInteractiveService(
      globalConfig: _globalConfig!,
    )..logger = _loggingService!;

    // ── ExifTool discovery (restored behavior) ───────────────────────────────
    // Pass the global config positionally (classic signature). If you don't
    // keep the exifTool path in config, you can just call find() with no args.
    try {
      exifTool = await ExifToolService.find(_globalConfig);
      if (exifTool != null) {
        exifTool!.logger = _loggingService!;
        await exifTool!.startPersistentProcess();
        _globalConfig!.exifToolInstalled = true;
        _loggingService!.info('ExifTool persistent process started.');
      } else {
        _globalConfig!.exifToolInstalled = false;
        _loggingService!.warning('Exiftool not found! Continuing without EXIF support...');
      }
    } catch (e) {
      _globalConfig!.exifToolInstalled = false;
      _loggingService!.error('Failed to initialize ExifTool: $e');
    }

    _isInitialized = true;
  }

  /// Dispose of all services and cleanup resources
  Future<void> dispose() async {
    if (exifTool != null) {
      await exifTool!.dispose();
      exifTool = null;
    }

    // Reset initialization state
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
