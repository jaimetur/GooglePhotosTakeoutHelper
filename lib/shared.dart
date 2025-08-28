/// Barrel for all shared, reusable components across steps.

export 'shared/constants/constants.dart';
export 'shared/constants/exif_constants.dart';
export 'shared/constants/extra_formats.dart';

export 'shared/entities/media_entity.dart';
export 'shared/entities/media_entity_collection.dart';

export 'shared/value_objects/date_accuracy.dart';
export 'steps/step_04_extract_dates/controllers/date_time_extraction_method.dart';
export 'shared/value_objects/media_files_collection.dart';

export 'shared/models/io_paths_model.dart';
export 'shared/models/processing_config_model.dart';
export 'shared/models/processing_result_model.dart';

export 'shared/file_extensions/file_extensions.dart';

export 'shared/services/core_services/formatting_service.dart';
export 'shared/services/core_services/global_config_service.dart';
export 'shared/services/core_services/global_pools.dart';
export 'shared/services/core_services/logging_service.dart';
export 'shared/services/core_services/container_service.dart';

export 'shared/services/file_operations_services/filename_sanitizer_service.dart';
export 'shared/services/core_services/processing_metrics_service.dart';
export 'steps/step_02_discover_media/services/takeout_folder_classifier_service.dart';

export 'shared/services/user_interaction/configuration_builder_service.dart';
export 'shared/services/file_operations_services/path_resolver_service.dart';
export 'shared/services/user_interaction/user_interaction_service.dart';
export 'shared/services/interactive_presenter_service/interactive_presenter_service.dart';

export 'shared/services/json_metadata_services/json_metadata_matcher_service.dart';

export 'shared/services/media_services/album_relationship_service.dart';
export 'shared/services/media_services/content_grouping_service.dart';
export 'shared/services/media_services/duplicate_detection_service.dart';
export 'shared/services/media_services/edited_version_detector_service.dart';
export 'shared/services/media_services/media_hash_service.dart';
export 'shared/services/media_services/mime_type_service.dart';

export 'shared/services/file_operations_services/file_system_service.dart';

export 'shared/infraestructure/concurrency_manager.dart';
export 'shared/infraestructure/consolidated_disk_space_service.dart';
export 'shared/infraestructure/exiftool_service.dart';
export 'shared/infraestructure/platform_service.dart';

export 'shared/exports.dart'; // keep if you use it internally
