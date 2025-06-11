import 'dart:io';

import '../../date_extractors/date_extractor.dart';

/// Domain model representing all configuration options for GPTH processing
///
/// This replaces the `Map<String, dynamic> args` with a type-safe configuration object
/// that validates inputs and provides clear access to all processing options.
class ProcessingConfig {
  const ProcessingConfig({
    required this.inputPath,
    required this.outputPath,
    this.albumBehavior = AlbumBehavior.shortcut,
    this.dateDivision = DateDivisionLevel.none,
    this.copyMode = false,
    this.writeExif = true,
    this.skipExtras = false,
    this.guessFromName = true,
    this.fixExtensions = false,
    this.fixExtensionsNonJpeg = false,
    this.fixExtensionsSoloMode = false,
    this.transformPixelMp = false,
    this.updateCreationTime = false,
    this.limitFileSize = false,
    this.verbose = false,
    this.isInteractiveMode = false,
  });

  final String inputPath;
  final String outputPath;
  final AlbumBehavior albumBehavior;
  final DateDivisionLevel dateDivision;
  final bool copyMode;
  final bool writeExif;
  final bool skipExtras;
  final bool guessFromName;
  final bool fixExtensions;
  final bool fixExtensionsNonJpeg;
  final bool fixExtensionsSoloMode;
  final bool transformPixelMp;
  final bool updateCreationTime;
  final bool limitFileSize;
  final bool verbose;
  final bool isInteractiveMode;

  /// Validates the configuration and throws descriptive errors if invalid
  void validate() {
    if (inputPath.isEmpty) {
      throw const ConfigurationException('Input path cannot be empty');
    }
    if (outputPath.isEmpty) {
      throw const ConfigurationException('Output path cannot be empty');
    }
    if (fixExtensionsSoloMode && !fixExtensions && !fixExtensionsNonJpeg) {
      throw const ConfigurationException(
        'Solo mode requires either fix-extensions or fix-extensions-non-jpeg to be enabled',
      );
    }
  }

  /// Returns whether the processing should continue after extension fixing
  bool get shouldContinueAfterExtensionFix => !fixExtensionsSoloMode;

  /// Returns the list of date extractors based on configuration
  List<DateTimeExtractor> get dateExtractors => [
    jsonDateTimeExtractor,
    exifDateTimeExtractor,
    if (guessFromName) guessExtractor,
    (final File f) => jsonDateTimeExtractor(f, tryhard: true),
  ];

  ProcessingConfig copyWith({
    final String? inputPath,
    final String? outputPath,
    final AlbumBehavior? albumBehavior,
    final DateDivisionLevel? dateDivision,
    final bool? copyMode,
    final bool? writeExif,
    final bool? skipExtras,
    final bool? guessFromName,
    final bool? fixExtensions,
    final bool? fixExtensionsNonJpeg,
    final bool? fixExtensionsSoloMode,
    final bool? transformPixelMp,
    final bool? updateCreationTime,
    final bool? limitFileSize,
    final bool? verbose,
    final bool? isInteractiveMode,
  }) => ProcessingConfig(
    inputPath: inputPath ?? this.inputPath,
    outputPath: outputPath ?? this.outputPath,
    albumBehavior: albumBehavior ?? this.albumBehavior,
    dateDivision: dateDivision ?? this.dateDivision,
    copyMode: copyMode ?? this.copyMode,
    writeExif: writeExif ?? this.writeExif,
    skipExtras: skipExtras ?? this.skipExtras,
    guessFromName: guessFromName ?? this.guessFromName,
    fixExtensions: fixExtensions ?? this.fixExtensions,
    fixExtensionsNonJpeg: fixExtensionsNonJpeg ?? this.fixExtensionsNonJpeg,
    fixExtensionsSoloMode: fixExtensionsSoloMode ?? this.fixExtensionsSoloMode,
    transformPixelMp: transformPixelMp ?? this.transformPixelMp,
    updateCreationTime: updateCreationTime ?? this.updateCreationTime,
    limitFileSize: limitFileSize ?? this.limitFileSize,
    verbose: verbose ?? this.verbose,
    isInteractiveMode: isInteractiveMode ?? this.isInteractiveMode,
  );
}

/// Enum representing how albums should be handled
enum AlbumBehavior {
  shortcut('shortcut'),
  reverseShortcut('reverse-shortcut'),
  duplicateCopy('duplicate-copy'),
  json('json'),
  nothing('nothing');

  const AlbumBehavior(this.value);
  final String value;

  static AlbumBehavior fromString(final String value) =>
      AlbumBehavior.values.firstWhere(
        (final behavior) => behavior.value == value,
        orElse: () => throw ArgumentError('Invalid album behavior: $value'),
      );
}

/// Enum representing how files should be divided by date
enum DateDivisionLevel {
  none(0),
  year(1),
  month(2),
  day(3);

  const DateDivisionLevel(this.value);
  final int value;

  static DateDivisionLevel fromInt(final int value) =>
      DateDivisionLevel.values.firstWhere(
        (final level) => level.value == value,
        orElse: () =>
            throw ArgumentError('Invalid date division level: $value'),
      );
}

class ConfigurationException implements Exception {
  const ConfigurationException(this.message);
  final String message;

  @override
  String toString() => 'ConfigurationException: $message';
}
