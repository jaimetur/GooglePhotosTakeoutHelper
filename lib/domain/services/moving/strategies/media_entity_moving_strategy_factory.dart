import '../../../models/processing_config_model.dart';
import '../file_operation_service.dart';
import '../path_generator_service.dart';
import '../shortcut_service.dart';
import 'media_entity_moving_strategy.dart';

/// Factory for creating MediaEntity moving strategies
///
/// This factory creates the appropriate strategy instance based on
/// the album behavior configuration, providing all necessary dependencies.
class MediaEntityMovingStrategyFactory {
  const MediaEntityMovingStrategyFactory(
    this._fileService,
    this._pathService,
    this._shortcutService,
  );
  // Dependencies ready for strategy implementations
  // ignore: unused_field
  final FileOperationService _fileService;
  // ignore: unused_field
  final PathGeneratorService _pathService;
  // ignore: unused_field
  final ShortcutService _shortcutService;

  /// Creates the appropriate strategy for the given album behavior
  MediaEntityMovingStrategy createStrategy(final AlbumBehavior albumBehavior) {
    throw UnimplementedError(
      'MediaEntity moving strategies not yet implemented. '
      'This will be created as we continue the modernization.',
    );
  }
}
