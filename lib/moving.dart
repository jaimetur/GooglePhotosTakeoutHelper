/// Refactored moving logic using clean architecture principles
///
/// This file provides a backwards-compatible interface to the new modular
/// moving system while maintaining the same API for existing code.
library;

import 'dart:io';

import 'domain/models/processing_config_model.dart';
import 'domain/services/moving/file_operation_service.dart';
import 'domain/services/moving/media_moving_service.dart';
import 'domain/services/moving/moving_context_model.dart';
import 'domain/services/moving/shortcut_service.dart';
import 'media.dart';

export 'domain/services/moving/file_operation_service.dart'
    show FileOperationException;

/// High-performance backwards-compatible interface to the refactored moving logic
///
/// This function maintains the same signature as the original moveFiles function
/// but uses parallel processing internally for massive performance improvements.
Stream<int> moveFiles(
  final List<Media> allMediaFinal,
  final Directory output, {
  required final bool copy,
  required final num divideToDates,
  required final String albumBehavior,
}) async* {
  // Convert old parameters to new models
  final context = MovingContext(
    outputDirectory: output,
    copyMode: copy,
    dateDivision: DateDivisionLevel.fromInt(divideToDates.toInt()),
    albumBehavior: AlbumBehavior.fromString(albumBehavior),
  );

  // Create the moving service
  final movingService = MediaMovingService();

  // Use parallel processing for better performance
  yield* movingService.moveMediaFilesParallel(allMediaFinal, context);
}

/// Creates a unique file name by appending (1), (2), etc. until non-existing
///
/// This function is kept for backwards compatibility with existing code.
/// New code should use FileOperationService.findUniqueFileName instead.
File findNotExistingName(final File initialFile) {
  // Delegate to the new service
  final fileService = FileOperationService();
  return fileService.findUniqueFileName(initialFile);
}

/// Creates a symbolic link (Unix) or shortcut (Windows) to target file
///
/// This function is kept for backwards compatibility with existing code.
/// New code should use ShortcutService.createShortcut instead.
Future<File> createShortcut(final Directory location, final File target) async {
  // Delegate to the new service
  final shortcutService = ShortcutService();
  return shortcutService.createShortcut(location, target);
}

/// Moves or copies a file to new location and creates a shortcut in the original location
///
/// This function is kept for backwards compatibility with existing code.
Future<File> moveFileAndCreateShortcut(
  final Directory newLocation,
  final File target, {
  required final bool copy,
}) async {
  final fileService = FileOperationService();
  final shortcutService = ShortcutService();

  // Move or copy the file
  final newFile = await fileService.moveOrCopyFile(
    target,
    newLocation,
    copyMode: copy,
  );

  // Create shortcut in the original location
  final shortcut = await shortcutService.createShortcut(target.parent, newFile);

  return shortcut;
}
