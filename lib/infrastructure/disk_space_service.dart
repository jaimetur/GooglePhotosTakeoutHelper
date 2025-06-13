import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../domain/services/logging_service.dart';
import 'platform_service.dart';

/// Service for checking available disk space across different platforms
///
/// Provides a unified interface for disk space checking while handling
/// platform-specific implementations internally.
class DiskSpaceService with LoggerMixin {
  /// Creates a new disk space service
  DiskSpaceService() : _platformService = const PlatformService();

  final PlatformService _platformService;

  /// Gets available disk space for the given path
  ///
  /// [path] Directory path to check
  /// Returns available space in bytes, or null if unable to determine
  Future<int?> getAvailableSpace(final String path) async {
    try {
      if (_platformService.isWindows) {
        return await _getSpaceWindows(path);
      } else if (_platformService.isMacOS) {
        return await _getSpaceMacOS(path);
      } else if (_platformService.isLinux) {
        return await _getSpaceLinux(path);
      } else {
        logWarning('Unsupported platform for disk space checking');
        return null;
      }
    } catch (e) {
      logError('Failed to get disk space for $path: $e');
      return null;
    }
  }

  /// Checks if there's enough space for a given operation
  ///
  /// [path] Directory path to check
  /// [requiredBytes] Number of bytes needed
  /// [safetyMarginBytes] Additional safety margin (default: 100MB)
  ///
  /// Returns true if there's enough space, false otherwise
  Future<bool> hasEnoughSpace(
    final String path,
    final int requiredBytes, {
    final int safetyMarginBytes = 100 * 1024 * 1024, // 100MB
  }) async {
    final int? availableSpace = await getAvailableSpace(path);

    if (availableSpace == null) {
      logWarning('Cannot determine available space, assuming insufficient');
      return false;
    }

    final int totalNeeded = requiredBytes + safetyMarginBytes;
    return availableSpace >= totalNeeded;
  }

  /// Gets disk space on Windows using PowerShell
  Future<int?> _getSpaceWindows(final String path) async {
    final String driveLetter = p
        .rootPrefix(p.absolute(path))
        .replaceAll('\\', '')
        .replaceAll(':', '');

    if (driveLetter.isEmpty) {
      logError('Could not determine drive letter for path: $path');
      return null;
    }

    final ProcessResult result = await Process.run('powershell', <String>[
      '-Command',
      'Get-PSDrive -Name ${driveLetter[0]} | Select-Object -ExpandProperty Free',
    ]);

    if (result.exitCode != 0) {
      logError('PowerShell command failed: ${result.stderr}');
      return null;
    }

    return int.tryParse(result.stdout.toString().trim());
  }

  /// Gets disk space on macOS using df command
  Future<int?> _getSpaceMacOS(final String path) async {
    final ProcessResult result = await Process.run('df', <String>['-k', path]);

    if (result.exitCode != 0) {
      logError('df command failed: ${result.stderr}');
      return null;
    }

    final String? outputLine = result.stdout
        .toString()
        .split('\n')
        .elementAtOrNull(1);

    if (outputLine == null) {
      logError('Unexpected df output format');
      return null;
    }

    final List<String> columns = outputLine.split(' ')
      ..removeWhere((final String e) => e.isEmpty);

    final String? availableKb = columns.elementAtOrNull(3);
    if (availableKb == null) {
      logError('Could not parse available space from df output');
      return null;
    }

    final int? kilobytes = int.tryParse(availableKb);
    return kilobytes != null ? kilobytes * 1024 : null;
  }

  /// Gets disk space on Linux using df command
  Future<int?> _getSpaceLinux(final String path) async {
    final ProcessResult result = await Process.run('df', <String>[
      '-B1', // Output in bytes
      '--output=avail',
      path,
    ]);

    if (result.exitCode != 0) {
      logError('df command failed: ${result.stderr}');
      return null;
    }

    final String? availableBytesStr = result.stdout
        .toString()
        .split('\n')
        .elementAtOrNull(1);

    if (availableBytesStr == null) {
      logError('Could not parse df output');
      return null;
    }

    return int.tryParse(availableBytesStr.trim());
  }
}
