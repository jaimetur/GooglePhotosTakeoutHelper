import '../../../models/processing_config_model.dart';
import '../file_operation_service.dart';
import '../path_generator_service.dart';
import '../shortcut_service.dart';
import 'duplicate_copy_moving_strategy.dart';
import 'json_moving_strategy.dart';
import 'moving_strategy.dart';
import 'nothing_moving_strategy.dart';
import 'reverse_shortcut_moving_strategy.dart';
import 'shortcut_moving_strategy.dart';

/// Factory for creating appropriate moving strategies based on album behavior
class MovingStrategyFactory {
  const MovingStrategyFactory(
    this._fileService,
    this._pathService,
    this._shortcutService,
  );
  final FileOperationService _fileService;
  final PathGeneratorService _pathService;
  final ShortcutService _shortcutService;

  /// Creates the appropriate moving strategy for the given album behavior
  MovingStrategy createStrategy(final AlbumBehavior albumBehavior) {
    switch (albumBehavior) {
      case AlbumBehavior.nothing:
        return NothingMovingStrategy(_fileService, _pathService);

      case AlbumBehavior.shortcut:
        return ShortcutMovingStrategy(
          _fileService,
          _pathService,
          _shortcutService,
        );

      case AlbumBehavior.json:
        return JsonMovingStrategy(_fileService, _pathService);
      case AlbumBehavior.duplicateCopy:
        return DuplicateCopyMovingStrategy(_fileService, _pathService);

      case AlbumBehavior.reverseShortcut:
        return ReverseShortcutMovingStrategy(
          _fileService,
          _pathService,
          _shortcutService,
        );
    }
  }

  /// Gets a list of all supported album behaviors
  static List<AlbumBehavior> get supportedBehaviors => [
    AlbumBehavior.nothing,
    AlbumBehavior.shortcut,
    AlbumBehavior.json,
    AlbumBehavior.duplicateCopy,
    AlbumBehavior.reverseShortcut,
  ];
}
