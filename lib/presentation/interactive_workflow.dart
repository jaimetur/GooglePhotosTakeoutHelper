/// Interactive workflow orchestrator for Google Photos Takeout Helper
///
/// Provides high-level workflow orchestration for interactive user sessions.
/// This class serves as a facade that delegates all functionality to the
/// ConsolidatedInteractiveService through the ServiceContainer.
library;

import 'dart:io';
import '../domain/services/consolidated_interactive_service.dart';
import '../domain/services/service_container.dart';

/// Interactive workflow controller
///
/// This class provides a clean interface to the consolidated interactive service.
/// All actual implementation is delegated to ConsolidatedInteractiveService,
/// accessed through the ServiceContainer singleton.
class InteractiveWorkflow {
  /// Creates a new InteractiveWorkflow instance
  const InteractiveWorkflow();

  /// Gets the consolidated interactive service instance
  static ConsolidatedInteractiveService get _service =>
      ServiceContainer.instance.interactiveService;

  /// Whether we are running in interactive mode
  static bool isActive = false;

  /// Pauses execution for specified number of seconds
  static Future<void> sleep(final num seconds) => _service.sleep(seconds);

  /// Displays a prompt and waits for user to press enter
  static void pressEnterToContinue() => _service.pressEnterToContinue();

  /// Reads user input and normalizes it
  static Future<String> readUserInput() => _service.readUserInput();

  /// Displays greeting message and introduction to the tool
  static Future<void> showGreeting() => _service.showGreeting();

  /// Shows nothing found message
  static Future<void> showNothingFoundMessage() =>
      _service.showNothingFoundMessage();

  /// Prompts user to select input directory
  static Future<Directory> selectInputDirectory() =>
      _service.selectInputDirectory();

  /// Prompts user to select ZIP files for extraction
  static Future<List<File>> selectZipFiles() => _service.selectZipFiles();

  /// Prompts user to select output directory
  static Future<Directory> selectOutputDirectory() =>
      _service.selectOutputDirectory();

  /// Ask for date division option
  static Future<int> askDivideDates() => _service.askDivideDates();

  /// Ask for clean output confirmation
  static Future<bool> askForCleanOutput() => _service.askForCleanOutput();

  /// Ask for album mode/option
  static Future<String> askAlbums() => _service.askAlbums();

  /// Ask if user wants to write exif data
  static Future<bool> askIfWriteExif() => _service.askIfWriteExif();

  /// Ask for Pixel/MP file conversion option
  static Future<bool> askTransformPixelMP() => _service.askTransformPixelMP();

  /// Ask for creation time update option (Windows only)
  static Future<bool> askChangeCreationTime() =>
      _service.askChangeCreationTime();

  /// Ask for file size limiting option
  static Future<bool> askIfLimitFileSize() => _service.askIfLimitFileSize();

  /// Ask for extension fixing option
  static Future<String> askFixExtensions() => _service.askFixExtensions();

  /// Ask if user wants to unzip files
  static Future<bool> askIfUnzip() => _service.askIfUnzip();

  /// Prompts for user input with a custom message
  static Future<String> promptUser(final String message) =>
      _service.promptUser(message);

  /// Asks a yes/no question and returns boolean result
  static Future<bool> askYesNo(final String question) =>
      _service.askYesNo(question);
}
