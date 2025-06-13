/// Factory for creating and managing interactive mode service instances
///
/// Provides centralized creation and management of services used in interactive mode,
/// ensuring proper dependency injection and consistent configuration.
library;

import '../../presentation/interactive_presenter.dart';
import '../services/file_selection_service.dart';
import '../services/interactive_utility_service.dart';
import '../services/user_prompt_service.dart';
import '../services/zip_extraction_service.dart';

/// Factory for creating interactive mode services with proper dependencies
///
/// This factory encapsulates the creation of service instances and their
/// dependencies, providing a centralized point for service configuration
/// in interactive mode.
class InteractiveServiceFactory {
  /// Creates a new InteractiveServiceFactory
  ///
  /// [presenter] The presenter instance for user interactions
  InteractiveServiceFactory({required final InteractivePresenter presenter})
    : _presenter = presenter;
  final InteractivePresenter _presenter;

  // Lazy-initialized service instances
  UserPromptService? _promptService;
  FileSelectionService? _fileSelectionService;
  ZipExtractionService? _zipExtractionService;
  InteractiveUtilityService? _utilityService;

  /// Gets or creates the UserPromptService instance
  UserPromptService get promptService =>
      _promptService ??= UserPromptService(presenter: _presenter);

  /// Gets or creates the FileSelectionService instance
  FileSelectionService get fileSelectionService =>
      _fileSelectionService ??= FileSelectionService(presenter: _presenter);

  /// Gets or creates the ZipExtractionService instance
  ZipExtractionService get zipExtractionService =>
      _zipExtractionService ??= ZipExtractionService(presenter: _presenter);

  /// Gets or creates the InteractiveUtilityService instance
  InteractiveUtilityService get utilityService =>
      _utilityService ??= InteractiveUtilityService(presenter: _presenter);
}
