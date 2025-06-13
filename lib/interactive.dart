/// This file contains code for interacting with user when launched without
/// arguments => probably with double-click
///
/// Such "interactive mode" was created because people are too dumb to use cmd
/// And I'm too lazy to create GUI <- this line is by Copilot and is true
///
/// Rules for this file functions do...:
/// - ...use sleep() to make thing live and give time to read text
/// - ...decide for themselves how much sleep() they want and where
/// - ...start and end without any extra \n, but can have \n inside
///    - extra \n are added in main file
/// - ...detect when something is wrong (f.e. disk space) and quit whole program
/// - ...are as single-job as it's appropriate - main file calls them one by one
library;

import 'dart:async';
import 'dart:io';

import 'domain/services/file_selection_service.dart';
import 'domain/services/user_prompt_service.dart';
import 'domain/services/zip_extraction_service.dart';
import 'presentation/interactive_presenter.dart';

// Legacy imports
export 'presentation/interactive_presenter.dart' show InteractivePresenter;

/// Whether we are, indeed, running interactive (or not)
bool indeed = false;

// Global presenter and service instances
final InteractivePresenter _presenter = InteractivePresenter();
final UserPromptService _promptService = UserPromptService(
  presenter: _presenter,
);

/// Pauses execution for specified number of seconds
///
/// [seconds] Number of seconds to sleep (can be fractional)
Future<void> sleep(final num seconds) =>
    Future<void>.delayed(Duration(milliseconds: (seconds * 1000).toInt()));

/// Displays a prompt and waits for user to press enter
void pressEnterToContinue() {
  _presenter.showPressEnterPrompt();
}

/// Reads user input and normalizes it (removes brackets, lowercase, trim)
///
/// Returns the normalized input string
Future<String> askForInt() async => _promptService.readUserInput();

/// Displays greeting message and introduction to the tool
Future<void> greet() async {
  await _presenter.showGreeting();
}

/// Does not quit explicitly - do it yourself
Future<void> nothingFoundMessage() async {
  await _presenter.showNothingFoundMessage();
}

/// Prompts user to select input directory using file picker dialog
///
/// Returns the selected Directory
/// Throws if dialog fails or user cancels
Future<Directory> getInputDir() async {
  final fileService = FileSelectionService(presenter: _presenter);
  return fileService.selectInputDirectory();
}

/// Asks user for zip files with ui dialogs
///
/// Returns a List of File objects representing the selected ZIP files.
Future<List<File>> getZips() async {
  final fileService = FileSelectionService(presenter: _presenter);
  return fileService.selectZipFiles();
}

/// Prompts user to select output directory using file picker dialog
///
/// Returns the selected Directory
/// Recursively asks again if dialog fails
Future<Directory> getOutput() async {
  final fileService = FileSelectionService(presenter: _presenter);
  return fileService.selectOutputDirectory();
}

/// Asks user how to organize photos by date folders
///
/// Returns:
/// - 0: One big folder
/// - 1: Year folders
/// - 2: Year/month folders
/// - 3: Year/month/day folders
Future<num> askDivideDates() async => _promptService.askDivideDates();

/// Prompts user to choose album handling behavior
///
/// Returns one of the album option keys from [albumOptions]
Future<String> askAlbums() async => _promptService.askAlbums();

// this is used in cli mode as well
Future<bool> askForCleanOutput() async => _promptService.askForCleanOutput();

/// Asks user whether to transform Pixel Motion Photo extensions to .mp4
///
/// Returns true if .MP/.MV files should be renamed to .mp4
Future<bool> askTransformPixelMP() async =>
    _promptService.askTransformPixelMP();

/// Asks user whether to update creation times on Windows
///
/// Returns true if creation times should be synced with modified times
Future<bool> askChangeCreationTime() async =>
    _promptService.askChangeCreationTime();

/// Checks free space on disk and notifies user accordingly
Future<void> freeSpaceNotice(final int required, final Directory dir) async =>
    _promptService.freeSpaceNotice(required, dir);

/// Unzips all zips to given folder (creates it if needed)
///
/// This function safely extracts all provided ZIP files to the specified directory.
/// It includes comprehensive error handling, progress reporting, and cross-platform support.
///
/// Features:
/// - Creates destination directory if it doesn't exist
/// - Validates ZIP file integrity before extraction
/// - Provides progress feedback during extraction
/// - Handles filename encoding issues across platforms
/// - Prevents path traversal attacks (Zip Slip vulnerability)
/// - Graceful error handling with user-friendly messages
///
/// [zips] List of ZIP files to extract
/// [dir] Target directory for extraction (will be created if needed)
///
/// Throws [SystemExit] with code 69 on extraction errors or path traversal attempts.
///
/// Example usage:
/// ```dart
/// final zips = await getZips();
/// final unzipDir = Directory(p.join(outputPath, '.gpth-unzipped'));
/// await unzip(zips, unzipDir);
/// ```
/// Unzips all zips to given folder using ZipExtractionService
///
/// This function delegates ZIP extraction to the dedicated ZipExtractionService
/// for better separation of concerns and reusability.
///
/// [zips] List of ZIP files to extract
/// [dir] Target directory for extraction
Future<void> unzip(final List<File> zips, final Directory dir) async {
  final zipService = ZipExtractionService(presenter: _presenter);
  await zipService.extractAll(zips, dir);
}

Future<bool> askIfWriteExif() async => _promptService.askIfWriteExif();

Future<bool> askIfLimitFileSize() async => _promptService.askIfLimitFileSize();

/// Asks user whether to fix incorrect file extensions
///
/// Returns the selected ExtensionFixingMode
Future<String> askFixExtensions() async => _promptService.askFixExtensions();

/// Asks user whether to unzip files or use pre-extracted directory
///
/// Returns true if user wants to select and unzip ZIP files,
/// false if they want to use a pre-extracted directory.
Future<bool> askIfUnzip() async => _promptService.askIfUnzip();
