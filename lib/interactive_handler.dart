/// Interactive mode handler for Google Photos Takeout Helper
///
/// Provides simplified function interface for interactive user sessions.
/// All UI logic is delegated to services in the domain and presentation layers.
library;

import 'dart:async';
import 'dart:io';

import 'domain/services/interactive_service_factory.dart';
import 'presentation/interactive_presenter.dart';

// Legacy exports for compatibility
export 'presentation/interactive_presenter.dart' show InteractivePresenter;

/// Whether we are running in interactive mode
bool indeed = false;

/// Global service factory for interactive mode operations
final InteractiveServiceFactory _services = InteractiveServiceFactory(
  presenter: InteractivePresenter(),
);

/// Pauses execution for specified number of seconds
Future<void> sleep(final num seconds) =>
    _services.utilityService.sleep(seconds);

/// Displays a prompt and waits for user to press enter
void pressEnterToContinue() => _services.utilityService.pressEnterToContinue();

/// Reads user input and normalizes it
Future<String> askForInt() async => _services.promptService.readUserInput();

/// Displays greeting message and introduction to the tool
Future<void> greet() async => _services.utilityService.showGreeting();

/// Shows nothing found message (does not quit explicitly)
Future<void> nothingFoundMessage() async =>
    _services.utilityService.showNothingFoundMessage();

/// Prompts user to select input directory
Future<Directory> getInputDir() async =>
    _services.fileSelectionService.selectInputDirectory();

/// Asks user for zip files with ui dialogs
Future<List<File>> getZips() async =>
    _services.fileSelectionService.selectZipFiles();

/// Prompts user to select output directory
Future<Directory> getOutput() async =>
    _services.fileSelectionService.selectOutputDirectory();

/// Asks user how to organize photos by date folders
Future<num> askDivideDates() async => _services.promptService.askDivideDates();

/// Prompts user to choose album handling behavior
Future<String> askAlbums() async => _services.promptService.askAlbums();

/// Asks user whether to clean output directory (used in cli mode as well)
Future<bool> askForCleanOutput() async =>
    _services.promptService.askForCleanOutput();

/// Asks user whether to transform Pixel Motion Photo extensions to .mp4
Future<bool> askTransformPixelMP() async =>
    _services.promptService.askTransformPixelMP();

/// Asks user whether to update creation times on Windows
Future<bool> askChangeCreationTime() async =>
    _services.promptService.askChangeCreationTime();

/// Checks free space on disk and notifies user accordingly
Future<void> freeSpaceNotice(final int required, final Directory dir) async =>
    _services.promptService.freeSpaceNotice(required, dir);

/// Unzips all zips to given folder using ZipExtractionService
Future<void> unzip(final List<File> zips, final Directory dir) async =>
    _services.zipExtractionService.extractAll(zips, dir);

/// Asks user whether to write EXIF data
Future<bool> askIfWriteExif() async => _services.promptService.askIfWriteExif();

/// Asks user whether to limit file size
Future<bool> askIfLimitFileSize() async =>
    _services.promptService.askIfLimitFileSize();

/// Asks user whether to fix incorrect file extensions
Future<String> askFixExtensions() async =>
    _services.promptService.askFixExtensions();

/// Asks user whether to unzip files or use pre-extracted directory
Future<bool> askIfUnzip() async => _services.promptService.askIfUnzip();
