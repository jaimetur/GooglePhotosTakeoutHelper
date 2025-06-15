/// Simplified utilities barrel file
///
/// Exports only the essential services and utilities that are actually used
/// throughout the application.
library;

// Core services used throughout the application
export 'domain/services/core/logging_service.dart';
export 'domain/services/core/service_container.dart';
export 'domain/services/media/mime_type_service.dart';
export 'domain/services/metadata/json_metadata_matcher_service.dart';
// Application constants
export 'shared/constants.dart';
// Extensions used by services
export 'shared/extensions/extensions.dart';
