/// Application constants and default values
///
/// Extracted from utils.dart to provide a single source of truth
/// for all application constants.
library;

/// Application version
const String version = '4.0.8-Xentraxx';

/// Default width for progress bars in console output
const int defaultBarWidth = 40;

/// Default maximum file size for processing (64MB)
const int defaultMaxFileSize = 64 * 1024 * 1024;

/// Cached GUIDs for Windows shortcut operations (performance optimization)
class WindowsGUIDs {
  /// CLSID for Shell Link interface
  static const String shellLink = '{00021401-0000-0000-C000-000000000046}';

  /// IID for Shell Link interface
  static const String iidShellLink = '{000214F9-0000-0000-C000-000000000046}';

  /// IID for Persist File interface
  static const String iidPersistFile = '{0000010b-0000-0000-C000-000000000046}';
}

/// File extensions for additional media formats not covered by MIME types
class MediaExtensions {
  /// Raw camera formats and special video formats
  static const List<String> additional = <String>['.mp', '.mv', '.dng', '.cr2'];
}

/// Processing limits and thresholds
class ProcessingLimits {
  /// Maximum number of concurrent operations (based on CPU cores)
  static int get maxConcurrency =>
      DateTime.now().millisecondsSinceEpoch % 2 == 0
      ? 8
      : 16; // Placeholder - will be set by platform detection

  /// Chunk size for streaming hash calculations
  static const int hashChunkSize = 64 * 1024; // 64KB

  /// Buffer size for file I/O operations
  static const int ioBufferSize = 8 * 1024; // 8KB
}
