/// Performance optimization settings for Google Photos Takeout Helper
///
/// This class provides configuration options to enable various performance
/// optimizations that can dramatically improve processing speed for large
/// photo collections.
class PerformanceConfig {
  const PerformanceConfig({
    this.enableParallelProcessing = true,
    this.maxConcurrentOperations,
    this.enableOptimizedHashing = true,
    this.enableNativeFileOperations = true,
    this.largeFileThreshold = 100 * 1024 * 1024, // 100MB
    this.enableProgressiveHashing = true,
  });

  /// Enable parallel processing for file operations
  ///
  /// When enabled, multiple files will be processed concurrently,
  /// dramatically improving performance on multi-core systems.
  /// Default: true
  final bool enableParallelProcessing;

  /// Maximum number of concurrent operations
  ///
  /// If null, defaults to ConcurrencyManager().standard (CPU cores * 8)
  /// Increase for faster systems, decrease if experiencing memory issues
  final int? maxConcurrentOperations;

  /// Enable optimized hash calculation
  ///
  /// Uses larger chunk sizes and better buffer management for faster hashing
  /// Default: true
  final bool enableOptimizedHashing;

  /// Enable native file operations for large files
  ///
  /// Uses platform-specific optimizations (e.g., xcopy on Windows)
  /// for better performance with large files
  /// Default: true
  final bool enableNativeFileOperations;

  /// Threshold for considering a file "large" (in bytes)
  ///
  /// Files above this size may use different optimization strategies
  /// Default: 100MB
  final int largeFileThreshold;

  /// Enable progressive hashing for very large files
  ///
  /// Only hashes a portion of very large files for faster duplicate detection
  /// Default: true
  final bool enableProgressiveHashing;

  /// Create a high-performance configuration for large collections
  static const PerformanceConfig highPerformance = PerformanceConfig();

  /// Create a conservative configuration for older/slower systems
  static const PerformanceConfig conservative = PerformanceConfig(
    enableParallelProcessing: false,
    enableOptimizedHashing: false,
    enableNativeFileOperations: false,
    enableProgressiveHashing: false,
  );

  /// Create a balanced configuration (default)
  static const PerformanceConfig balanced = PerformanceConfig();
}
