import 'dart:io';
import '../domain/services/logging_service.dart';
import '../shared/constants.dart';
import '../utils.dart' as utils;

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
    print('GooglePhotosTakeoutHelper v$version');
    await _sleep(1);
    print(
      'Hi there! This tool will help you to get all of your photos from '
      'Google Takeout to one nice tidy folder\n',
    );
    await _sleep(3);
    print(
      '(If any part confuses you, read the guide on:\n'
      'https://github.com/Xentraxx/GooglePhotosTakeoutHelper)',
    );
    await _sleep(3);
  }

  /// Shows message when no photos are found
  Future<void> showNothingFoundMessage() async {
    print('...oh :(');
    print('...');
    print("8 I couldn't find any photos :( reasons for this may be:");
    print(
      "  - you've already ran gpth and it moved all photos to output -\n"
      '    delete the input folder and re-extract the zip',
    );
    await _sleep(3);
    print(
      '  - you have a different folder structure in your takeout\n'
      '    (this often happens when downloading takeout twice)\n'
      '    try browsing your zip file and re-extracting only\n'
      '    the "Takeout/Google Photos" folder',
    );
    await _sleep(3);
  }

  /// Prompts user to press enter to continue
  void showPressEnterPrompt() {
    print('[press enter to continue]');
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
    print('How do you want to handle albums?');
    await _sleep(1);

    int index = 1;
    final options = <String>[];

    for (final entry in albumOptions.entries) {
      options.add(entry.key);
      print('[$index] ${entry.key}');
      print('    ${entry.value}');
      index++;
    }

    print('Please enter the number of your choice:');

    while (true) {
      final input = await readUserInput();
      final choice = int.tryParse(input);

      if (choice != null && choice >= 1 && choice <= options.length) {
        final selectedOption = options[choice - 1];
        print('You selected: $selectedOption');
        await _sleep(1);
        return selectedOption;
      }

      print(
        'Invalid choice. Please enter a number between 1 and ${options.length}:',
      );
    }
  }

  /// Shows directory selection prompt
  Future<Directory?> selectDirectory(final String prompt) async {
    print(prompt);
    await _sleep(1);

    // For now, delegate to file picker or manual input
    // This could be enhanced with a proper directory picker
    print('Please enter the full path to the directory:');

    final input = await readUserInput();
    if (input.isEmpty) {
      return null;
    }

    final directory = Directory(input);
    if (!await directory.exists()) {
      print('Directory does not exist: $input');
      return null;
    }

    return directory;
  }

  /// Prompts user to select input directory
  Future<void> promptForInputDirectory() async {
    print('Select the directory where you unzipped all your takeout zips');
    print('(Make sure they are merged => there is only one "Takeout" folder!)');
    if (enableSleep) await _sleep(1);
  }

  /// Shows confirmation message for input directory selection
  Future<void> showInputDirectoryConfirmation() async {
    print('Cool!');
    if (enableSleep) await _sleep(1);
  }

  /// Prompts user to select ZIP files
  Future<void> promptForZipFiles() async {
    print(
      'First, select all .zips from Google Takeout '
      '(use Ctrl to select multiple)',
    );
    if (enableSleep) await _sleep(2);
  }

  /// Shows warning for single ZIP file selection
  Future<void> showSingleZipWarning() async {
    print(
      "You selected only one zip - if that's only one you have, it's cool, "
      'but if you have multiple, Ctrl-C to exit gpth, and select them '
      '*all* again (with Ctrl)',
    );
    if (enableSleep) await _sleep(5);
  }

  /// Shows success message for ZIP selection with file count and size
  Future<void> showZipSelectionSuccess(
    final int count,
    final String totalSize,
  ) async {
    print('Cool! Selected $count zips => $totalSize');
    if (enableSleep) await _sleep(1);
  }

  /// Shows file list for debugging
  void showFileList(final List<String> fileNames) {
    print('Files: [${fileNames.join(', ')}]');
  }

  /// Prompts user to select output directory
  Future<void> promptForOutputDirectory() async {
    print(
      'Now, select output folder - all photos will be moved there\n'
      '(note: GPTH will *move* your photos - no extra space will be taken ;)',
    );
    await _sleep(1);
  }

  /// Shows confirmation message for output directory selection
  Future<void> showOutputDirectoryConfirmation() async {
    print('Cool!');
    await _sleep(1);
  }

  /// Prompts user to select date organization method
  Future<void> promptForDateDivision() async {
    print('How to organize output folder?');
    print('[1] (default) - one big folder');
    print('[2] - year folders');
    print('[3] - year/month folders');
    print('[3] - year/month/day folders');
    print('(Type a number or press enter for default):');
  }

  /// Shows selected date division option
  Future<void> showDateDivisionChoice(final String choice) async {
    print(choice);
  }

  /// Prompts user for album handling behavior
  Future<void> promptForAlbumBehavior() async {
    print('What should be done with albums?');
  }

  /// Shows album option with index and description
  void showAlbumOption(
    final int index,
    final String key,
    final String description,
  ) {
    print('[$index] $key: $description');
  }

  /// Shows selected album choice
  Future<void> showAlbumChoice(final String choice) async {
    print('Okay, doing: $choice');
  }

  /// Prompts user for output folder cleanup decision
  Future<void> promptForOutputCleanup() async {
    print('Output folder IS NOT EMPTY! What to do? Type either:');
    print('[1] - delete *all* files inside output folder and continue');
    print('[2] - continue as usual - put output files alongside existing');
    print('[3] - exit program to examine situation yourself');
  }

  /// Shows response to output cleanup choice
  Future<void> showOutputCleanupResponse(final String choice) async {
    switch (choice) {
      case '1':
        print('Okay, deleting all files inside output folder...');
        break;
      case '2':
        print('Okay, continuing as usual...');
        break;
      case '3':
        print('Okay, exiting...');
        break;
    }
  }

  /// Prompts user about Pixel Motion Photo transformation
  Future<void> promptForPixelMpTransform() async {
    print(
      'Pixel Motion Pictures are saved with the .MP or .MV '
      'extensions. Do you want to change them to .mp4 '
      'for better compatibility?',
    );
    print('[1] (default) - no, keep original extension');
    print('[2] - yes, change extension to .mp4');
    print('(Type 1 or 2 or press enter for default):');
  }

  /// Shows response to Pixel MP transformation choice
  Future<void> showPixelMpTransformResponse(final String choice) async {
    switch (choice) {
      case '1':
      case '':
        print('Okay, will keep original extension');
        break;
      case '2':
        print('Okay, will change to mp4!');
        break;
    }
  }

  /// Prompts user about creation time update
  Future<void> promptForCreationTimeUpdate() async {
    print(
      'Set the files creation time to match the modified time?\n'
      'This will only work on Windows. On other platforms, \n'
      'this option is ignored.',
    );
    print('[1] (Default) - No, don\'t update creation time');
    print('[2] - Yes, update creation time to match modified time');
    print('(Type 1 or 2, or press enter for default):');
  }

  /// Shows response to creation time update choice
  Future<void> showCreationTimeUpdateResponse(final String choice) async {
    switch (choice) {
      case '1':
      case '':
        print('Okay, will not change creation time');
        break;
      case '2':
        print('Okay, will update creation time at the end of the prorgam!');
        break;
    }
  }

  /// Prompts user about EXIF writing with ExifTool availability check
  Future<void> promptForExifWriting(final bool exifToolInstalled) async {
    if (exifToolInstalled) {
      print(
        'This mode will write Exif data (dates/times/coordinates) back to your files. '
        'To achieve the best results, download Exiftool and place it next to this executable or in your \$PATH.'
        'If you haven\'t done so yet, close this program and come back. '
        'creation times with modified times?'
        '\nNote: ONLY ON WINDOWS',
      );
    } else {
      print(
        'This mode will write Exif data (dates/times/coordinates) back to your files. '
        'We detected that ExifTool is NOT available! '
        'To achieve the best results, we strongly recomend to download Exiftool and place it next to this executable or in your \$PATH.'
        'You can download ExifTool here: https://exiftool.org '
        'Note that this mode will alter your original files, regardless of the "copy" mode.'
        'Do you want to continue with writing exif data enabled?',
      );
    }
    print('[1] (Default) - Yes, write exif');
    print('[2] - No, don\'t write to exif');
    print('(Type 1 or 2, or press enter for default):');
  }

  /// Shows response to EXIF writing choice
  Future<void> showExifWritingResponse(final String choice) async {
    switch (choice) {
      case '1':
      case '':
        print('Okay, will write to exif');
        break;
      case '2':
        print('Okay, will not touch the exif of your files!');
        break;
    }
  }

  /// Prompts user about file size limitations
  Future<void> promptForFileSizeLimit() async {
    print(
      'By default we will process all your files.'
      'However, if you have large video files and run this script on a low ram system (e.g. a NAS or your vacuum cleaning robot), you might want to '
      'limit the maximum file size to 64 MB not run out of memory. '
      'We recommend to only activate this if you run into problems.',
    );
    print('[1] (Default) - Don\'t limit me! Process everything!');
    print('[2] - I operate a Toaster. Limit supported media size to 64 MB');
    print('(Type 1 or 2, or press enter for default):');
  }

  /// Shows response to file size limit choice
  Future<void> showFileSizeLimitResponse(final String choice) async {
    switch (choice) {
      case '1':
      case '':
        print('Alrighty! Will process everything!');
        break;
      case '2':
        print('Okay! Limiting files to a size of 64 MB');
        break;
    }
  }

  /// Prompts user about extension fixing options
  Future<void> promptForExtensionFixing() async {
    print(
      'Some files from Google Photos may have incorrect extensions due to '
      'compression or web downloads. For example, a file named "photo.jpeg" '
      'might actually be a HEIF file internally. This can cause issues when '
      'writing EXIF data.',
    );
    print('');
    print('Do you want to fix incorrect file extensions?');
    print('[1] - No, keep original extensions');
    print(
      '[2] (Default) - Yes, fix extensions (skip TIFF-based files like RAW)',
    );
    print('[3] - Yes, fix extensions (skip TIFF and JPEG files)');
    print('[4] - Fix extensions then exit immediately (solo mode)');
    print('(Type 1-4 or press enter for default):');
  }

  /// Shows response to extension fixing choice
  Future<void> showExtensionFixingResponse(final String choice) async {
    switch (choice) {
      case '1':
        print('Okay, will keep original extensions');
        break;
      case '2':
      case '':
        print('Okay, will fix incorrect extensions (except TIFF-based files)');
        break;
      case '3':
        print(
          'Okay, will fix incorrect extensions (except TIFF and JPEG files)',
        );
        break;
      case '4':
        print('Okay, will fix extensions then exit immediately');
        break;
    }
  }

  /// Prompts user about data source selection (ZIP files vs extracted folder)
  Future<void> promptForDataSource() async {
    print('How would you like to provide your Google Photos Takeout data?');
    print('');
    print('[1] (Recommended) - Select ZIP files from Google Takeout');
    print('    GPTH will automatically extract and process them');
    print('    ✓ Convenient and automated');
    print('    ✓ Validates file integrity');
    print('    ✓ Handles multiple ZIP files seamlessly');
    print('');
    print('[2] - Use already extracted folder');
    print('    You have manually extracted ZIP files to a folder');
    print('    ✓ Faster if files are already extracted');
    print('    ✓ Uses less temporary disk space');
    print('    ⚠️  Requires manual extraction and merging of ZIP files');
    print('');
    print('(Type 1 or 2, or press enter for recommended option):');
  }

  /// Shows response to data source choice
  Future<void> showDataSourceResponse(final String choice) async {
    switch (choice) {
      case '1':
      case '':
        print(
          '✓ Great! You\'ll select ZIP files and GPTH will handle extraction',
        );
        break;
      case '2':
        print('✓ Okay! You\'ll select the directory with extracted files');
        break;
    }
  }

  /// Shows disk space notice with warning levels
  Future<void> showDiskSpaceNotice({
    required final int requiredSpace,
    required final String dirPath,
    final int? freeSpace,
  }) async {
    if (freeSpace == null) {
      print(
        'Note: everything will take ~${utils.filesize(requiredSpace)} of disk space - '
        'make sure you have that available on $dirPath - otherwise, '
        'Ctrl-C to exit, and make some free space!\n'
        'Or: unzip manually, remove the zips and use gpth with cmd options',
      );
    } else if (freeSpace < requiredSpace) {
      print(
        '!!! WARNING !!!\n'
        'Whole process requires ${utils.filesize(requiredSpace)} of space, but you '
        'only have ${utils.filesize(freeSpace)} available on $dirPath - \n'
        'Go make some free space!\n'
        '(Or: unzip manually, remove the zips, and use gpth with cmd options)',
      );
    } else {
      print(
        '(Note: everything will take ~${utils.filesize(requiredSpace)} of disk space - '
        'you have ${utils.filesize(freeSpace)} free so should be fine :)',
      );
    }
    await _sleep(3);
  }

  /// Shows unzip starting message
  Future<void> showUnzipStartMessage() async {
    print(
      'GPTH will now unzip all selected files, process them, and organize everything in the output folder :)',
    );
    await _sleep(1);
  }

  /// Shows progress for individual ZIP file extraction
  void showUnzipProgress(final String fileName) {
    print('Unzipping $fileName...');
  }

  /// Shows success message for individual ZIP file extraction
  void showUnzipSuccess(final String fileName) {
    print('✓ Successfully extracted $fileName');
  }

  /// Shows completion message for all ZIP files
  void showUnzipComplete() {
    print('✓ All ZIP files extracted successfully!');
  }
}
