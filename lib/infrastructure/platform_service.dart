import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Service for platform-specific operations and disk space detection
///
/// Extracted from utils.dart to isolate platform-specific code
/// and provide better testability through interface abstraction.
class PlatformService {
  /// Creates a new instance of PlatformService
  const PlatformService();

  /// Returns disk free space in bytes for the given path
  ///
  /// [path] Directory path to check (defaults to current directory)
  /// Returns null if unable to determine free space
  Future<int?> getDiskFreeSpace([String? path]) async {
    path ??= Directory.current.path;

    // Handle empty string as current directory
    if (path.isEmpty) {
      path = Directory.current.path;
    }

    if (Platform.isLinux) {
      return _getDiskFreeLinux(path);
    } else if (Platform.isWindows) {
      return _getDiskFreeWindows(path);
    } else if (Platform.isMacOS) {
      return _getDiskFreeMacOS(path);
    }

    return null; // Unsupported platform
  }

  /// Gets disk free space on Linux using statvfs
  Future<int?> _getDiskFreeLinux(final String path) async {
    try {
      final result = await Process.run('df', ['-B1', path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length >= 2) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            return int.tryParse(parts[3]);
          }
        }
      }
    } catch (e) {
      // Ignore errors and return null
    }
    return null;
  }

  /// Gets disk free space on macOS using statvfs
  Future<int?> _getDiskFreeMacOS(final String path) async {
    try {
      final result = await Process.run('df', ['-k', path]);
      if (result.exitCode == 0) {
        final lines = result.stdout.toString().split('\n');
        if (lines.length >= 2) {
          final parts = lines[1].split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            final freeKB = int.tryParse(parts[3]);
            return freeKB != null ? freeKB * 1024 : null; // Convert KB to bytes
          }
        }
      }
    } catch (e) {
      // Ignore errors and return null
    }
    return null;
  }

  /// Gets disk free space on Windows using GetDiskFreeSpaceEx
  int? _getDiskFreeWindows(final String path) {
    try {
      final pathPtr = path.toNativeUtf16();
      final freeBytes = calloc<Uint64>();
      final totalBytes = calloc<Uint64>();

      final result = GetDiskFreeSpaceEx(
        pathPtr,
        freeBytes,
        totalBytes,
        nullptr,
      );

      if (result != 0) {
        final free = freeBytes.value;
        calloc.free(pathPtr);
        calloc.free(freeBytes);
        calloc.free(totalBytes);
        return free;
      }

      calloc.free(pathPtr);
      calloc.free(freeBytes);
      calloc.free(totalBytes);
    } catch (e) {
      // Ignore errors and return null
    }
    return null;
  }

  /// Gets the number of logical processors available
  int getProcessorCount() => Platform.numberOfProcessors;

  /// Checks if the current platform supports symbolic links
  bool get supportsSymlinks => Platform.isLinux || Platform.isMacOS;

  /// Checks if the current platform supports Windows shortcuts
  bool get supportsWindowsShortcuts => Platform.isWindows;

  /// Check if running on Windows platform
  bool get isWindows => Platform.isWindows;

  /// Check if running on macOS platform
  bool get isMacOS => Platform.isMacOS;

  /// Check if running on Linux platform
  bool get isLinux => Platform.isLinux;

  /// Gets the optimal number of concurrent operations for this platform
  int getOptimalConcurrency() {
    final cores = getProcessorCount();

    // Conservative multiplier based on platform
    if (Platform.isWindows) {
      return cores * 2; // Windows handles concurrent I/O well
    } else {
      return cores + 1; // More conservative for Unix-like systems
    }
  }

  /// Checks if the current platform has sufficient resources for operation
  ///
  /// [requiredMemoryMB] Minimum required memory in MB
  /// [requiredDiskSpaceMB] Minimum required disk space in MB
  /// [path] Path to check disk space for
  Future<PlatformResourceCheck> checkResources({
    final int requiredMemoryMB = 512,
    final int requiredDiskSpaceMB = 1024,
    final String? path,
  }) async {
    final diskSpace = await getDiskFreeSpace(path);
    final diskSpaceMB = diskSpace != null ? diskSpace ~/ (1024 * 1024) : null;

    return PlatformResourceCheck(
      hasEnoughMemory:
          true, // Simplified - would need platform-specific memory check
      hasEnoughDiskSpace:
          diskSpaceMB != null && diskSpaceMB >= requiredDiskSpaceMB,
      availableDiskSpaceMB: diskSpaceMB,
      processorCount: getProcessorCount(),
    );
  }
}

/// Result of platform resource checking
class PlatformResourceCheck {
  const PlatformResourceCheck({
    required this.hasEnoughMemory,
    required this.hasEnoughDiskSpace,
    required this.availableDiskSpaceMB,
    required this.processorCount,
  });

  /// Whether sufficient memory is available
  final bool hasEnoughMemory;

  /// Whether sufficient disk space is available
  final bool hasEnoughDiskSpace;

  /// Available disk space in MB (null if unknown)
  final int? availableDiskSpaceMB;

  /// Number of processor cores
  final int processorCount;

  /// Whether all resource requirements are met
  bool get isResourcesAdequate => hasEnoughMemory && hasEnoughDiskSpace;
}
