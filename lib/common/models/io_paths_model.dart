/// **INPUT/OUTPUT PATH DATA MODEL**
///
/// Domain model for holding resolved and validated input and output directory paths.
/// This provides type safety and clarity for path handling throughout the
/// argument parsing and validation process.
///
/// **PURPOSE:**
/// - Encapsulates the two required paths in a single domain object
/// - Provides type safety for path passing between functions
/// - Makes function signatures clearer and more maintainable
/// - Enables future extension with additional path-related metadata
/// - Follows clean architecture principles by keeping data models in domain layer
///
/// **USAGE:**
/// Used by path resolution services and configuration builders to return validated
/// input and output directory paths from either CLI arguments or interactive mode prompts.
class InputOutputPaths {
  const InputOutputPaths({required this.inputPath, required this.outputPath});

  /// Path to the directory containing Google Photos Takeout media files.
  /// This path is normalized to point to the actual Google Photos folder
  /// containing "Photos from YYYY" directories and album folders.
  final String inputPath;

  /// Path to the directory where organized photos will be written.
  /// This directory will be created if it doesn't exist.
  final String outputPath;

  @override
  String toString() =>
      'InputOutputPaths(input: $inputPath, output: $outputPath)';

  @override
  bool operator ==(final Object other) =>
      identical(this, other) ||
      (other is InputOutputPaths &&
          runtimeType == other.runtimeType &&
          inputPath == other.inputPath &&
          outputPath == other.outputPath);

  @override
  int get hashCode => inputPath.hashCode ^ outputPath.hashCode;
}
