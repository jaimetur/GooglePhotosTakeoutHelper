/// Public barrel of the library.
/// Import this from apps/bin/tests: `import 'package:<your_package_name>/gpth-lib.dart';`
library gpth;

/*
============================================================
Barrel that exposes the pipeline and each step orchestration.
============================================================
*/

export 'steps/main_pipeline.dart';
export 'steps/steps_pipeline.dart';

// Step 01
export 'steps/step_01_fix_extensions/step_01_fix_extensions.dart';

// Step 02
export 'steps/step_02_discover_media/step_02_discover_media.dart';
export 'steps/step_02_discover_media/services/takeout_folder_classifier_service.dart';

// Step 03
export 'steps/step_03_remove_duplicates/step_03_remove_duplicates.dart';

// Step 04
export 'steps/step_04_extract_dates/step_04_extract_dates.dart';
export 'steps/step_04_extract_dates/services/date_extractors/date_extractor_service.dart';
export 'steps/step_04_extract_dates/services/date_extractors/exif_date_extractor.dart';
export 'steps/step_04_extract_dates/services/date_extractors/filename_date_extractor.dart';
export 'steps/step_04_extract_dates/services/date_extractors/folder_year_extractor.dart';
export 'steps/step_04_extract_dates/services/date_extractors/json_date_extractor.dart';

// Step 05
export 'steps/step_05_write_exif/step_05_write_exif.dart';
export 'steps/step_05_write_exif/services/exif_gps_extractor.dart';
export 'steps/step_05_write_exif/services/exif_writer_service.dart';

// Step 06
export 'steps/step_06_find_albums/step_06_find_albums.dart';

// Step 07
export 'steps/step_07_move_files/step_07_move_files.dart';
export 'steps/step_07_move_files/services/file_operation_service.dart';
export 'steps/step_07_move_files/services/media_entity_moving_service.dart';
export 'steps/step_07_move_files/services/moving_context_model.dart';
export 'steps/step_07_move_files/services/path_generator_service.dart';
export 'steps/step_07_move_files/services/symlink_service.dart';
export 'steps/step_07_move_files/strategies/duplicate_copy_moving_strategy.dart';
export 'steps/step_07_move_files/strategies/json_moving_strategy.dart';
export 'steps/step_07_move_files/strategies/media_entity_moving_strategy.dart';
export 'steps/step_07_move_files/strategies/media_entity_moving_strategy_factory.dart';
export 'steps/step_07_move_files/strategies/nothing_moving_strategy.dart';
export 'steps/step_07_move_files/strategies/reverse_shortcut_moving_strategy.dart';
export 'steps/step_07_move_files/strategies/shortcut_moving_strategy.dart';

// Step 08
export 'steps/step_08_update_creation_time/step_08_update_creation_time.dart';


/*
========================================================
Barrel for all shared, reusable components across steps.
========================================================
*/

// modules from shared/constants
export 'shared/constants/constants.dart';
export 'shared/constants/exif_constants.dart';
export 'shared/constants/extra_formats.dart';

// modules from shared/entities
export 'shared/entities/media_entity.dart';
export 'shared/entities/media_entity_collection.dart';

// modules from shared/file_extensions
export 'shared/file_extensions/file_extensions.dart';

// modules from shared/infraestructure
export 'shared/infraestructure/concurrency_manager.dart';
export 'shared/infraestructure/consolidated_disk_space_service.dart';
export 'shared/infraestructure/exiftool_service.dart';
export 'shared/infraestructure/platform_service.dart';
export 'shared/infraestructure/windows_symlink_service.dart';

// modules from shared/models
export 'shared/models/io_paths_model.dart';
export 'shared/models/processing_config_model.dart';
export 'shared/models/processing_result_model.dart';

// modules from shared/services/core_services
export 'shared/services/core_services/container_service.dart';
export 'shared/services/core_services/formatting_service.dart';
export 'shared/services/core_services/global_config_service.dart';
export 'shared/services/core_services/global_pools.dart';
export 'shared/services/core_services/logging_service.dart';
export 'shared/services/core_services/processing_metrics_service.dart';

// modules from shared/services/file_operations_services
export 'shared/services/file_operations_services/archive_extraction_service.dart';
export 'shared/services/file_operations_services/file_system_service.dart';
export 'shared/services/file_operations_services/filename_sanitizer_service.dart';
export 'shared/services/file_operations_services/path_resolver_service.dart';

// modules from shared/services/interactive_presenter_service
export 'shared/services/interactive_presenter_service/interactive_presenter_service.dart';

// modules from shared/services/json_metadata_services
export 'shared/services/json_metadata_services/json_metadata_matcher_service.dart';

// modules from shared/services/media_services
export 'shared/services/media_services/album_relationship_service.dart';
export 'shared/services/media_services/content_grouping_service.dart';
export 'shared/services/media_services/date_time_extraction_method.dart';
export 'shared/services/media_services/duplicate_detection_service.dart';
export 'shared/services/media_services/edited_version_detector_service.dart';
export 'shared/services/media_services/media_hash_service.dart';
export 'shared/services/media_services/mime_type_service.dart';

// modules from shared/services/user_interaction
export 'shared/services/user_interaction/configuration_builder_service.dart';
export 'shared/services/user_interaction/user_interaction_service.dart';

// modules from shared/services/user_interaction
export 'shared/value_objects/date_accuracy.dart';
export 'shared/value_objects/media_files_collection.dart';


export 'shared/exports.dart'; // keep if you use it internally

