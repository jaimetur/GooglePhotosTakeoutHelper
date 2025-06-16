import 'dart:io';

import '../../models/processing_config_model.dart';
import '../core/formatting_service.dart';

/// Domain service for handling interactive configuration logic
///
/// This service contains the business logic for configuring the processing
/// pipeline based on user choices, without any UI concerns.
///
/// NOTE: File size formatting has been moved to ConsolidatedUtilityService.
class InteractiveConfigurationService {
  /// Creates processing configuration from user choices
  ///
  /// This method encapsulates all the business logic for converting
  /// user selections into a proper ProcessingConfig object.
  ProcessingConfig createProcessingConfig({
    required final String inputPath,
    required final String outputPath,
    required final DateDivisionLevel dateDivision,
    required final AlbumBehavior albumBehavior,
    required final bool transformPixelMp,
    required final bool updateCreationTime,
    required final bool writeExif,
    required final bool limitFileSize,
    required final ExtensionFixingMode extensionFixing,
    final bool verbose = false,
    final bool skipExtras = false,
    final bool guessFromName = true,
  }) => ProcessingConfig(
    inputPath: inputPath,
    outputPath: outputPath,
    dateDivision: dateDivision,
    albumBehavior: albumBehavior,
    transformPixelMp: transformPixelMp,
    updateCreationTime: updateCreationTime,
    writeExif: writeExif,
    limitFileSize: limitFileSize,
    extensionFixing: extensionFixing,
    verbose: verbose,
    skipExtras: skipExtras,
    guessFromName: guessFromName,
    isInteractiveMode: true,
  );

  /// Validates input directory and returns validation result
  ValidationResult validateInputDirectory(final String path) {
    final directory = Directory(path);

    if (!directory.existsSync()) {
      return ValidationResult.failure('Directory does not exist: $path');
    }

    final takeoutDir = Directory('$path/Takeout');
    if (!takeoutDir.existsSync()) {
      return ValidationResult.failure(
        'No "Takeout" folder found in $path. '
        'Make sure you\'ve extracted your Google Photos Takeout ZIP files '
        'and merged them into a single "Takeout" folder.',
      );
    }

    return ValidationResult.success();
  }

  /// Validates output directory and returns validation result
  ValidationResult validateOutputDirectory(final String path) {
    final directory = Directory(path);

    // Create directory if it doesn't exist
    if (!directory.existsSync()) {
      try {
        directory.createSync(recursive: true);
        return ValidationResult.success();
      } catch (e) {
        return ValidationResult.failure('Cannot create output directory: $e');
      }
    }

    return ValidationResult.success();
  }

  /// Checks if output directory is empty and returns appropriate action
  OutputDirectoryStatus checkOutputDirectoryStatus(final String path) {
    final directory = Directory(path);

    if (!directory.existsSync()) {
      return OutputDirectoryStatus.empty;
    }

    final contents = directory.listSync();
    if (contents.isEmpty) {
      return OutputDirectoryStatus.empty;
    }

    return OutputDirectoryStatus.notEmpty;
  }

  /// Validates ZIP files for processing
  ValidationResult validateZipFiles(final List<File> zipFiles) {
    if (zipFiles.isEmpty) {
      return ValidationResult.failure('No ZIP files selected');
    }

    for (final zip in zipFiles) {
      if (!zip.existsSync()) {
        return ValidationResult.failure('ZIP file does not exist: ${zip.path}');
      }

      if (zip.lengthSync() == 0) {
        return ValidationResult.failure('ZIP file is empty: ${zip.path}');
      }
    }

    return ValidationResult.success();
  }

  /// Calculates required disk space for processing
  DiskSpaceRequirement calculateDiskSpaceRequirement({
    required final List<File> zipFiles,
    required final AlbumBehavior albumBehavior,
    required final bool copyMode,
  }) {
    int totalZipSize = 0;
    for (final zip in zipFiles) {
      totalZipSize += zip.lengthSync();
    }

    // Estimate extraction space (typically 1.2x compressed size)
    final extractionSpace = (totalZipSize * 1.2).round();

    // Estimate output space based on album behavior
    double outputMultiplier;
    switch (albumBehavior) {
      case AlbumBehavior.shortcut:
      case AlbumBehavior.reverseShortcut:
      case AlbumBehavior.json:
      case AlbumBehavior.nothing:
        outputMultiplier = copyMode ? 1.0 : 0.0; // No extra space for move mode
        break;
      case AlbumBehavior.duplicateCopy:
        outputMultiplier = 2.0; // Albums duplicate files
        break;
    }

    final outputSpace = (extractionSpace * outputMultiplier).round();
    final totalRequired = extractionSpace + outputSpace;

    return DiskSpaceRequirement(
      extractionSpace: extractionSpace,
      outputSpace: outputSpace,
      totalRequired: totalRequired,
    );
  }
}

/// Result of a validation operation
class ValidationResult {
  const ValidationResult._({required this.isValid, this.errorMessage});

  factory ValidationResult.success() => const ValidationResult._(isValid: true);

  factory ValidationResult.failure(final String message) =>
      ValidationResult._(isValid: false, errorMessage: message);

  final bool isValid;
  final String? errorMessage;

  bool get isFailure => !isValid;
}

/// Status of output directory
enum OutputDirectoryStatus { empty, notEmpty }

/// Disk space requirement calculation
class DiskSpaceRequirement {
  const DiskSpaceRequirement({
    required this.extractionSpace,
    required this.outputSpace,
    required this.totalRequired,
  });

  final int extractionSpace;
  final int outputSpace;
  final int totalRequired;

  static const _utility = FormattingService();

  /// Human-readable total required space
  String get totalRequiredFormatted => _utility.formatFileSize(totalRequired);

  /// Human-readable extraction space
  String get extractionSpaceFormatted =>
      _utility.formatFileSize(extractionSpace);

  /// Human-readable output space
  String get outputSpaceFormatted => _utility.formatFileSize(outputSpace);
}
