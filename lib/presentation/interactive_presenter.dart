import 'dart:io';
import '../domain/services/logging_service.dart';
import '../shared/constants.dart';

/// Service for handling interactive user interface and console interactions
///
/// Extracted from interactive.dart to separate UI concerns from core business logic.
/// This service provides a clean interface for user interactions while maintaining
/// the same user experience as the original interactive mode.
class InteractivePresenter with LoggerMixin {
  /// Creates a new instance of InteractivePresenter
  InteractivePresenter({
    this.enableSleep = true,
    this.enableInputValidation = true,
  });

  /// Whether to use sleep delays for better UX (disable for testing)
  final bool enableSleep;

  /// Whether to validate user input (disable for testing)
  final bool enableInputValidation;

  /// Helper method for sleep delays (can be disabled for testing)
  Future<void> _sleep(final num seconds) async {
    if (enableSleep) {
      await Future<void>.delayed(
        Duration(milliseconds: (seconds * 1000).toInt()),
      );
    }
  }

  /// Album options with descriptions for user selection
  static const Map<String, String> albumOptions = <String, String>{
    'shortcut':
        '[Recommended] Album folders with shortcuts/symlinks to \n'
        'original photos. \nRecommended as it will take the least space, but \n'
        'may not be portable when moving across systems/computes/phones etc\n',
    'duplicate-copy':
        'Album folders with photos copied into them. \n'
        'This will work across all systems, but may take wayyy more space!!\n',
    'json':
        'Put ALL photos (including Archive and Trash) in one folder and \n'
        'make a .json file with info about albums. \n'
        "Use if you're a programmer, or just want to get everything, \n"
        'ignoring lack of year-folders etc.\n',
    'nothing':
        'Just ignore them and put year-photos into one folder. \n'
        'WARNING: This ignores Archive/Trash !!!\n',
    'reverse-shortcut':
        'Album folders with ORIGINAL photos. "ALL_PHOTOS" folder \n'
        'with shortcuts/symlinks to albums. If a photo is in an album, \n'
        'the original is saved. CAUTION: If a photo is in multiple albums, it will \n'
        'be duplicated in the other albums, and the shortcuts/symlinks in \n'
        '"ALL_PHOTOS" will point only to one album.\n',
  };

  /// Displays greeting message and introduction to the tool
  Future<void> showGreeting() async {
    logInfo('GooglePhotosTakeoutHelper v$version', forcePrint: true);
    await _sleep(1);
    logInfo(
      'Hi there! This tool will help you to get all of your photos from '
      'Google Takeout to one nice tidy folder\n',
      forcePrint: true,
    );
    await _sleep(3);
    logInfo(
      '(If any part confuses you, read the guide on:\n'
      'https://github.com/Xentraxx/GooglePhotosTakeoutHelper)',
      forcePrint: true,
    );
    await _sleep(3);
  }

  /// Shows message when no photos are found
  Future<void> showNothingFoundMessage() async {
    logWarning('...oh :(', forcePrint: true);
    logWarning('...', forcePrint: true);
    logWarning(
      "8 I couldn't find any photos :( reasons for this may be:",
      forcePrint: true,
    );
    logWarning(
      "  - you've already ran gpth and it moved all photos to output -\n"
      '    delete the input folder and re-extract the zip',
      forcePrint: true,
    );
    await _sleep(3);
    logWarning(
      '  - you have a different folder structure in your takeout\n'
      '    (this often happens when downloading takeout twice)\n'
      '    try browsing your zip file and re-extracting only\n'
      '    the "Takeout/Google Photos" folder',
      forcePrint: true,
    );
    await _sleep(3);
  }

  /// Prompts user to press enter to continue
  void showPressEnterPrompt() {
    logInfo('[press enter to continue]', forcePrint: true);
    stdin.readLineSync();
  }

  /// Reads user input and normalizes it
  Future<String> readUserInput() async {
    final input = stdin.readLineSync();
    if (input == null) {
      throw Exception('No input received');
    }

    return input.replaceAll('[', '').replaceAll(']', '').toLowerCase().trim();
  }

  /// Shows available album options and prompts user to select one
  Future<String> selectAlbumOption() async {
    logInfo('How do you want to handle albums?', forcePrint: true);
    await _sleep(1);

    int index = 1;
    final options = <String>[];

    for (final entry in albumOptions.entries) {
      options.add(entry.key);
      logInfo('[$index] ${entry.key}', forcePrint: true);
      logInfo('    ${entry.value}', forcePrint: true);
      index++;
    }

    logInfo('Please enter the number of your choice:', forcePrint: true);

    while (true) {
      final input = await readUserInput();
      final choice = int.tryParse(input);

      if (choice != null && choice >= 1 && choice <= options.length) {
        final selectedOption = options[choice - 1];
        logInfo('You selected: $selectedOption', forcePrint: true);
        await _sleep(1);
        return selectedOption;
      }

      logWarning(
        'Invalid choice. Please enter a number between 1 and ${options.length}:',
        forcePrint: true,
      );
    }
  }

  /// Shows directory selection prompt
  Future<Directory?> selectDirectory(final String prompt) async {
    logInfo(prompt, forcePrint: true);
    await _sleep(1);

    // For now, delegate to file picker or manual input
    // This could be enhanced with a proper directory picker
    logInfo('Please enter the full path to the directory:', forcePrint: true);

    final input = await readUserInput();
    if (input.isEmpty) {
      return null;
    }

    final directory = Directory(input);
    if (!await directory.exists()) {
      logWarning('Directory does not exist: $input', forcePrint: true);
      return null;
    }

    return directory;
  }

  /// Prompts user to select input directory
  Future<void> promptForInputDirectory() async {
    logInfo(
      'Select the directory where you unzipped all your takeout zips',
      forcePrint: true,
    );
    logInfo(
      '(Make sure they are merged => there is only one "Takeout" folder!)',
      forcePrint: true,
    );
    if (enableSleep) await _sleep(1);
  }

  /// Shows confirmation message for input directory selection
  Future<void> showInputDirectoryConfirmation() async {
    logInfo('Cool!', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts user to select ZIP files
  Future<void> promptForZipFiles() async {
    logInfo(
      'First, select all .zips from Google Takeout '
      '(use Ctrl to select multiple)',
      forcePrint: true,
    );
    if (enableSleep) await _sleep(2);
  }

  /// Shows warning for single ZIP file selection
  Future<void> showSingleZipWarning() async {
    logWarning(
      "You selected only one zip - if that's only one you have, it's cool, "
      'but if you have multiple, Ctrl-C to exit gpth, and select them '
      '*all* again (with Ctrl)',
      forcePrint: true,
    );
    if (enableSleep) await _sleep(5);
  }

  /// Shows success message for ZIP selection with file count and size
  Future<void> showZipSelectionSuccess(
    final int count,
    final String size,
  ) async {
    logInfo('Selected $count zip files ($size)', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for ZIP selection
  Future<void> showZipSelectionError() async {
    logError('No zip files selected!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid input directory
  Future<void> showInvalidInputDirectoryError() async {
    logError('Invalid input directory!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid output directory
  Future<void> showInvalidOutputDirectoryError() async {
    logError('Invalid output directory!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid album option
  Future<void> showInvalidAlbumOptionError() async {
    logError('Invalid album option!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid file option
  Future<void> showInvalidFileOptionError() async {
    logError('Invalid file option!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid date option
  Future<void> showInvalidDateOptionError() async {
    logError('Invalid date option!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid time option
  Future<void> showInvalidTimeOptionError() async {
    logError('Invalid time option!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone option
  Future<void> showInvalidTimezoneOptionError() async {
    logError('Invalid timezone option!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone format
  Future<void> showInvalidTimezoneFormatError() async {
    logError('Invalid timezone format!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone offset
  Future<void> showInvalidTimezoneOffsetError() async {
    logError('Invalid timezone offset!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone name
  Future<void> showInvalidTimezoneNameError() async {
    logError('Invalid timezone name!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone abbreviation
  Future<void> showInvalidTimezoneAbbreviationError() async {
    logError('Invalid timezone abbreviation!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone location
  Future<void> showInvalidTimezoneLocationError() async {
    logError('Invalid timezone location!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone region
  Future<void> showInvalidTimezoneRegionError() async {
    logError('Invalid timezone region!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone country
  Future<void> showInvalidTimezoneCountryError() async {
    logError('Invalid timezone country!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone continent
  Future<void> showInvalidTimezoneContinentError() async {
    logError('Invalid timezone continent!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone hemisphere
  Future<void> showInvalidTimezoneHemisphereError() async {
    logError('Invalid timezone hemisphere!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone season
  Future<void> showInvalidTimezoneSeasonError() async {
    logError('Invalid timezone season!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone daylight saving time
  Future<void> showInvalidTimezoneDSTError() async {
    logError('Invalid timezone daylight saving time!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone standard time
  Future<void> showInvalidTimezoneSTError() async {
    logError('Invalid timezone standard time!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone offset change
  Future<void> showInvalidTimezoneOffsetChangeError() async {
    logError('Invalid timezone offset change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone name change
  Future<void> showInvalidTimezoneNameChangeError() async {
    logError('Invalid timezone name change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone abbreviation change
  Future<void> showInvalidTimezoneAbbreviationChangeError() async {
    logError('Invalid timezone abbreviation change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone location change
  Future<void> showInvalidTimezoneLocationChangeError() async {
    logError('Invalid timezone location change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone region change
  Future<void> showInvalidTimezoneRegionChangeError() async {
    logError('Invalid timezone region change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone country change
  Future<void> showInvalidTimezoneCountryChangeError() async {
    logError('Invalid timezone country change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone continent change
  Future<void> showInvalidTimezoneContinentChangeError() async {
    logError('Invalid timezone continent change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone hemisphere change
  Future<void> showInvalidTimezoneHemisphereChangeError() async {
    logError('Invalid timezone hemisphere change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone season change
  Future<void> showInvalidTimezoneSeasonChangeError() async {
    logError('Invalid timezone season change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone daylight saving time change
  Future<void> showInvalidTimezoneDSTChangeError() async {
    logError('Invalid timezone daylight saving time change!');
    if (enableSleep) await _sleep(1);
  }

  /// Shows error message for invalid timezone standard time change
  Future<void> showInvalidTimezoneSTChangeError() async {
    logError('Invalid timezone standard time change!');
    if (enableSleep) await _sleep(1);
  }

  /// Prompts user to select output directory
  Future<void> promptForOutputDirectory() async {
    logInfo(
      'Select the directory where you want to save your photos',
      forcePrint: true,
    );
    if (enableSleep) await _sleep(1);
  }

  /// Shows confirmation message for output directory selection
  Future<void> showOutputDirectoryConfirmation() async {
    logInfo('Great!', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows list of files to be processed
  Future<void> showFileList(final List<String> files) async {
    logInfo('Files to be processed:', forcePrint: true);
    for (final file in files) {
      logInfo('  - $file', forcePrint: true);
    }
    if (enableSleep) await _sleep(1);
  }

  /// Prompts user to select date division option
  Future<void> promptForDateDivision() async {
    logInfo('How do you want to divide your photos by date?', forcePrint: true);
    logInfo('1. By year', forcePrint: true);
    logInfo('2. By year and month', forcePrint: true);
    logInfo('3. By year, month, and day', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows the selected date division choice
  Future<void> showDateDivisionChoice(final String choice) async {
    logInfo('You selected: $choice', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts user to select album behavior
  Future<void> promptForAlbumBehavior() async {
    logInfo('How do you want to handle albums?', forcePrint: true);
    logInfo(
      '1. Create album folders with shortcuts to original photos',
      forcePrint: true,
    );
    logInfo('2. Create album folders with copied photos', forcePrint: true);
    logInfo(
      '3. Create a single folder with all photos and a JSON file for album info',
      forcePrint: true,
    );
    logInfo(
      '4. Ignore albums and put all photos in one folder',
      forcePrint: true,
    );
    if (enableSleep) await _sleep(1);
  }

  /// Shows an album option to the user
  void showAlbumOption(final int index, final String key, final String value) {
    logInfo('[$index] $key: $value', forcePrint: true);
  }

  /// Shows the selected album choice
  Future<void> showAlbumChoice(final String choice) async {
    logInfo('You selected album option: $choice', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for output cleanup
  Future<void> promptForOutputCleanup() async {
    logInfo(
      'Do you want to clean the output directory before proceeding?',
      forcePrint: true,
    );
    logInfo('1. Yes', forcePrint: true);
    logInfo('2. No', forcePrint: true);
    logInfo('3. Quit', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows output cleanup response
  Future<void> showOutputCleanupResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for Pixel MP transform
  Future<void> promptForPixelMpTransform() async {
    logInfo(
      'Do you want to transform Pixel Motion Photo extensions to .mp4?',
      forcePrint: true,
    );
    logInfo('1. No', forcePrint: true);
    logInfo('2. Yes', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows Pixel MP transform response
  Future<void> showPixelMpTransformResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for creation time update
  Future<void> promptForCreationTimeUpdate() async {
    logInfo(
      'Do you want to update creation times on Windows?',
      forcePrint: true,
    );
    logInfo('1. No', forcePrint: true);
    logInfo('2. Yes', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows creation time update response
  Future<void> showCreationTimeUpdateResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for EXIF writing
  Future<void> promptForExifWriting(final bool exifToolInstalled) async {
    logInfo('Do you want to write EXIF data to your photos?', forcePrint: true);
    logInfo('1. Yes', forcePrint: true);
    logInfo('2. No', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows EXIF writing response
  Future<void> showExifWritingResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for file size limit
  Future<void> promptForFileSizeLimit() async {
    logInfo('Do you want to set a file size limit?', forcePrint: true);
    logInfo('1. No', forcePrint: true);
    logInfo('2. Yes', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows file size limit response
  Future<void> showFileSizeLimitResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for extension fixing
  Future<void> promptForExtensionFixing() async {
    logInfo('Do you want to fix file extensions?', forcePrint: true);
    logInfo('1. Standard', forcePrint: true);
    logInfo('2. Conservative', forcePrint: true);
    logInfo('3. Solo', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows extension fixing response
  Future<void> showExtensionFixingResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Prompts for data source
  Future<void> promptForDataSource() async {
    logInfo('Select your data source:', forcePrint: true);
    logInfo('1. Google Takeout', forcePrint: true);
    logInfo('2. Local Backup', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows data source response
  Future<void> showDataSourceResponse(final String answer) async {
    logInfo('You selected: $answer', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows disk space notice
  Future<void> showDiskSpaceNotice(final String message) async {
    logInfo('Disk space notice: $message', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows unzip start message
  Future<void> showUnzipStartMessage() async {
    logInfo('Starting unzip process...', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows unzip progress
  Future<void> showUnzipProgress(final String fileName) async {
    logInfo('Unzipping: $fileName', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows unzip success
  Future<void> showUnzipSuccess(final String fileName) async {
    logInfo('Successfully unzipped: $fileName', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }

  /// Shows unzip complete
  Future<void> showUnzipComplete() async {
    logInfo('Unzip process complete.', forcePrint: true);
    if (enableSleep) await _sleep(1);
  }
}
