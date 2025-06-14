import 'dart:async';
import 'dart:io';

import 'package:file_picker_desktop/file_picker_desktop.dart';

import '../../presentation/interactive_presenter.dart';
import '../models/processing_config_model.dart';
import '../services/global_config_service.dart';
import '../services/logging_service.dart';
import '../services/service_container.dart';
import '../services/zip_extraction_service.dart';
import 'consolidated_utility_service.dart';

/// Consolidated interactive service that combines all user interaction functionality
///
/// This service consolidates functionality from:
/// - InteractiveUtilityService (sleep, pressEnter)
/// - UserPromptService (user input, prompts)
/// - InteractiveConfigurationService (validation logic)
/// - FileSelectionService (file/directory selection)
///
/// Provides a clean, single interface for all interactive operations.
class ConsolidatedInteractiveService with LoggerMixin {
  /// Creates a new ConsolidatedInteractiveService
  ConsolidatedInteractiveService({
    required this.globalConfig,
    final InteractivePresenter? presenter,
  }) : _presenter = presenter ?? InteractivePresenter(),
       _utility = const ConsolidatedUtilityService();

  final GlobalConfigService globalConfig;
  final InteractivePresenter _presenter;
  final ConsolidatedUtilityService _utility;

  // ============================================================================
  // UTILITY OPERATIONS (from InteractiveUtilityService)
  // ============================================================================

  /// Pauses execution for specified number of seconds
  ///
  /// [seconds] Number of seconds to sleep (can be fractional)
  Future<void> sleep(final num seconds) =>
      Future<void>.delayed(Duration(milliseconds: (seconds * 1000).toInt()));

  /// Displays a prompt and waits for user to press enter
  void pressEnterToContinue() {
    _presenter.showPressEnterPrompt();
  }
  // ============================================================================
  // USER INPUT OPERATIONS (from UserPromptService)
  // ============================================================================

  /// Reads user input and normalizes it (removes brackets, lowercase, trim)
  Future<String> readUserInput() async => _presenter.readUserInput();

  /// Asks user how to organize photos by date folders
  ///
  /// Returns:
  /// - 0: One big folder
  /// - 1: Year folders
  /// - 2: Year/month folders
  /// - 3: Year/month/day folders
  Future<int> askDivideDates() async {
    await _presenter.promptForDateDivision();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '1':
        case '':
          await _presenter.showDateDivisionChoice(
            'Will put all photos into one folder',
          );
          return 0;
        case '2':
          await _presenter.showDateDivisionChoice('Will divide by year');
          return 1;
        case '3':
          await _presenter.showDateDivisionChoice(
            'Will divide by year and month',
          );
          return 2;
        case '4':
          await _presenter.showDateDivisionChoice(
            'Will divide by year, month, and day',
          );
          return 3;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks user about album behavior preference
  ///
  /// Returns the selected album behavior option key
  Future<String> askAlbums() async {
    await _presenter.promptForAlbumBehavior();
    int i = 0;
    for (final MapEntry<String, String> entry
        in InteractivePresenter.albumOptions.entries) {
      _presenter.showAlbumOption(i++, entry.key, entry.value);
    }

    while (true) {
      final int? answer = int.tryParse(await readUserInput());
      if (answer != null &&
          answer >= 0 &&
          answer < InteractivePresenter.albumOptions.length) {
        final String choice = InteractivePresenter.albumOptions.keys.elementAt(
          answer,
        );
        await _presenter.showAlbumChoice(choice);
        return choice;
      }
      await _presenter.showInvalidAnswerError();
    }
  }

  /// Asks if user wants to clean output directory
  Future<bool> askForCleanOutput() async {
    await _presenter.promptForOutputCleanup();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
          await _presenter.showOutputCleanupResponse(input);
          return true;
        case 'n':
        case 'no':
          await _presenter.showOutputCleanupResponse(input);
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to transform Pixel motion photos
  Future<bool> askTransformPixelMP() async {
    await _presenter.promptForPixelMpTransform();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
          await _presenter.showPixelMpTransformResponse(input);
          return true;
        case 'n':
        case 'no':
        case '':
          await _presenter.showPixelMpTransformResponse(input);
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to change file creation time
  Future<bool> askChangeCreationTime() async {
    await _presenter.promptForCreationTimeUpdate();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
          await _presenter.showCreationTimeUpdateResponse(input);
          return true;
        case 'n':
        case 'no':
        case '':
          await _presenter.showCreationTimeUpdateResponse(input);
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to write EXIF data
  Future<bool> askIfWriteExif() async {
    await _presenter.promptForExifWriting(globalConfig.exifToolInstalled);

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
        case '':
          await _presenter.showExifWritingResponse(input);
          return true;
        case 'n':
        case 'no':
          await _presenter.showExifWritingResponse(input);
          return false;
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to limit file sizes
  Future<bool> askIfLimitFileSize() async {
    await _presenter.promptForFileSizeLimit();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case 'y':
        case 'yes':
          await _presenter.showFileSizeLimitResponse(input);
          return true;
        case 'n':
        case 'no':
        case '':
          await _presenter.showFileSizeLimitResponse(input);
          return false;
        default:
          await _presenter.showInvalidAnswerError('Invalid answer - try again');
          continue;
      }
    }
  }

  /// Asks about extension fixing mode
  Future<String> askFixExtensions() async {
    await _presenter.promptForExtensionFixing();

    while (true) {
      final input = await readUserInput();
      switch (input) {
        case '0':
        case '':
        case 'standard':
          return 'standard';
        case '1':
        case 'conservative':
          return 'conservative';
        case '2':
        case 'solo':
          return 'solo';
        case '3':
        case 'none':
          return 'none';
        default:
          await _presenter.showInvalidAnswerError();
          continue;
      }
    }
  }

  /// Asks if user wants to unzip files
  Future<bool> askIfUnzip() async {
    await _presenter.promptForDataSource();

    while (true) {
      final input = await readUserInput();
      await _presenter.showDataSourceResponse(input);

      switch (input) {
        case '1':
        case '':
          return true;
        case '2':
          return false;
        default:
          await _presenter.showInvalidAnswerError(
            'Invalid answer - please type 1 or 2',
          );
          continue;
      }
    }
  }

  /// Prompts for user input with a custom message
  Future<String> promptUser(final String message) async {
    logInfo(message, forcePrint: true);
    return readUserInput();
  }

  /// Asks a yes/no question and returns boolean result
  Future<bool> askYesNo(final String question) async {
    logInfo('$question (y/n)', forcePrint: true);
    while (true) {
      final input = await readUserInput();
      if (input.startsWith('y')) return true;
      if (input.startsWith('n')) return false;
      logWarning('Please enter y or n:', forcePrint: true);
    }
  }

  /// Shows greeting and introduction
  Future<void> showGreeting() async {
    await _presenter.showGreeting();
  }

  /// Shows "nothing found" message
  Future<void> showNothingFoundMessage() async {
    await _presenter.showNothingFoundMessage();
  }

  /// Shows a disk space notice and checks if enough space is available
  ///
  /// [required] Required space in bytes
  /// [dir] Directory to check space for
  Future<void> freeSpaceNotice(final int required, final Directory dir) async {
    final int? freeSpace = await ServiceContainer.instance.diskSpaceService
        .getAvailableSpace(dir.path);

    await _presenter.showDiskSpaceNotice(
      'Required: ${_utility.formatFileSize(required)}, '
      'Directory: ${dir.path}, '
      'Free: ${freeSpace != null ? _utility.formatFileSize(freeSpace) : 'Unknown'}',
    );

    if (freeSpace != null && freeSpace < required) {
      logError('Insufficient disk space available');
      exit(69);
    }

    _presenter.showPressEnterPrompt();
  }

  // ============================================================================
  // ZIP EXTRACTION OPERATIONS
  // ============================================================================
  /// Extracts all ZIP files to output directory
  ///
  /// [zipFiles] List of ZIP files to extract
  /// [outputDirectory] Directory to extract to
  Future<Directory> extractAll(
    final List<File> zipFiles,
    final Directory outputDirectory,
  ) async {
    // Delegate to the existing ZIP extraction service for now
    final zipService = ZipExtractionService(presenter: _presenter);
    await zipService.extractAll(zipFiles, outputDirectory);
    return outputDirectory;
  }

  // ============================================================================
  // FILE/DIRECTORY SELECTION (from FileSelectionService)
  // ============================================================================
  /// Prompts user to select input directory using file picker dialog
  Future<Directory> selectInputDirectory() async {
    await _presenter.promptForInputDirectory();
    _presenter.showPressEnterPrompt();

    try {
      final String? selectedPath = await _showDirectoryPicker(
        'Select Google Photos Takeout folder',
      );

      if (selectedPath == null) {
        throw Exception('No directory selected');
      }

      final directory = Directory(selectedPath);
      final validation = _utility.validateDirectory(directory);

      if (validation.isFailure) {
        throw Exception(validation.message);
      }

      return directory;
    } catch (e) {
      logError('Failed to select input directory: $e');
      rethrow;
    }
  }

  /// Prompts user to select output directory
  Future<Directory> selectOutputDirectory() async {
    await _presenter.promptForOutputDirectory();
    _presenter.showPressEnterPrompt();

    try {
      final String? selectedPath = await _showDirectoryPicker(
        'Select output folder for organized photos',
      );

      if (selectedPath == null) {
        throw Exception('No directory selected');
      }

      final directory = Directory(selectedPath);

      // Create directory if it doesn't exist
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }

      return directory;
    } catch (e) {
      logError('Failed to select output directory: $e');
      rethrow;
    }
  }

  /// Prompts user to select ZIP files for extraction
  Future<List<File>> selectZipFiles() async {
    await _presenter.promptForZipFiles();
    _presenter.showPressEnterPrompt();

    try {
      final FilePickerResult? filePickerResult = await _showFilesPicker(
        'Select Google Photos Takeout ZIP files',
        allowedExtensions: ['zip'],
      );
      if (filePickerResult == null || filePickerResult.files.isEmpty) {
        await _presenter.showZipSelectionError();
        throw Exception('No ZIP files selected');
      }

      final files = filePickerResult.files
          .map((final PlatformFile e) => File(e.path!))
          .toList();

      // Validate all files exist and are accessible
      for (final file in files) {
        final validation = _utility.validateFile(file);
        if (validation.isFailure) {
          throw Exception('Invalid ZIP file: ${validation.message}');
        }
      }

      // Show appropriate user feedback based on file count
      final totalSize = files.fold<int>(
        0,
        (final sum, final file) => sum + file.lengthSync(),
      );

      if (files.length == 1) {
        await _presenter.showSingleZipWarning();
      }

      await _presenter.showZipSelectionSuccess(
        files.length,
        _utility.formatFileSize(totalSize),
      );

      return files;
    } catch (e) {
      logError('Failed to select ZIP files: $e');
      rethrow;
    }
  }

  /// Prompts user to select extraction directory for ZIP files
  Future<Directory> selectExtractionDirectory() async {
    await _presenter.promptForExtractionDirectory();
    _presenter.showPressEnterPrompt();

    try {
      final String? selectedPath = await _showDirectoryPicker(
        'Select the folder to extract the ZIP files to',
      );

      if (selectedPath == null) {
        throw Exception('No directory selected');
      }

      final directory = Directory(selectedPath);

      // Create directory if it doesn't exist
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }

      return directory;
    } catch (e) {
      logError('Failed to select extraction directory: $e');
      rethrow;
    }
  }

  // ============================================================================
  // CONFIGURATION BUILDING (from InteractiveConfigurationService)
  // ============================================================================

  /// Creates processing configuration from user choices
  ProcessingConfig createProcessingConfig({
    required final String inputPath,
    required final String outputPath,
    required final DateDivisionLevel dateDivision,
    required final AlbumBehavior albumBehavior,
    required final bool copyMode,
    required final bool transformPixelMp,
    required final bool updateCreationTime,
    required final bool writeExif,
    required final bool limitFileSize,
    required final ExtensionFixingMode extensionFixing,
    final bool verbose = false,
    final bool skipExtras = false,
    final bool guessFromName = true,
  }) => ProcessingConfig(
    inputPath: inputPath,
    outputPath: outputPath,
    dateDivision: dateDivision,
    albumBehavior: albumBehavior,
    copyMode: copyMode,
    transformPixelMp: transformPixelMp,
    updateCreationTime: updateCreationTime,
    writeExif: writeExif,
    limitFileSize: limitFileSize,
    extensionFixing: extensionFixing,
    verbose: verbose,
    skipExtras: skipExtras,
    guessFromName: guessFromName,
  );

  /// Validates input directory for processing
  ValidationResult validateInputDirectory(final String path) {
    final directory = Directory(path);

    if (!directory.existsSync()) {
      return ValidationResult.failure('Input directory does not exist: $path');
    }

    // Check if directory contains Google Photos takeout structure
    final hasPhotosFolder = Directory('$path/Google Photos').existsSync();
    final hasPhotosFolders = directory.listSync().whereType<Directory>().any(
      (final dir) => dir.path.contains('Photos from'),
    );

    if (!hasPhotosFolder && !hasPhotosFolders) {
      return const ValidationResult.failure(
        'Directory does not appear to contain Google Photos takeout data',
      );
    }

    return const ValidationResult.success();
  }

  /// Validates output directory for processing
  ValidationResult validateOutputDirectory(final String path) {
    final directory = Directory(path);

    // Create directory if it doesn't exist
    if (!directory.existsSync()) {
      try {
        directory.createSync(recursive: true);
        return const ValidationResult.success();
      } catch (e) {
        return ValidationResult.failure('Cannot create output directory: $e');
      }
    }

    return const ValidationResult.success();
  }

  // ============================================================================
  // PRIVATE HELPER METHODS
  // ============================================================================

  /// Shows platform-specific directory picker dialog
  Future<String?> _showDirectoryPicker(final String title) async =>
      getDirectoryPath(dialogTitle: title);

  /// Shows platform-specific file picker dialog
  Future<FilePickerResult?> _showFilesPicker(
    final String title, {
    final List<String>? allowedExtensions,
  }) async => pickFiles(
    dialogTitle: title,
    type: FileType.custom,
    allowedExtensions: allowedExtensions,
    allowMultiple: true,
  );
}

/// Extension methods for enum conversion
extension AlbumBehaviorExtension on AlbumBehavior {
  static AlbumBehavior fromString(final String value) {
    switch (value.toLowerCase()) {
      case 'shortcut':
        return AlbumBehavior.shortcut;
      case 'duplicate-copy':
        return AlbumBehavior.duplicateCopy;
      case 'json':
        return AlbumBehavior.json;
      case 'nothing':
        return AlbumBehavior.nothing;
      case 'reverse-shortcut':
        return AlbumBehavior.reverseShortcut;
      default:
        throw ArgumentError('Unknown album behavior: $value');
    }
  }
}

extension ExtensionFixingModeExtension on ExtensionFixingMode {
  static ExtensionFixingMode fromString(final String value) {
    switch (value.toLowerCase()) {
      case 'none':
        return ExtensionFixingMode.none;
      case 'standard':
        return ExtensionFixingMode.standard;
      case 'conservative':
        return ExtensionFixingMode.conservative;
      case 'solo':
        return ExtensionFixingMode.solo;
      default:
        throw ArgumentError('Unknown extension fixing mode: $value');
    }
  }
}
