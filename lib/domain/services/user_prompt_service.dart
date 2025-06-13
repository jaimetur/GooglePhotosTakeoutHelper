import 'dart:io';

import '../../presentation/interactive_presenter.dart';
import '../../utils.dart';
import '../services/global_config_service.dart';
import 'logging_service.dart';

/// Service for handling user configuration prompts and input validation
///
/// This service provides a clean interface for collecting user preferences
/// and configuration options in interactive mode.
class UserPromptService with LoggerMixin {
  /// Creates a new instance of UserPromptService
  UserPromptService({
    required this.globalConfig,
    final InteractivePresenter? presenter,
  }) : _presenter = presenter ?? InteractivePresenter();

  final GlobalConfigService globalConfig;
  final InteractivePresenter _presenter;

  /// Reads user input and normalizes it (removes brackets, lowercase, trim)
  ///
  /// Returns the normalized input string
  Future<String> readUserInput() async => _presenter.readUserInput();

  /// Asks user how to organize photos by date folders
  ///
  /// Returns:
  /// - 0: One big folder
  /// - 1: Year folders
  /// - 2: Year/month folders
  /// - 3: Year/month/day folders
  Future<num> askDivideDates() async {
    await _presenter.promptForDateDivision();
    final String answer = await readUserInput();
    switch (answer) {
      case '1':
      case '':
        await _presenter.showDateDivisionChoice('Selected one big folder');
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
        logError('Invalid answer - try again');
        return askDivideDates();
    }
  }

  /// Prompts user to choose album handling behavior
  ///
  /// Returns one of the album option keys from [albumOptions]
  ///
  /// Available album modes:
  ///
  /// - **shortcut**: Creates shortcuts/symlinks from album folders to the main file in ALL_PHOTOS.
  ///   The original file is moved to ALL_PHOTOS, and shortcuts are created in album folders.
  ///   This saves space while maintaining album organization.
  ///
  /// - **duplicate-copy**: Creates actual copies of files in both ALL_PHOTOS and album folders.
  ///   Each file appears in ALL_PHOTOS and in every album it belongs to as separate physical files.
  ///   Uses more disk space but provides complete independence between folders.
  ///
  /// - **reverse-shortcut**: The opposite of shortcut mode. Files remain in album folders,
  ///   and shortcuts are created in ALL_PHOTOS pointing to the album locations.
  ///   Maintains files in their album context while providing access via ALL_PHOTOS.
  ///
  /// - **json**: Creates a single ALL_PHOTOS folder with all files, plus an albums-info.json
  ///   file that contains metadata about which albums each file belonged to.
  ///   Most space-efficient option with programmatic album information.
  ///
  /// - **nothing**: Ignores albums entirely. Only creates ALL_PHOTOS folder with files
  ///   from year folders. Album-only files are skipped unless they have null keys assigned.
  ///   Simplest option for users who don't care about album organization.
  Future<String> askAlbums() async {
    await _presenter.promptForAlbumBehavior();
    int i = 0;
    for (final MapEntry<String, String> entry
        in InteractivePresenter.albumOptions.entries) {
      _presenter.showAlbumOption(i++, entry.key, entry.value);
    }
    final int? answer = int.tryParse(await readUserInput());
    if (answer == null ||
        answer < 0 ||
        answer >= InteractivePresenter.albumOptions.length) {
      logError('Invalid answer - try again');
      return askAlbums();
    }
    final String choice = InteractivePresenter.albumOptions.keys.elementAt(
      answer,
    );
    await _presenter.showAlbumChoice(choice);
    return choice;
  }

  /// Asks user about output directory cleanup
  Future<bool> askForCleanOutput() async {
    await _presenter.promptForOutputCleanup();
    final String answer = stdin
        .readLineSync()!
        .replaceAll('[', '')
        .replaceAll(']', '')
        .toLowerCase()
        .trim();
    await _presenter.showOutputCleanupResponse(answer);
    switch (answer) {
      case '1':
        return true;
      case '2':
        return false;
      case '3':
        logger.quit(0);
      default:
        logError('Invalid answer - try again');
        return askForCleanOutput();
    }
  }

  /// Asks user whether to transform Pixel Motion Photo extensions to .mp4
  ///
  /// Returns true if .MP/.MV files should be renamed to .mp4
  Future<bool> askTransformPixelMP() async {
    await _presenter.promptForPixelMpTransform();
    final String answer = await readUserInput();
    await _presenter.showPixelMpTransformResponse(answer);
    switch (answer) {
      case '1':
      case '':
        return false;
      case '2':
        return true;
      default:
        logError('Invalid answer - try again');
        return askTransformPixelMP();
    }
  }

  /// Asks user whether to update creation times on Windows
  ///
  /// Returns true if creation times should be synced with modified times
  Future<bool> askChangeCreationTime() async {
    await _presenter.promptForCreationTimeUpdate();
    final String answer = await readUserInput();
    await _presenter.showCreationTimeUpdateResponse(answer);
    switch (answer) {
      case '1':
      case '':
        return false;
      case '2':
        return true;
      default:
        logError('Invalid answer - try again');
        return askChangeCreationTime();
    }
  }

  /// Asks user about EXIF writing configuration
  Future<bool> askIfWriteExif() async {
    await _presenter.promptForExifWriting(globalConfig.exifToolInstalled);
    final String answer = await readUserInput();
    await _presenter.showExifWritingResponse(answer);
    switch (answer) {
      case '1':
      case '':
        return true;
      case '2':
        return false;
      default:
        logError('Invalid answer - try again');
        return askIfWriteExif();
    }
  }

  /// Asks user about file size limitations
  Future<bool> askIfLimitFileSize() async {
    await _presenter.promptForFileSizeLimit();
    final String answer = await readUserInput();
    await _presenter.showFileSizeLimitResponse(answer);
    switch (answer) {
      case '1':
      case '':
        return false;
      case '2':
        return true;
      default:
        logError('Invalid answer - try again');
        return askIfLimitFileSize();
    }
  }

  /// Asks user whether to fix incorrect file extensions
  ///
  /// Returns the selected ExtensionFixingMode
  Future<String> askFixExtensions() async {
    await _presenter.promptForExtensionFixing();
    final String answer = await readUserInput();
    await _presenter.showExtensionFixingResponse(answer);
    switch (answer) {
      case '1':
        return 'none';
      case '2':
      case '':
        return 'standard';
      case '3':
        return 'conservative';
      case '4':
        return 'solo';
      default:
        logError('Invalid answer - try again');
        return askFixExtensions();
    }
  }

  /// Asks user whether to unzip files or use pre-extracted directory
  ///
  /// This function provides users with a choice between:
  /// 1. Selecting ZIP files from Google Takeout for automatic extraction
  /// 2. Using a directory where ZIP files have already been manually extracted
  ///
  /// Returns true if user wants to select and unzip ZIP files,
  /// false if they want to use a pre-extracted directory.
  ///
  /// Example usage:
  /// ```dart
  /// final shouldUnzip = await askIfUnzip();
  /// if (shouldUnzip) {
  ///   final zips = await getZips();
  ///   await unzip(zips, outputDir);
  /// } else {
  ///   final inputDir = await getInputDir();
  /// }
  /// ```
  Future<bool> askIfUnzip() async {
    await _presenter.promptForDataSource();
    final String answer = await readUserInput();
    await _presenter.showDataSourceResponse(answer);
    switch (answer) {
      case '1':
      case '':
        return true;
      case '2':
        return false;
      default:
        logError('Invalid answer - please type 1 or 2');
        return askIfUnzip();
    }
  }

  /// Checks free space on disk and notifies user accordingly
  ///
  /// This function calculates available disk space and compares it with the required space
  /// for the unzipping operation. It provides warnings or errors if insufficient space is available.
  ///
  /// [required] The required space in bytes for the operation
  /// [dir] The target directory to check space for
  ///
  /// Exits the program with code 69 if insufficient space is detected.
  ///
  /// Example usage:
  /// ```dart
  /// final requiredSpace = totalZipSize * 2 + (256 * 1024 * 1024); // ZIP size * 2 + 256MB buffer
  /// await freeSpaceNotice(requiredSpace, outputDirectory);
  /// ```
  Future<void> freeSpaceNotice(final int required, final Directory dir) async {
    final int? freeSpace = await getDiskFree(dir.path);
    await _presenter.showDiskSpaceNotice(
      'Required: $required, Directory: ${dir.path}, Free: $freeSpace',
    );

    if (freeSpace != null && freeSpace < required) {
      logger.quit(69);
    }

    _presenter.showPressEnterPrompt();
  }

  /// Returns available disk space in bytes for the given path
  Future<int?> getDiskFree(final String path) => Future.value();
}
