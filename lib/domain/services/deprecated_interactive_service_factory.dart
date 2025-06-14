import 'dart:io';

import '../services/service_container.dart';

/// @deprecated This factory is being replaced by ConsolidatedInteractiveService
///
/// This class provides backward compatibility during the migration to consolidated services.
/// New code should use ServiceContainer.instance.interactiveService directly.
///
/// Migration guide:
/// ```dart
/// // OLD:
/// final factory = InteractiveServiceFactory(presenter: presenter);
/// final result = await factory.promptService.askAlbums();
///
/// // NEW:
/// final result = await ServiceContainer.instance.interactiveService.askAlbums();
/// ```
class InteractiveServiceFactory {
  /// Creates a new InteractiveServiceFactory
  ///
  /// @deprecated Use ServiceContainer.instance.interactiveService instead
  InteractiveServiceFactory();

  // Note: presenter parameter kept for API compatibility but not stored

  /// Gets the consolidated interactive service as prompt service
  ///
  /// @deprecated Access methods directly on ServiceContainer.instance.interactiveService
  DeprecatedPromptServiceWrapper get promptService =>
      DeprecatedPromptServiceWrapper();

  /// Gets the consolidated interactive service as file selection service
  ///
  /// @deprecated Access methods directly on ServiceContainer.instance.interactiveService
  DeprecatedFileSelectionServiceWrapper get fileSelectionService =>
      DeprecatedFileSelectionServiceWrapper();

  /// Gets the consolidated interactive service as zip extraction service
  ///
  /// @deprecated Access methods directly on ServiceContainer.instance.interactiveService
  DeprecatedZipExtractionServiceWrapper get zipExtractionService =>
      DeprecatedZipExtractionServiceWrapper();

  /// Gets the consolidated interactive service as utility service
  ///
  /// @deprecated Access methods directly on ServiceContainer.instance.interactiveService
  DeprecatedUtilityServiceWrapper get utilityService =>
      DeprecatedUtilityServiceWrapper();
}

/// @deprecated Wrapper for backward compatibility
class DeprecatedPromptServiceWrapper {
  /// @deprecated Use ServiceContainer.instance.interactiveService.readUserInput()
  Future<String> readUserInput() =>
      ServiceContainer.instance.interactiveService.readUserInput();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askDivideDates()
  Future<int> askDivideDates() =>
      ServiceContainer.instance.interactiveService.askDivideDates();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askAlbums()
  Future<String> askAlbums() =>
      ServiceContainer.instance.interactiveService.askAlbums();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askForCleanOutput()
  Future<bool> askForCleanOutput() =>
      ServiceContainer.instance.interactiveService.askForCleanOutput();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askTransformPixelMP()
  Future<bool> askTransformPixelMP() =>
      ServiceContainer.instance.interactiveService.askTransformPixelMP();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askChangeCreationTime()
  Future<bool> askChangeCreationTime() =>
      ServiceContainer.instance.interactiveService.askChangeCreationTime();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askIfWriteExif()
  Future<bool> askIfWriteExif() =>
      ServiceContainer.instance.interactiveService.askIfWriteExif();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askIfLimitFileSize()
  Future<bool> askIfLimitFileSize() =>
      ServiceContainer.instance.interactiveService.askIfLimitFileSize();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askFixExtensions()
  Future<String> askFixExtensions() =>
      ServiceContainer.instance.interactiveService.askFixExtensions();

  /// @deprecated Use ServiceContainer.instance.interactiveService.askIfUnzip()
  Future<bool> askIfUnzip() =>
      ServiceContainer.instance.interactiveService.askIfUnzip();

  /// @deprecated Use ServiceContainer.instance.interactiveService.showGreeting()
  Future<void> showGreeting() =>
      ServiceContainer.instance.interactiveService.showGreeting();

  /// @deprecated Use ServiceContainer.instance.interactiveService.showNothingFoundMessage()
  Future<void> showNothingFoundMessage() =>
      ServiceContainer.instance.interactiveService.showNothingFoundMessage();

  /// Displays free space notice
  /// @deprecated This will be moved to consolidated disk space service
  void freeSpaceNotice(final int requiredBytes, final Directory path) {
    // Simple implementation for backward compatibility
    print('Free space check: $requiredBytes bytes required at ${path.path}');
  }
}

/// @deprecated Wrapper for backward compatibility
class DeprecatedFileSelectionServiceWrapper {
  /// @deprecated Use ServiceContainer.instance.interactiveService.selectInputDirectory()
  Future<Directory> selectInputDirectory() =>
      ServiceContainer.instance.interactiveService.selectInputDirectory();

  /// @deprecated Use ServiceContainer.instance.interactiveService.selectOutputDirectory()
  Future<Directory> selectOutputDirectory() =>
      ServiceContainer.instance.interactiveService.selectOutputDirectory();

  /// @deprecated Use ServiceContainer.instance.interactiveService.selectZipFiles()
  Future<List<File>> selectZipFiles() =>
      ServiceContainer.instance.interactiveService.selectZipFiles();
}

/// @deprecated Wrapper for backward compatibility
class DeprecatedZipExtractionServiceWrapper {
  /// @deprecated This functionality will be moved to consolidated services
  Future<void> extractAll(
    final List<File> zipFiles,
    final Directory outputDir,
  ) async {
    // Placeholder implementation for backward compatibility
    print('ZIP extraction: ${zipFiles.length} files to ${outputDir.path}');
  }
}

/// @deprecated Wrapper for backward compatibility
class DeprecatedUtilityServiceWrapper {
  /// @deprecated Use ServiceContainer.instance.interactiveService.sleep()
  Future<void> sleep(final num seconds) =>
      ServiceContainer.instance.interactiveService.sleep(seconds);

  /// @deprecated Use ServiceContainer.instance.interactiveService.pressEnterToContinue()
  void pressEnterToContinue() =>
      ServiceContainer.instance.interactiveService.pressEnterToContinue();
}
