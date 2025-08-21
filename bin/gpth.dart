// ignore_for_file: unintended_html_in_doc_comment

import 'dart:convert'; // <-- for jsonDecode
import 'dart:io';

import 'package:args/args.dart';
import 'package:gpth/domain/main_pipeline.dart';
import 'package:gpth/domain/models/io_paths_model.dart';
import 'package:gpth/domain/models/processing_config_model.dart';
import 'package:gpth/domain/models/processing_result_model.dart';
import 'package:gpth/domain/services/core/logging_service.dart';
import 'package:gpth/domain/services/core/service_container.dart';
import 'package:gpth/domain/services/user_interaction/path_resolver_service.dart';
import 'package:gpth/presentation/interactive_presenter.dart';
import 'package:gpth/shared/concurrency_manager.dart';
import 'package:gpth/shared/constants.dart';
import 'package:path/path.dart' as p;

// Parses hidden test-only flags from argv, applies them, and returns a list
// with those flags removed so ArgParser won't choke on unknown options.
// Supported examples:
//   --_test-standard-multiplier=2
//   --_test-conservative-multiplier=4
//   --_test-disk-optimized-multiplier=8
List<String> _applyAndStripTestMultipliers(final List<String> args) {
  final re = RegExp(r'^--_test-([a-z0-9-]+)=(\d+)$', caseSensitive: false);
  final cleaned = <String>[];
  for (final arg in args) {
    final m = re.firstMatch(arg);
    if (m == null) {
      cleaned.add(arg);
      continue;
    }
    final name = m.group(1)!.toLowerCase();
    final val = int.tryParse(m.group(2)!);
    if (val == null) continue; // silently ignore malformed
    switch (name) {
      case 'standard-multiplier':
        ConcurrencyManager.setMultipliers(standard: val);
        break;
      case 'conservative-multiplier':
        ConcurrencyManager.setMultipliers(conservative: val);
        break;
      case 'disk-optimized-multiplier':
        ConcurrencyManager.setMultipliers(diskOptimized: val);
        break;
      default:
        // Unknown hidden flag -> ignore (do not forward to parser)
        break;
    }
  }
  return cleaned;
}

/// ############################### GOOGLE PHOTOS TAKEOUT HELPER #############################
///
/// **PROCESSING FLOW:**
/// 1. Parse command line arguments → ProcessingConfig
/// 2. Initialize dependencies (ExifTool, ServiceContainer)
/// 3. Execute ProcessingPipeline with 8 steps:
///    - Fix Extensions: Correct mismatched file extensions (optional)
///    - Discover Media: Find and classify all media files
///    - Remove Duplicates: Eliminate duplicate files using content hashing
///    - Extract Dates: Determine accurate timestamps from multiple sources
///    - Write EXIF: Embed metadata into files (when ExifTool available)
///    - Find Albums: Detect and merge album relationships
///    - Move Files: Organize files to output structure using selected album behavior
///    - Update Creation Time: Sync file creation timestamps (Windows only, optional)
/// 4. Display comprehensive results and statistics
///
/// **DESIGN PATTERNS USED:**
/// - Builder Pattern: For complex ProcessingConfig construction
/// - Template Method: ProcessingStep base class with consistent interface
/// - Pipeline Pattern: Sequential step execution with error handling
/// - Domain Models: Type-safe data structures replacing Maps
///
/// **MAINTAINABILITY FEATURES:**
/// - Each function has a single, clear responsibility
/// - All components are independently testable
/// - Configuration is type-safe and validated
/// - Error handling is consistent throughout
/// - Documentation covers both technical and business logic
///
/// ##############################################################################
/// **MAIN ENTRY POINT**
///
/// This is the main entry point for the Google Photos Takeout Helper (GPTH).
/// It orchestrates the entire photo processing workflow using clean architecture principles.
///
/// **HIGH-LEVEL FLOW:**
/// 1. Parse and validate command line arguments
/// 2. Initialize external dependencies (ExifTool, global settings)
/// 3. Execute the main processing pipeline
/// 4. Display comprehensive results to the user
///
/// **ERROR HANDLING:**
/// - All exceptions are caught and handled gracefully
/// - Specific exit codes are used for different error types
/// - User-friendly error messages are displayed
///
/// **PERFORMANCE CONSIDERATIONS:**
/// - Asynchronous processing throughout the pipeline
/// - Memory-efficient streaming for large photo collections
/// - Progress reporting for long-running operations
///
/// @param arguments Command line arguments from the user
Future<void> main(final List<String> arguments) async {
  // Initialize logger early with default settings
  _logger = LoggingService();
  // Apply & strip hidden test-only concurrency multiplier flags before parsing normal args.
  final parsedArguments = _applyAndStripTestMultipliers(arguments);
  try {
    // Initialize ServiceContainer early to support interactive mode during argument parsing
    await ServiceContainer.instance.initialize();

    // Parse command line arguments
    final config = await _parseArguments(parsedArguments);
    if (config == null) {
      return; // Help was shown or other early exit
    }

    // Update logger with correct verbosity and reinitialize services with it
    _logger = LoggingService(isVerbose: config.verbose);

    // Reinitialize ServiceContainer with the properly configured logger
    await ServiceContainer.instance.initialize(loggingService: _logger);

    // Configure dependencies with the parsed config
    await _configureDependencies(config);

    // Execute the processing pipeline
    final result = await _executeProcessing(config);

    // Show final results
    _showResults(config, result);

    // Cleanup services
    await ServiceContainer.instance.dispose();
  } catch (e) {
    _logger.error('Fatal error: $e');
    _logger.quit();
  }
}

/// Global logger instance
late LoggingService _logger;

/// Print a helpful message and exit with given code.
Never _exitWithMessage(
  final int code,
  final String message, {
  final bool showInteractivePrompt = false,
}) {
  final errorType = switch (code) {
    0 => 'SUCCESS',
    1 => 'PROCESSING_ERROR',
    11 => 'INPUT_VALIDATION_ERROR',
    _ => 'ERROR_CODE_$code',
  };

  final fullMessage = '[$errorType] $message';

  try {
    stderr.writeln(fullMessage);
  } catch (_) {}
  try {
    // logger may not be set early in startup, guard against that
    _logger.error(fullMessage);
  } catch (_) {}

  if (showInteractivePrompt && Platform.environment['INTERACTIVE'] == 'true') {
    print(
      '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - press enter to close]',
    );
    stdin.readLineSync();
  }

  exit(code);
}

Future<ProcessingConfig?> _parseArguments(final List<String> arguments) async {
  final parser = _createArgumentParser();

  try {
    final res = parser.parse(arguments);

    if (res['help']) {
      _showHelp(parser);
      return null;
    }

    // Convert ArgResults to configuration
    return await _buildConfigFromArgs(res);
  } on FormatException catch (e) {
    _logger.error('$e');
    _exitWithMessage(
      2,
      'Argument parsing failed: ${e.toString()}. Run `gpth --help` for usage.',
    );
  }
}

/// COMMAND LINE PARSER FACTORY
ArgParser _createArgumentParser() => ArgParser()
  ..addFlag('help', abbr: 'h', negatable: false)
  ..addOption('fix', help: 'Folder with any photos to fix dates (special mode)')
  ..addFlag('interactive', help: 'Use interactive mode')
  ..addFlag('verbose', abbr: 'v', help: 'Shows extensive output')
  ..addOption('input', abbr: 'i', help: 'Input folder with extracted takeouts')
  ..addOption('output', abbr: 'o', help: 'Output folder for organized photos')
  ..addOption(
    'albums',
    help: 'What to do about albums?',
    allowed: InteractivePresenter.albumOptions.keys,
    allowedHelp: InteractivePresenter.albumOptions,
    defaultsTo: 'shortcut',
  )
  ..addOption(
    'divide-to-dates',
    help: 'Divide output to folders by nothing/year/month/day',
    allowed: ['0', '1', '2', '3'],
    defaultsTo: '0',
  )
  ..addFlag('skip-extras', help: 'Skip extra images (like -edited etc)')
  ..addFlag(
    'guess-from-name',
    help: 'Try to guess file dates from their names',
    defaultsTo: true,
  )
  ..addOption(
    'fix-extensions',
    help: 'Fix incorrect file extensions',
    allowed: ['none', 'standard', 'conservative', 'solo'],
    allowedHelp: {
      'none': 'No extension fixing',
      'standard': 'Fix extensions (skip TIFF-based files like RAW) - Default',
      'conservative': 'Fix extensions (skip TIFF and JPEG files)',
      'solo': 'Fix extensions then exit immediately',
    },
    defaultsTo: 'standard',
  )
  ..addFlag('transform-pixel-mp', help: 'Transform Pixel .MP/.MV to .mp4')
  ..addFlag(
    'update-creation-time',
    help: 'Set creation time equal to modification date (Windows only)',
  )
  ..addFlag(
    'write-exif',
    help: 'Write geodata and DateTime to EXIF (requires ExifTool for non-JPEG)',
    defaultsTo: true,
  )
  ..addFlag(
    'limit-filesize',
    help: 'Enforces 64MB file size limit for low RAM systems',
  )
  ..addFlag(
    'divide-partner-shared',
    help: 'Move partner shared media to separate folder (PARTNER_SHARED)',
  )
  // NEW: allow a JSON with precomputed dates
  ..addOption(
    'fileDates',
    help: 'Path to a JSON file with a date dictionary (OldestDate per file)',
  );

void _showHelp(final ArgParser parser) =>
    print('''GooglePhotosTakeoutHelper v$version - The Dart successor

gpth is meant to help you with exporting your photos from Google Photos.

First, go to https://takeout.google.com/ , deselect all and select only Photos.
When ready, download all .zips, and extract them into *one* folder.
To read and write exif data, you have to install exiftool (e.g. from here https://exiftool.org)
for your OS and make sure the executable is in a folder in the \$PATH.

Then, run: gpth --input "folder/with/all/takeouts" --output "your/output/folder"
...and gpth will parse and organize all photos into one big chronological folder

${parser.usage}''');

Future<ProcessingConfig> _buildConfigFromArgs(final ArgResults res) async {
  // Handle special fix mode
  if (res['fix'] != null) {
    return _handleFixMode(res);
  }
  // Set up interactive mode if needed
  final isInteractiveMode =
      res['interactive'] || (res.arguments.isEmpty && stdin.hasTerminal);
  // Get input/output paths (interactive or from args)
  final paths = await _getInputOutputPaths(res, isInteractiveMode);

  // Attempt to load the optional dates dictionary if provided
  if (res['fileDates'] != null) {
    final jsonPath = res['fileDates'] as String;
    _logger.info('Attempting to load fileDates JSON from: $jsonPath');
    try {
      final file = File(jsonPath);
      final jsonString = await file.readAsString();
      final Map<String, dynamic> parsed = jsonDecode(jsonString);

      // Promote to Map<String, Map<String, dynamic>>
      ServiceContainer.instance.globalConfig.fileDatesDictionary =
          parsed.map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));

      final dict = ServiceContainer.instance.globalConfig.fileDatesDictionary!;
      _logger.info('Loaded ${dict.length} entries from $jsonPath');

      // Show a few sample keys to verify shapes quickly
      var shown = 0;
      for (final e in dict.entries) {
        _logger.info('fileDates sample key: ${e.key}');
        shown++;
        if (shown >= 3) break;
      }
    } catch (e) {
      _logger.error('Failed to load fileDates JSON from "$jsonPath": $e');
    }
  } else {
    _logger.info('No --fileDates provided. Continuing without external date dictionary.');
  }

  // Build configuration using the builder pattern
  final configBuilder = ProcessingConfig.builder(
    inputPath: paths.inputPath,
    outputPath: paths.outputPath,
  ); // Apply all configuration options
  if (res['verbose']) configBuilder.verboseOutput = true;
  if (res['skip-extras']) configBuilder.skipExtras = true;
  if (!res['guess-from-name']) configBuilder.guessFromName = false;
  // Set album behavior
  final albumBehavior = AlbumBehavior.fromString(res['albums']);
  configBuilder.albumBehavior = albumBehavior;

  // Set extension fixing mode
  ExtensionFixingMode extensionFixingMode;
  if (isInteractiveMode) {
    // Ask user for date division preference in interactive mode
    print('');
    final dateDivision = await ServiceContainer.instance.interactiveService
        .askDivideDates();
    final divisionLevel = DateDivisionLevel.fromInt(dateDivision);
    configBuilder.dateDivision = divisionLevel;

    // Ask user for extension fixing preference in interactive mode
    print('');
    final extensionFixingChoice = await ServiceContainer
        .instance
        .interactiveService
        .askFixExtensions();
    extensionFixingMode = ExtensionFixingMode.fromString(extensionFixingChoice);

    // Ask user for EXIF writing preference in interactive mode
    print('');
    final writeExif = await ServiceContainer.instance.interactiveService
        .askIfWriteExif();
    configBuilder.exifWriting = writeExif;

    // Ask user for Pixel/MP file transformation in interactive mode
    print('');
    final transformPixelMP = await ServiceContainer.instance.interactiveService
        .askTransformPixelMP();
    configBuilder.pixelTransformation = transformPixelMP;

    // Ask user for file size limiting in interactive mode
    print('');
    final limitFileSize = await ServiceContainer.instance.interactiveService
        .askIfLimitFileSize();
    configBuilder.fileSizeLimit = limitFileSize;

    // Ask user for creation time update in interactive mode (Windows only)
    if (Platform.isWindows) {
      print('');
      final updateCreationTime = await ServiceContainer
          .instance
          .interactiveService
          .askChangeCreationTime();
      configBuilder.creationTimeUpdate = updateCreationTime;
    }
    configBuilder.interactiveMode = true;
  } else {
    // Set date division from command line arguments
    final divisionLevel = DateDivisionLevel.fromInt(
      int.parse(res['divide-to-dates']),
    );
    configBuilder.dateDivision = divisionLevel;

    // Use command line arguments or defaults
    final fixExtensionsArg = res['fix-extensions'] ?? 'standard';
    extensionFixingMode = ExtensionFixingMode.fromString(fixExtensionsArg);

    // Apply remaining configuration options from command line
    if (!res['write-exif']) configBuilder.exifWriting = false;
    if (res['transform-pixel-mp']) configBuilder.pixelTransformation = true;
    if (res['update-creation-time']) configBuilder.creationTimeUpdate = true;
    if (res['limit-filesize']) configBuilder.fileSizeLimit = true;
    if (res['divide-partner-shared']) configBuilder.dividePartnerShared = true;
  }
  configBuilder.extensionFixing = extensionFixingMode;

  return configBuilder.build();
}

Future<ProcessingConfig> _handleFixMode(final ArgResults res) async {
  final fixPath = res['fix'] as String;
  final builder = ProcessingConfig.builder(
    inputPath: fixPath,
    outputPath: fixPath,
  );
  builder.verboseOutput = res['verbose'];
  builder.guessFromName = res['guess-from-name'];
  return builder.build();
}

Future<InputOutputPaths> _getInputOutputPaths(
  final ArgResults res,
  final bool isInteractiveMode,
) async {
  String? inputPath = res['input'];
  String? outputPath = res['output'];
  if (isInteractiveMode) {
    // Interactive mode handles path collection
    await ServiceContainer.instance.interactiveService.showGreeting();
    print('');

    final bool shouldUnzip = await ServiceContainer.instance.interactiveService
        .askIfUnzip();
    print('');

    late Directory inDir;
    if (shouldUnzip) {
      final zips = await ServiceContainer.instance.interactiveService
          .selectZipFiles();
      print('');

      final extractDir = await ServiceContainer.instance.interactiveService
          .selectExtractionDirectory();
      print('');

      final out = await ServiceContainer.instance.interactiveService
          .selectOutputDirectory();
      print('');
      // Calculate space requirements
      final cumZipsSize = zips
          .map((final e) => e.lengthSync())
          .reduce((final a, final b) => a + b);
      final requiredSpace =
          (cumZipsSize * 2) + 256 * 1024 * 1024; // Double because original ZIPs remain
      await ServiceContainer.instance.interactiveService.freeSpaceNotice(
        requiredSpace,
        extractDir,
      );
      print('');
      inDir = extractDir;
      outputPath = out.path;

      await ServiceContainer.instance.interactiveService.extractAll(
        zips,
        extractDir,
      );
      print('');
    } else {
      try {
        inDir = await ServiceContainer.instance.interactiveService
            .selectInputDirectory();
      } catch (e) {
        _logger.warning('⚠️  INTERACTIVE DIRECTORY SELECTION FAILED');
        _logger.warning(
          'Interactive selecting input dir crashed... \n'
          "It looks like you're running headless/on Synology/NAS...\n"
          "If so, you have to use cli options - run 'gpth --help' to see them",
        );
        _logger.warning('');
        _logger.warning('Please restart the program with CLI options instead.');
        _logger.error('No input directory could be selected');
        _exitWithMessage(
          2,
          'Interactive input directory selection failed. If you are running headless or on a NAS, run with CLI options: `gpth --input <path> --output <path>`',
        );
      }
      print('');
      final out = await ServiceContainer.instance.interactiveService
          .selectOutputDirectory();
      outputPath = out.path;
      print('');
    }

    inputPath = inDir.path;
  }

  if (!isInteractiveMode && inputPath != null) {
    try {
      final provided = File(inputPath);
      final Directory extractDir;
      final List<File> zips = [];

      if (await provided.exists() &&
          provided.statSync().type == FileSystemEntityType.file &&
          p.extension(provided.path).toLowerCase() == '.zip') {
        // Single zip file provided as --input
        zips.add(provided);
        extractDir = Directory(
          p.join(p.dirname(provided.path), '.gpth-unzipped'),
        );
      } else {
        final providedDir = Directory(inputPath);
        if (await providedDir.exists()) {
          // Find zip files in directory (non-recursive)
          for (final ent in providedDir.listSync()) {
            if (ent is File && p.extension(ent.path).toLowerCase() == '.zip') {
              zips.add(ent);
            }
          }
        }
        extractDir = Directory(p.join(inputPath, '.gpth-unzipped'));
      }

      if (zips.isNotEmpty) {
        _logger.info(
          'Detected ${zips.length} ZIP file(s) in input path - extracting before processing...',
        );

        // Compute rough required space and warn
        var cumZipsSize = 0;
        for (final z in zips) {
          try {
            cumZipsSize += z.lengthSync();
          } catch (_) {}
        }
        final requiredSpace = (cumZipsSize * 2) + 256 * 1024 * 1024;
        _logger.info(
          'Estimated required temporary space for extraction: ${requiredSpace ~/ (1024 * 1024)} MB',
        );

        try {
          await ServiceContainer.instance.interactiveService.extractAll(
            zips,
            extractDir,
          );
          inputPath = extractDir.path;
          _logger.info(
            'Extraction complete. Using extracted folder: $inputPath',
          );
        } catch (e) {
          _logger.error('Automatic ZIP extraction failed: $e');
          _exitWithMessage(
            12,
            'Automatic ZIP extraction failed: ${e.toString()}. Try extracting manually and run again with the extracted folder as --input.',
          );
        }
      }
    } catch (e) {
      _logger.warning('ZIP auto-detection/extraction encountered an error: $e');
    }
  }

  if (inputPath == null) {
    _logger.error('No --input folder specified :/');
    _exitWithMessage(
      10,
      'Missing required --input path. Provide --input <folder> or run interactive mode.',
    );
  }
  if (outputPath == null) {
    _logger.error('No --output folder specified :/');
    _exitWithMessage(
      10,
      'Missing required --output path. Provide --output <folder> or run interactive mode.',
    );
  }
  try {
    inputPath = PathResolverService.resolveGooglePhotosPath(inputPath);
  } catch (e) {
    _logger.error('Path resolution failed: $e');
    _exitWithMessage(
      12,
      'Could not resolve Google Photos directory from input path: ${e.toString()}. Make sure the folder contains a Takeout/Google Photos structure or pass the correct --input path.',
    );
  }

  return InputOutputPaths(inputPath: inputPath, outputPath: outputPath);
}

Future<void> _configureDependencies(final ProcessingConfig config) async {
  bool isDebugMode = false;
  assert(() {
    isDebugMode = true;
    return true;
  }(), 'Debug mode assertion');
  if (config.verbose || isDebugMode) {
    ServiceContainer.instance.globalConfig.isVerbose = true;
    _logger.info('Verbose mode active!');
  }
  if (config.limitFileSize) {
    ServiceContainer.instance.globalConfig.enforceMaxFileSize = true;
  }

  // Log ExifTool status (already set during ServiceContainer initialization)
  if (ServiceContainer.instance.exifTool != null) {
    print('Exiftool found! Continuing with EXIF support...');
  } else {
    print('Exiftool not found! Continuing without EXIF support...');
  }

  // EXTRA: let the user know if we have a file dates dictionary loaded
  final dict = ServiceContainer.instance.globalConfig.fileDatesDictionary;
  if (dict != null) {
    _logger.info('fileDates dictionary is loaded with ${dict.length} entries.');
  } else {
    _logger.info('fileDates dictionary not loaded.');
  }

  sleep(const Duration(seconds: 3));
}

Future<ProcessingResult> _executeProcessing(
  final ProcessingConfig config,
) async {
  final inputDir = Directory(config.inputPath);
  final outputDir = Directory(config.outputPath);

  if (!await inputDir.exists()) {
    _logger.error('Input folder does not exist :/');
    _exitWithMessage(11, 'Input folder does not exist: ${inputDir.path}');
  }
  if (await outputDir.exists() &&
      !await _isOutputDirectoryEmpty(outputDir, config)) {
    if (config.isInteractiveMode &&
        await ServiceContainer.instance.interactiveService
            .askForCleanOutput()) {
      await _cleanOutputDirectory(outputDir, config);
    }
  }
  await outputDir.create(recursive: true);
  final pipeline = ProcessingPipeline(
    interactiveService: ServiceContainer.instance.interactiveService,
  );
  return pipeline.execute(
    config: config,
    inputDirectory: inputDir,
    outputDirectory: outputDir,
  );
}

Future<bool> _isOutputDirectoryEmpty(
  final Directory outputDir,
  final ProcessingConfig config,
) => outputDir
    .list()
    .where((final e) => p.absolute(e.path) != p.absolute(config.inputPath))
    .isEmpty;

Future<void> _cleanOutputDirectory(
  final Directory outputDir,
  final ProcessingConfig config,
) async {
  await for (final file in outputDir.list().where(
    (final e) => p.absolute(e.path) != p.absolute(config.inputPath),
  )) {
    await file.delete(recursive: true);
  }
}

void _showResults(
  final ProcessingConfig config,
  final ProcessingResult result,
) {
  const barWidth = 50;

  print('');
  print('=' * barWidth);
  print('DONE! FREEEEEDOOOOM!!!');
  print('Some statistics for the achievement hunters:');

  if (result.creationTimesUpdated > 0) {
    print(
      '${result.creationTimesUpdated} files had their CreationDate updated',
    );
  }
  if (result.duplicatesRemoved > 0) {
    print('${result.duplicatesRemoved} duplicates were found and skipped');
  }
  if (result.coordinatesWrittenToExif > 0) {
    print(
      '${result.coordinatesWrittenToExif} files got their coordinates set in EXIF data (from json)',
    );
  }
  if (result.dateTimesWrittenToExif > 0) {
    print(
      '${result.dateTimesWrittenToExif} files got their DateTime set in EXIF data',
    );
  }
  if (result.extensionsFixed > 0) {
    print('${result.extensionsFixed} files got their extensions fixed');
  }
  if (result.extrasSkipped > 0) {
    print('${result.extrasSkipped} extras were skipped');
  }

  if (result.extractionMethodStats.isNotEmpty) {
    print('DateTime extraction method statistics:');
    for (final entry in result.extractionMethodStats.entries) {
      print('${entry.key.name}: ${entry.value} files');
    }
  }

  final totalMinutes = result.totalProcessingTime.inMinutes;
  print('In total GPTH took $totalMinutes minutes to complete');

  print('=' * barWidth);

  final exitCode = result.isSuccess ? 0 : 1;
  final exitMessage = result.isSuccess
      ? 'Processing completed successfully'
      : 'Processing completed with errors - check logs above for details';

  if (!result.isSuccess) {
    stderr.writeln('[PROCESSING_RESULT] $exitMessage');
  } else {
    print('[SUCCESS] $exitMessage');
  }

  exit(exitCode);
}
