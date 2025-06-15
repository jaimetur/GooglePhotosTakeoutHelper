import 'dart:io';

import 'models/media_entity_collection.dart';
import 'models/pipeline_step_model.dart';
import 'models/processing_config_model.dart';
import 'models/processing_result_model.dart';
import 'services/core/formatting_utility_service.dart';
import 'services/user_interaction/user_interaction_service.dart';
import 'steps/step_01_fix_extensions.dart';
import 'steps/step_02_discover_media.dart';
import 'steps/step_03_remove_duplicates.dart';
import 'steps/step_04_extract_dates.dart';
import 'steps/step_05_write_exif.dart';
import 'steps/step_06_find_albums.dart';
import 'steps/step_07_move_files.dart';
import 'steps/step_08_update_creation_time.dart';
import 'value_objects/date_time_extraction_method.dart';

/// Processing Pipeline for Google Photos Takeout Helper
///
/// This pipeline executes 8 processing steps in their fixed order:
/// 1. Fix Extensions - Correct mismatched file extensions (configurable)
/// 2. Discover Media - Find and classify all media files from input directory
/// 3. Remove Duplicates - Eliminate duplicate files using content hashing
/// 4. Extract Dates - Determine accurate timestamps from JSON, EXIF, and filenames
/// 5. Write EXIF - Embed metadata into files (requires ExifTool for non-JPEG formats)
/// 6. Find Albums - Detect and merge album relationships between duplicate files
/// 7. Move Files - Organize files to output structure using selected album behavior
/// 8. Update Creation Time - Sync file creation timestamps (Windows only, configurable)
///
/// Each step checks configuration flags to determine if it should run.
/// This eliminates the need for complex builder patterns while maintaining
/// full flexibility through configuration.
class ProcessingPipeline {
  /// Create a processing pipeline
  const ProcessingPipeline({this.interactiveService});

  /// Optional interactive service for displaying processing summaries and results
  final ConsolidatedInteractiveService? interactiveService;

  /// Execute the complete processing pipeline
  ///
  /// Runs all 8 steps in sequence, with each step checking configuration
  /// to determine if it should execute. Returns comprehensive results
  /// including timing, statistics, and any errors encountered.
  Future<ProcessingResult> execute({
    required final ProcessingConfig config,
    required final Directory inputDirectory,
    required final Directory outputDirectory,
  }) async {
    final overallStopwatch = Stopwatch()..start();
    final mediaCollection = MediaEntityCollection();

    // Create processing context
    final context = ProcessingContext(
      config: config,
      mediaCollection: mediaCollection,
      inputDirectory: inputDirectory,
      outputDirectory: outputDirectory,
    );

    // Define the 8 processing steps in fixed order
    final steps = [
      const FixExtensionsStep(), // Step 1
      const DiscoverMediaStep(), // Step 2
      const RemoveDuplicatesStep(), // Step 3
      const ExtractDatesStep(), // Step 4
      const WriteExifStep(), // Step 5
      const FindAlbumsStep(), // Step 6
      const MoveFilesStep(), // Step 7
      const UpdateCreationTimeStep(), // Step 8
    ];

    final stepResults = <StepResult>[];
    final stepTimings = <String, Duration>{};

    // Counters for ProcessingResult
    var duplicatesRemoved = 0;
    var extrasSkipped = 0;
    var extensionsFixed = 0;
    var coordinatesWrittenToExif = 0;
    var dateTimesWrittenToExif = 0;
    var creationTimesUpdated = 0;
    final extractionMethodStats = <DateTimeExtractionMethod, int>{};

    if (config.verbose) {
      print('\n=== Starting Google Photos Takeout Helper Processing ===');
      print('Input: ${config.inputPath}');
      print('Output: ${outputDirectory.path}');
      print(
        'Configuration: ${config.albumBehavior.name} album behavior, '
        '${config.dateDivision.name} date division',
      );
    } // Execute each step in sequence
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      final stepNumber = i + 1;

      print('\n--- Step $stepNumber/8: ${step.name} ---');

      // Check if step should be skipped
      if (step.shouldSkip(context)) {
        if (config.verbose) {
          print('Skipping ${step.name} (conditions not met)');
        }

        stepResults.add(
          StepResult.success(
            stepName: step.name,
            duration: Duration.zero,
            data: {'skipped': true},
            message: 'Step skipped due to configuration or conditions',
          ),
        );
        continue;
      }

      // Execute the step
      try {
        final result = await step.execute(context);
        stepResults.add(result);
        stepTimings[step.name] = result.duration;

        // Extract statistics from step results
        _extractStepStatistics(
          step,
          result,
          duplicatesRemoved: (final int value) => duplicatesRemoved = value,
          extrasSkipped: (final int value) => extrasSkipped = value,
          extensionsFixed: (final int value) => extensionsFixed = value,
          coordinatesWrittenToExif: (final int value) =>
              coordinatesWrittenToExif = value,
          dateTimesWrittenToExif: (final int value) =>
              dateTimesWrittenToExif = value,
          creationTimesUpdated: (final int value) =>
              creationTimesUpdated = value,
          extractionMethodStats: extractionMethodStats,
        );

        if (result.isSuccess) {
          print(
            '✅ ${step.name} completed in ${const UtilityService().formatDuration(result.duration)}',
          );
          if (result.message != null) {
            print('   ${result.message}');
          }
        } else {
          print('❌ ${step.name} failed: ${result.message}');
          if (result.error != null) {
            print('   Error: ${result.error}');
          }
        }

        // Stop processing if a critical step fails
        if (!result.isSuccess && _isCriticalStep(step)) {
          if (config.verbose) {
            print('\n⚠️  Critical step failed, stopping pipeline execution');
          }
          break;
        }
      } catch (e) {
        final error = Exception('Unexpected error in ${step.name}: $e');
        final failureResult = StepResult.failure(
          stepName: step.name,
          duration: Duration.zero,
          error: error,
          message: 'Step failed with unexpected error',
        );

        stepResults.add(failureResult);

        if (config.verbose) {
          print('❌ ${step.name} failed with unexpected error: $e');
        }

        // Stop on critical step failure
        if (_isCriticalStep(step)) {
          break;
        }
      }
    }
    overallStopwatch.stop();

    // Calculate final statistics
    final successfulSteps = stepResults
        .where((final StepResult r) => r.isSuccess)
        .length;
    final failedSteps = stepResults
        .where((final StepResult r) => !r.isSuccess)
        .length;
    final skippedSteps = stepResults
        .where((final StepResult r) => r.data['skipped'] == true)
        .length;
    final totalProcessingTime = overallStopwatch.elapsed;

    if (config.verbose && interactiveService != null) {
      // Display warnings and errors summary first
      await interactiveService!.showWarningsAndErrorsSummary(stepResults);

      // Display processing summary
      await interactiveService!.showProcessingSummary(
        totalTime: totalProcessingTime,
        successfulSteps: successfulSteps,
        failedSteps: failedSteps,
        skippedSteps: skippedSteps,
        mediaCount: mediaCollection.length,
      );

      // Display detailed step results
      await interactiveService!.showStepResults(stepResults, stepTimings);
    } else if (config.verbose) {
      // Fallback to legacy display if no interactive service provided
      _displayWarningsAndErrorsSummary(stepResults);

      print('\n=== Processing Summary ===');
      print(
        'Total time: ${totalProcessingTime.inMinutes}m ${totalProcessingTime.inSeconds % 60}s',
      );
      print(
        'Steps: $successfulSteps successful, $failedSteps failed, $skippedSteps skipped',
      );
      print('Final media count: ${mediaCollection.length}');

      // Display detailed step results
      _displayStepResults(stepResults, stepTimings);
    }

    // Create comprehensive result
    return ProcessingResult(
      totalProcessingTime: totalProcessingTime,
      stepTimings: stepTimings,
      mediaProcessed: mediaCollection.length,
      duplicatesRemoved: duplicatesRemoved,
      extrasSkipped: extrasSkipped,
      extensionsFixed: extensionsFixed,
      coordinatesWrittenToExif: coordinatesWrittenToExif,
      dateTimesWrittenToExif: dateTimesWrittenToExif,
      creationTimesUpdated: creationTimesUpdated,
      extractionMethodStats: extractionMethodStats,
      isSuccess: failedSteps == 0,
    );
  }

  /// Determine if a step is critical for processing
  ///
  /// Critical steps will stop the pipeline if they fail
  bool _isCriticalStep(final ProcessingStep step) =>
      step is DiscoverMediaStep || step is MoveFilesStep;

  /// Extract statistics from individual step results
  void _extractStepStatistics(
    final ProcessingStep step,
    final StepResult result, {
    required final Function(int) duplicatesRemoved,
    required final Function(int) extrasSkipped,
    required final Function(int) extensionsFixed,
    required final Function(int) coordinatesWrittenToExif,
    required final Function(int) dateTimesWrittenToExif,
    required final Function(int) creationTimesUpdated,
    required final Map<DateTimeExtractionMethod, int> extractionMethodStats,
  }) {
    final data = result.data;

    if (step is RemoveDuplicatesStep) {
      duplicatesRemoved(data['duplicatesRemoved'] as int? ?? 0);
      extrasSkipped(data['extrasRemoved'] as int? ?? 0);
    } else if (step is FixExtensionsStep) {
      extensionsFixed(data['extensionsFixed'] as int? ?? 0);
    } else if (step is WriteExifStep) {
      coordinatesWrittenToExif(data['coordinatesWritten'] as int? ?? 0);
      dateTimesWrittenToExif(data['dateTimesWritten'] as int? ?? 0);
    } else if (step is UpdateCreationTimeStep) {
      creationTimesUpdated(data['creationTimesUpdated'] as int? ?? 0);
    } else if (step is ExtractDatesStep) {
      final stepStats = data['extractionStats'] as Map<dynamic, dynamic>? ?? {};
      for (final entry in stepStats.entries) {
        // Convert string keys to DateTimeExtractionMethod enum values
        final methodName = entry.key.toString();
        final count = entry.value as int? ?? 0;

        // Try to find matching enum value
        for (final method in DateTimeExtractionMethod.values) {
          if (method.toString().split('.').last == methodName ||
              method.name == methodName) {
            extractionMethodStats[method] = count;
            break;
          }
        }
      }
    }
  }

  /// Displays a summary of warnings and errors encountered during processing
  ///
  /// Only shown in verbose mode, provides detailed information about any
  /// issues that occurred during processing steps.
  void _displayWarningsAndErrorsSummary(final List<StepResult> stepResults) {
    final failedSteps = stepResults.where((final r) => !r.isSuccess).toList();
    final warnings = <String>[];

    // Collect warnings from step messages and errors
    for (final result in stepResults) {
      if (!result.isSuccess && result.error != null) {
        warnings.add('${result.stepName}: ${result.error}');
      } else if (result.message != null &&
          (result.message!.toLowerCase().contains('warning') ||
              result.message!.toLowerCase().contains('skipped') ||
              result.message!.toLowerCase().contains('failed'))) {
        warnings.add('${result.stepName}: ${result.message}');
      }
    }

    if (warnings.isNotEmpty || failedSteps.isNotEmpty) {
      print('\n=== Warnings and Errors Summary ===');

      if (failedSteps.isNotEmpty) {
        print('Failed Steps:');
        for (final step in failedSteps) {
          print('  ❌ ${step.stepName}: ${step.message ?? 'Unknown error'}');
          if (step.error != null) {
            print('     Error: ${step.error}');
          }
        }
      }

      if (warnings.isNotEmpty) {
        print('Warnings:');
        for (final warning in warnings) {
          print('  ⚠️  $warning');
        }
      }

      if (warnings.isEmpty && failedSteps.isEmpty) {
        print('No warnings or errors encountered during processing.');
      }
    }
  }

  /// Displays detailed results for each processing step
  ///
  /// Shows step-by-step breakdown of what was accomplished
  void _displayStepResults(
    final List<StepResult> stepResults,
    final Map<String, Duration> stepTimings,
  ) {
    print('\n=== Step-by-Step Results ===');

    for (final result in stepResults) {
      final timing = stepTimings[result.stepName] ?? result.duration;
      final status = result.isSuccess ? '✅' : '❌';
      final skipped = result.data['skipped'] == true;

      print('$status ${result.stepName} (${_formatDuration(timing)})');

      if (skipped) {
        print('   Status: Skipped');
        print('   Reason: ${result.message ?? 'Conditions not met'}');
      } else if (result.isSuccess) {
        print('   Status: Completed successfully');
        if (result.message != null) {
          print('   Result: ${result.message}');
        }

        // Display specific metrics for each step
        _displayStepMetrics(result);
      } else {
        print('   Status: Failed');
        print('   Error: ${result.message ?? 'Unknown error'}');
      }
      print('');
    }
  }

  /// Displays specific metrics for a step based on its data
  void _displayStepMetrics(final StepResult result) {
    final data = result.data;

    switch (result.stepName) {
      case 'Fix Extensions':
        if (data['fixedCount'] != null) {
          print('   Fixed extensions: ${data['fixedCount']} files');
        }
        break;

      case 'Discover Media':
        if (data['totalFiles'] != null) {
          print('   Total files discovered: ${data['totalFiles']}');
        }
        if (data['yearFolderFiles'] != null) {
          print('   Year folder files: ${data['yearFolderFiles']}');
        }
        if (data['albumFolderFiles'] != null) {
          print('   Album folder files: ${data['albumFolderFiles']}');
        }
        break;

      case 'Remove Duplicates':
        if (data['duplicatesRemoved'] != null) {
          print('   Duplicates removed: ${data['duplicatesRemoved']} files');
        }
        if (data['remainingMedia'] != null) {
          print('   Remaining media: ${data['remainingMedia']} files');
        }
        break;

      case 'Extract Dates':
        if (data['processedMedia'] != null) {
          print('   Media processed: ${data['processedMedia']} files');
        }
        if (data['extractionStats'] != null) {
          final stats = data['extractionStats'] as Map;
          print('   Extraction methods used:');
          for (final entry in stats.entries) {
            print('     ${entry.key}: ${entry.value} files');
          }
        }
        break;

      case 'Write EXIF Data':
        if (data['coordinatesWritten'] != null) {
          print(
            '   GPS coordinates written: ${data['coordinatesWritten']} files',
          );
        }
        if (data['dateTimesWritten'] != null) {
          print('   DateTime written: ${data['dateTimesWritten']} files');
        }
        break;

      case 'Find Albums':
        if (data['initialCount'] != null && data['finalCount'] != null) {
          print('   Initial media count: ${data['initialCount']}');
          print('   Final media count: ${data['finalCount']}');
        }
        if (data['mergedCount'] != null) {
          print('   Album relationships merged: ${data['mergedCount']}');
        }
        break;

      case 'Move Files':
        if (data['processedCount'] != null) {
          print('   Files processed: ${data['processedCount']}');
        }
        if (data['copyMode'] != null) {
          print('   Operation mode: ${data['copyMode'] ? 'Copy' : 'Move'}');
        }
        if (data['albumBehavior'] != null) {
          print('   Album behavior: ${data['albumBehavior']}');
        }
        break;

      case 'Update Creation Time':
        if (data['updatedCount'] != null) {
          print('   Creation times updated: ${data['updatedCount']} files');
        }
        break;
    }
  }

  /// Formats a duration as a human-readable string
  String _formatDuration(final Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    } else {
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds % 60;
      return '${minutes}m ${seconds}s';
    }
  }
}
