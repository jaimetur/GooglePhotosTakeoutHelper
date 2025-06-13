/// Service for utility functions used in interactive mode
///
/// Provides common utility functions that support the interactive user experience
/// but don't belong to any specific domain concern.
library;

import 'dart:async';

import '../../presentation/interactive_presenter.dart';

/// Service providing utility functions for interactive mode operations
///
/// This service encapsulates common utility operations that support
/// interactive user sessions, including timing controls and user prompts.
class InteractiveUtilityService {
  /// Creates a new InteractiveUtilityService
  ///
  /// [presenter] The presenter instance for user interactions
  const InteractiveUtilityService({
    required final InteractivePresenter presenter,
  }) : _presenter = presenter;
  final InteractivePresenter _presenter;

  /// Pauses execution for specified number of seconds
  ///
  /// This is commonly used in interactive mode to give users time to read
  /// messages and make the experience feel more natural.
  ///
  /// [seconds] Number of seconds to sleep (can be fractional)
  ///
  /// Example:
  /// ```dart
  /// await utilityService.sleep(2.5); // Sleep for 2.5 seconds
  /// ```
  Future<void> sleep(final num seconds) =>
      Future<void>.delayed(Duration(milliseconds: (seconds * 1000).toInt()));

  /// Displays a prompt and waits for user to press enter
  ///
  /// This provides a standard way to pause execution and wait for user
  /// acknowledgment before continuing with the next operation.
  void pressEnterToContinue() {
    _presenter.showPressEnterPrompt();
  }

  /// Displays greeting message and introduction to the tool
  ///
  /// Shows the welcome message and initial information about the tool
  /// to orient new users.
  Future<void> showGreeting() async {
    await _presenter.showGreeting();
  }

  /// Displays the "nothing found" message
  ///
  /// Shows appropriate messaging when no files are found to process.
  /// Note: Does not quit explicitly - caller should handle program termination.
  Future<void> showNothingFoundMessage() async {
    await _presenter.showNothingFoundMessage();
  }
}
