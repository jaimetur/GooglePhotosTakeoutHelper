/// Utilities file using clean architecture principles
///
/// This file now serves as a barrel file to re-export functionality
/// that has been moved to appropriate services and utilities.
library;

export 'domain/services/extension_fixing_service.dart';
// Re-export services
export 'domain/services/file_system_service.dart';
export 'domain/services/logging_service.dart';
export 'domain/services/metadata_matcher_service.dart';
export 'domain/services/mime_type_service.dart';
export 'domain/services/processing_metrics_service.dart';
export 'domain/services/service_container.dart';
export 'infrastructure/disk_space_service.dart';
// Legacy exports for backward compatibility
export 'interactive_handler.dart' show indeed;
// Re-export constants
export 'shared/constants.dart';
// Re-export extensions
export 'shared/extensions/extensions.dart';
