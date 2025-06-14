/// Interactive workflow orchestrator for Google Photos Takeout Helper
///
/// Provides high-level workflow orchestration for interactive user sessions.
/// All UI logic is delegated to services in the domain and presentation layers.
library;

import 'dart:async';
import 'dart:io';

import '../domain/services/interactive_service_factory.dart';
import 'interactive_presenter.dart';

// Legacy exports for compatibility
export 'interactive_presenter.dart' show InteractivePresenter;

/// Interactive workflow controller
class InteractiveWorkflow {
  InteractiveWorkflow({final InteractivePresenter? presenter})
    : _services = InteractiveServiceFactory(
        presenter: presenter ?? InteractivePresenter(),
      );

  final InteractiveServiceFactory _services;

  /// Whether we are running in interactive mode
  bool isActive = false;

  /// Pauses execution for specified number of seconds
  Future<void> sleep(final num seconds) =>
      _services.utilityService.sleep(seconds);

  /// Displays a prompt and waits for user to press enter
  void pressEnterToContinue() =>
      _services.utilityService.pressEnterToContinue();

  /// Reads user input and normalizes it
  Future<String> askForInt() async => _services.promptService.readUserInput();

  /// Displays greeting message and introduction to the tool
  Future<void> greet() async => _services.promptService.showGreeting();

  /// Shows nothing found message (does not quit explicitly)
  Future<void> nothingFoundMessage() async =>
      _services.promptService.showNothingFoundMessage();

  /// Prompts user to select input directory
  Future<Directory> getInputDir() async =>
      _services.fileSelectionService.selectInputDirectory();

  /// Asks user for zip files with ui dialogs
  Future<List<File>> getZips() async =>
      _services.fileSelectionService.selectZipFiles();

  /// Prompts user to select output directory
  Future<Directory> getOutput() async =>
      _services.fileSelectionService.selectOutputDirectory();

  /// Ask for date division option
  Future<num> askDivideToPhotos() async =>
      _services.promptService.askDivideDates();

  /// Ask for clean output confirmation
  Future<bool> askForCleanOutput() async =>
      _services.promptService.askForCleanOutput();

  /// Ask for photo skipping option (legacy name mapping)
  Future<bool> askForSkipExtra() async =>
      _services.promptService.askForCleanOutput();

  /// Ask for duplicate copying option (legacy name mapping)
  Future<bool> askForDuplicateCopy() async =>
      _services.promptService.askForCleanOutput();

  /// Ask for album mode/option
  Future<String> askForAlbumMode() async => _services.promptService.askAlbums();

  /// Ask if user wants to write exif data
  Future<bool> askForWriteExif() async =>
      _services.promptService.askIfWriteExif();

  /// Ask if files should be copied instead of moved (legacy name mapping)
  Future<bool> askForCopyMode() async =>
      _services.promptService.askForCleanOutput();

  /// Ask for Pixel/MP file conversion option
  Future<bool> askForPixelTransform() async =>
      _services.promptService.askTransformPixelMP();

  /// Ask for creation time update option (Windows only)
  Future<bool> askForCreationTimeUpdate() async =>
      _services.promptService.askChangeCreationTime();

  /// Ask for file size limiting option
  Future<bool> askForFileSizeLimit() async =>
      _services.promptService.askIfLimitFileSize();

  /// Ask for extension fixing option
  Future<String> askForExtensionFixing() async =>
      _services.promptService.askFixExtensions();
}

// Global instance for backward compatibility
final InteractiveWorkflow _defaultWorkflow = InteractiveWorkflow();

/// Legacy global functions for backward compatibility
bool get indeed => _defaultWorkflow.isActive;
set indeed(final bool value) => _defaultWorkflow.isActive = value;

Future<void> sleep(final num seconds) => _defaultWorkflow.sleep(seconds);
void pressEnterToContinue() => _defaultWorkflow.pressEnterToContinue();
Future<String> askForInt() async => _defaultWorkflow.askForInt();
Future<void> greet() async => _defaultWorkflow.greet();
Future<void> nothingFoundMessage() async =>
    _defaultWorkflow.nothingFoundMessage();
Future<Directory> getInputDir() async => _defaultWorkflow.getInputDir();
Future<List<File>> getZips() async => _defaultWorkflow.getZips();
Future<Directory> getOutput() async => _defaultWorkflow.getOutput();
Future<num> askDivideToPhotos() async => _defaultWorkflow.askDivideToPhotos();
Future<bool> askForCleanOutput() async => _defaultWorkflow.askForCleanOutput();
Future<bool> askForSkipExtra() async => _defaultWorkflow.askForSkipExtra();
Future<bool> askForDuplicateCopy() async =>
    _defaultWorkflow.askForDuplicateCopy();
Future<String> askForAlbumMode() async => _defaultWorkflow.askForAlbumMode();
Future<bool> askForWriteExif() async => _defaultWorkflow.askForWriteExif();
Future<bool> askForCopyMode() async => _defaultWorkflow.askForCopyMode();
Future<bool> askForPixelTransform() async =>
    _defaultWorkflow.askForPixelTransform();
Future<bool> askForCreationTimeUpdate() async =>
    _defaultWorkflow.askForCreationTimeUpdate();
Future<bool> askForFileSizeLimit() async =>
    _defaultWorkflow.askForFileSizeLimit();
Future<String> askForExtensionFixing() async =>
    _defaultWorkflow.askForExtensionFixing();
