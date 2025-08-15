import 'dart:io';
import 'package:gpth/domain/services/core/logging_service.dart';

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
  static int standardMultiplier = 8;

  /// High performance multiplier for intensive operations
  static int highPerformanceMultiplier = 24;

  // Additional multipliers (modifiable for tests or CLI overrides)
  static int conservativeMultiplier = 6;

  static int diskOptimizedMultiplier = 6;

  static int networkOptimizedMultiplier = 16;

  // ============================================================================
  // CONCURRENCY LEVELS
  // ============================================================================

  /// Standard concurrency level for most operations
  /// Uses CPU cores * 8 (no caps)
  int get standard {
    final val = cpuCoreCount * standardMultiplier;
    try {
      LoggingService().info('Starting $val threads (standard concurrency)');
    } catch (_) {}
    return val;
  }

  /// Conservative concurrency for resource-intensive operations
  /// Uses CPU cores * 6 (increased from 4)
  int get conservative {
    final val = cpuCoreCount * conservativeMultiplier;
    try {
      LoggingService().info('Starting $val threads (conservative concurrency)');
    } catch (_) {}
    return val;
  }

  /// High performance concurrency for fast operations
  /// Uses CPU cores * 24
  int get highPerformance {
    final val = cpuCoreCount * highPerformanceMultiplier;
    try {
      LoggingService().info(
        'Starting $val threads (highPerformance concurrency)',
      );
    } catch (_) {}
    return val;
  }

  /// Platform-optimized concurrency (platform-specific logic)
  int get platformOptimized {
    int val;
    if (Platform.isWindows) {
      val =
          cpuCoreCount *
          standardMultiplier; // Windows handles concurrent I/O well
    } else if (Platform.isMacOS) {
      val =
          cpuCoreCount *
          conservativeMultiplier; // macOS handles concurrency well, slightly more conservative
    } else if (Platform.isLinux) {
      val =
          cpuCoreCount *
          standardMultiplier; // Modern Linux handles concurrent I/O excellently
    } else {
      val =
          cpuCoreCount * 4; // Conservative default for other Unix-like systems
    }
    try {
      LoggingService().info(
        'Starting $val threads (platformOptimized concurrency)',
      );
    } catch (_) {}
    return val;
  }

  /// Disk I/O optimized concurrency
  /// Uses CPU cores * 6 (increased from 4 for modern SSDs)
  int get diskOptimized {
    final val = cpuCoreCount * diskOptimizedMultiplier;
    try {
      LoggingService().info(
        'Starting $val threads (diskOptimized concurrency)',
      );
    } catch (_) {}
    return val;
  }

  /// Network I/O optimized concurrency
  /// Can be higher since network operations are often waiting
  int get networkOptimized {
    final val = cpuCoreCount * networkOptimizedMultiplier;
    try {
      LoggingService().info(
        'Starting $val threads (networkOptimized concurrency)',
      );
    } catch (_) {}
    return val;
  }

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

    try {
      LoggingService().info(
        'Starting $result threads (custom multiplier $multiplier)',
      );
    } catch (_) {}
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
        final hashVal =
            cpuCoreCount *
            4; // Balanced for CPU + I/O workload (reduced from standard)
        try {
          LoggingService().info('Starting $hashVal threads (hash concurrency)');
        } catch (_) {}
        return hashVal;

      case 'exif':
      case 'metadata':
        final val = diskOptimized; // Mostly I/O operations
        try {
          LoggingService().info(
            'Starting $val threads (exif/metadata concurrency)',
          );
        } catch (_) {}
        return val;

      case 'duplicate':
      case 'comparison':
        final val = conservative; // Memory intensive
        try {
          LoggingService().info(
            'Starting $val threads (duplicate/conparison concurrency)',
          );
        } catch (_) {}
        return val;

      case 'network':
      case 'download':
      case 'upload':
        final val = networkOptimized; // Network I/O
        try {
          LoggingService().info('Starting $val threads (network concurrency)');
        } catch (_) {}
        return val;

      case 'disk':
      case 'file':
      case 'copy':
      case 'move':
        final val = diskOptimized; // Disk I/O
        try {
          LoggingService().info(
            'Starting $val threads (disk/file concurrency)',
          );
        } catch (_) {}
        return val;

      default:
        final val = standard; // Default to standard concurrency
        try {
          LoggingService().info(
            'Starting $val threads (default/standard concurrency)',
          );
        } catch (_) {}
        return val;
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
