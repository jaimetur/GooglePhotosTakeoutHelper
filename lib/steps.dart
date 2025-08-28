/// Barrel that exposes the pipeline and each step orchestration.
/// Keep step-internal services/strategies private unless you need them from outside.

export 'steps/steps_pipeline.dart';
export 'steps/main_pipeline.dart';

// Step 01
export 'steps/step_01_fix_extensions/step_01_fix_extensions.dart';

// Step 02
export 'steps/step_02_discover_media/step_02_discover_media.dart';

// Step 03
export 'steps/step_03_remove_duplicates/step_03_remove_duplicates.dart';

// Step 04
export 'steps/step_04_extract_dates/step_04_extract_dates.dart';

// If you need to call specific extractors from outside, uncomment these lines.
// export 'steps/step_04_extract_dates/services/date_extractors/date_extractor_service.dart';
// export 'steps/step_04_extract_dates/services/date_extractors/exif_date_extractor.dart';
// export 'steps/step_04_extract_dates/services/date_extractors/filename_date_extractor.dart';
// export 'steps/step_04_extract_dates/services/date_extractors/folder_year_extractor.dart';
// export 'steps/step_04_extract_dates/services/date_extractors/json_date_extractor.dart';

// Step 05
export 'steps/step_05_write_exif/step_05_write_exif.dart';
// If you need them from outside the step, uncomment:
// export 'steps/step_05_write_exif/services/exif_gps_extractor.dart';
// export 'steps/step_05_write_exif/services/exif_writer_service.dart';

// Step 06
export 'steps/step_06_find_albums/step_06_find_albums.dart';

// Step 07
export 'steps/step_07_move_files/step_07_move_files.dart';
// Keep strategies/services internal to the step unless required externally.
// export 'steps/step_07_move_files/services/file_operation_service.dart';
// export 'steps/step_07_move_files/services/media_entity_moving_service.dart';
// export 'steps/step_07_move_files/services/moving_context_model.dart';
// export 'steps/step_07_move_files/services/path_generator_service.dart';
// export 'steps/step_07_move_files/services/symlink_service.dart';
// export 'steps/step_07_move_files/strategies/duplicate_copy_moving_strategy.dart';
// export 'steps/step_07_move_files/strategies/json_moving_strategy.dart';
// export 'steps/step_07_move_files/strategies/media_entity_moving_strategy.dart';
// export 'steps/step_07_move_files/strategies/media_entity_moving_strategy_factory.dart';
// export 'steps/step_07_move_files/strategies/nothing_moving_strategy.dart';
// export 'steps/step_07_move_files/strategies/reverse_shortcut_moving_strategy.dart';
// export 'steps/step_07_move_files/strategies/shortcut_moving_strategy.dart';

// Step 08
export 'steps/step_08_update_creation_time/step_08_update_creation_time.dart';
