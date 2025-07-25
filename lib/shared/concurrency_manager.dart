import 'dart:io';

/// Centralized concurrency management for the entire application
///
/// This class provides consistent concurrency calculations across all services
/// and eliminates the need for hardcoded multipliers scattered throughout the codebase.
class ConcurrencyManager {
  factory ConcurrencyManager() => _instance;
  const ConcurrencyManager._internal();
  static const ConcurrencyManager _instance = ConcurrencyManager._internal();

  // ============================================================================
  // CORE CONCURRENCY CALCULATIONS
  // ============================================================================

  /// Base CPU core count (cached for performance)
  static int? _cachedCpuCount;

  /// Gets the number of CPU cores, with caching for performance
  int get cpuCoreCount {
    _cachedCpuCount ??= Platform.numberOfProcessors;
    return _cachedCpuCount!;
  }

  /// Standard concurrency multiplier (changed from 2 to 8 as requested)
  static const int standardMultiplier = 8;

  /// High performance multiplier for intensive operations
  static const int highPerformanceMultiplier = 24;

  // ============================================================================
  // CONCURRENCY LEVELS
  // ============================================================================

  /// Standard concurrency level for most operations
  /// Uses CPU cores * 8 (no caps)
  int get standard => cpuCoreCount * standardMultiplier;

  /// Conservative concurrency for resource-intensive operations
  /// Uses CPU cores * 6 (increased from 4)
  int get conservative => cpuCoreCount * 6;

  /// High performance concurrency for fast operations
  /// Uses CPU cores * 24
  int get highPerformance => cpuCoreCount * highPerformanceMultiplier;

  /// Platform-optimized concurrency (platform-specific logic)
  int get platformOptimized {
    if (Platform.isWindows) {
      return cpuCoreCount *
          standardMultiplier; // Windows handles concurrent I/O well
    } else if (Platform.isMacOS) {
      return cpuCoreCount *
          6; // macOS handles concurrency well, slightly more conservative
    } else if (Platform.isLinux) {
      return cpuCoreCount *
          8; // Modern Linux handles concurrent I/O excellently
    } else {
      return cpuCoreCount *
          4; // Conservative default for other Unix-like systems
    }
  }

  /// Disk I/O optimized concurrency
  /// Uses CPU cores * 6 (increased from 4 for modern SSDs)
  int get diskOptimized => cpuCoreCount * 6;

  /// Network I/O optimized concurrency
  /// Can be higher since network operations are often waiting
  int get networkOptimized => cpuCoreCount * 16;

  // ============================================================================
  // ADAPTIVE CONCURRENCY
  // ============================================================================

  /// Calculates adaptive concurrency based on performance metrics
  ///
  /// [recentPerformanceMetrics] List of recent performance measurements
  /// [baseLevel] Base concurrency level to scale from
  ///
  /// Returns scaled concurrency based on performance
  int getAdaptiveConcurrency(
    final List<double> recentPerformanceMetrics, {
    int? baseLevel,
  }) {
    baseLevel ??= standard;

    if (recentPerformanceMetrics.isEmpty) {
      return baseLevel;
    }

    final avgPerformance =
        recentPerformanceMetrics.reduce((final a, final b) => a + b) /
        recentPerformanceMetrics.length;

    // Scale concurrency based on performance
    if (avgPerformance > 10.0) {
      return baseLevel * 3; // High performance - scale up
    } else if (avgPerformance > 5.0) {
      return baseLevel; // Normal performance - use base
    } else {
      return (baseLevel * 0.5).round(); // Poor performance - scale down
    }
  }

  // ============================================================================
  // CUSTOM CONCURRENCY CALCULATIONS
  // ============================================================================

  /// Gets concurrency with custom multiplier
  ///
  /// [multiplier] Custom multiplier to apply to CPU core count
  /// [minValue] Minimum concurrency value (default: 1)
  /// [maxValue] Maximum concurrency value (null = no limit)
  ///
  /// Returns calculated concurrency with optional bounds
  int getCustomConcurrency(
    final double multiplier, {
    final int minValue = 1,
    final int? maxValue,
  }) {
    int result = (cpuCoreCount * multiplier).round();

    if (result < minValue) result = minValue;
    if (maxValue != null && result > maxValue) result = maxValue;

    return result;
  }

  /// Gets concurrency for specific operation types
  ///
  /// [operationType] Type of operation (hash, exif, duplicate, etc.)
  ///
  /// Returns optimized concurrency for the operation type
  int getConcurrencyForOperation(final String operationType) {
    switch (operationType.toLowerCase()) {
      case 'hash':
      case 'hashing':
        return standard; // CPU + I/O intensive

      case 'exif':
      case 'metadata':
        return diskOptimized; // Mostly I/O operations

      case 'duplicate':
      case 'comparison':
        return conservative; // Memory intensive

      case 'network':
      case 'download':
      case 'upload':
        return networkOptimized; // Network I/O

      case 'disk':
      case 'file':
      case 'copy':
      case 'move':
        return diskOptimized; // Disk I/O

      default:
        return standard; // Default to standard concurrency
    }
  }

  // ============================================================================
  // UTILITY METHODS
  // ============================================================================

  /// Invalidates the cached CPU count (useful for testing)
  void invalidateCache() {
    _cachedCpuCount = null;
  }

  /// Gets system information for debugging/logging
  Map<String, dynamic> getSystemInfo() => {
    'cpuCores': cpuCoreCount,
    'platform': Platform.operatingSystem,
    'standardConcurrency': standard,
    'conservativeConcurrency': conservative,
    'highPerformanceConcurrency': highPerformance,
    'platformOptimizedConcurrency': platformOptimized,
    'diskOptimizedConcurrency': diskOptimized,
    'networkOptimizedConcurrency': networkOptimized,
  };
}

/// Extension methods for easy access to concurrency manager
extension ConcurrencyExtensions on Object {
  /// Quick access to the concurrency manager
  ConcurrencyManager get concurrency => ConcurrencyManager();
}
