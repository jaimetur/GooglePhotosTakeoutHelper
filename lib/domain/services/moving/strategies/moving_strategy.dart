import '../../../../media.dart';
import '../moving_context_model.dart';

/// Abstract base class for different album moving strategies
///
/// This interface defines the contract for implementing different album
/// behaviors (shortcut, duplicate-copy, json, nothing, reverse-shortcut).
abstract class MovingStrategy {
  const MovingStrategy();

  /// The name of this strategy for logging and debugging
  String get name;

  /// Whether this strategy creates shortcuts/symlinks
  bool get createsShortcuts;

  /// Whether this strategy creates duplicate files
  bool get createsDuplicates;

  /// Processes a single media file according to this strategy
  ///
  /// [media] The media file to process
  /// [context] The moving context with configuration
  /// Returns a stream of MovingResult objects representing the operations performed
  Stream<MovingResult> processMedia(
    final Media media,
    final MovingContext context,
  );

  /// Performs any finalization steps after all media has been processed
  ///
  /// [context] The moving context
  /// [processedMedia] All media that was processed
  /// Returns any additional results from finalization
  Future<List<MovingResult>> finalize(
    final MovingContext context,
    final List<Media> processedMedia,
  ) async => []; // Default: no finalization needed

  /// Validates that this strategy can be used with the given context
  ///
  /// [context] The moving context to validate
  /// Throws an exception if the context is invalid for this strategy
  void validateContext(final MovingContext context) {
    // Default: no validation needed
  }
}
