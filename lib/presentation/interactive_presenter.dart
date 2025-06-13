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

  /// Shows progress update to user
  void showProgress(final String message) {
    logInfo(message, forcePrint: true);
  }

  /// Shows error message to user
  void showError(final String message) {
    logError(message);
  }

  /// Shows warning message to user
  void showWarning(final String message) {
    logWarning(message, forcePrint: true);
  }

  /// Shows success message to user
  void showSuccess(final String message) {
    logInfo(message, forcePrint: true);
  }

  /// Prompts user for yes/no confirmation
  Future<bool> confirmAction(final String prompt) async {
    print('$prompt (y/n):');

    while (true) {
      final input = await readUserInput();

      if (input == 'y' || input == 'yes') {
        return true;
      } else if (input == 'n' || input == 'no') {
        return false;
      }

      print('Please enter y (yes) or n (no):');
    }
  }

  /// Internal sleep method that respects the enableSleep setting
  Future<void> _sleep(final num seconds) async {
    if (enableSleep) {
      await Future<void>.delayed(
        Duration(milliseconds: (seconds * 1000).toInt()),
      );
    }
  }

  /// Shows completion message with statistics
  Future<void> showCompletion({
    required final int processedFiles,
    required final Duration elapsed,
    required final String outputPath,
  }) async {
    print('\n🎉 Processing completed successfully!');
    await _sleep(1);
    print('📊 Statistics:');
    print('   • Files processed: $processedFiles');
    print('   • Time elapsed: ${_formatDuration(elapsed)}');
    print('   • Output location: $outputPath');
    await _sleep(2);
    print('\n✨ Your photos are now organized and ready to use!');
    await _sleep(1);
  }

  /// Formats duration for display
  String _formatDuration(final Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    } else {
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds % 60;
      return '${minutes}m ${seconds}s';
    }
  }

  /// Shows disk space warning
  Future<void> showDiskSpaceWarning({
    required final int requiredSpaceMB,
    required final int? availableSpaceMB,
  }) async {
    showWarning('⚠️  Disk Space Warning');
    print('Required space: ${requiredSpaceMB}MB');
    if (availableSpaceMB != null) {
      print('Available space: ${availableSpaceMB}MB');
      if (availableSpaceMB < requiredSpaceMB) {
        print('❌ Insufficient disk space!');
        await _sleep(2);
        throw Exception('Insufficient disk space for operation');
      }
    }
    await _sleep(1);
  }
}
