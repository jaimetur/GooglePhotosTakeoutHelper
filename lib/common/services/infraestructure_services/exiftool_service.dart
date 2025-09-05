import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gpth/gpth_lib_exports.dart';
import 'package:path/path.dart' as path;

/// Shim to call logPrint on statics/top-level contexts.
class _TopLevelLogger with LoggerMixin {
  const _TopLevelLogger();
}
const _TopLevelLogger _kTopLogger = _TopLevelLogger();
void logPrint(final String msg, {final bool forcePrint = false}) =>
    _kTopLogger.logPrint(msg);

/// Infrastructure service for ExifTool external process management.
/// Keeps 4.2.2 performance behavior while restoring robust path discovery
/// (binary/script dir, parent dirs, PATH, common install paths) and
/// adds safe batch write via classic argv and via argfile (-@ file).
class ExifToolService with LoggerMixin {
  ExifToolService(this.exiftoolPath);

  final String exiftoolPath;

  // Persistent process plumbing (kept for future use; batch uses one-shot).
  Process? _persistentProcess;
  StreamSubscription<String>? _outputSubscription;
  StreamSubscription<String>? _errorSubscription;
  final Map<int, Completer<String>> _pendingCommands = {};
  final Map<int, String> _commandOutputs = {};
  bool _isDisposed = false;
  bool _isStarting = false;

  /// Find ExifTool in PATH, near the binary/script, or in common locations.
  static Future<ExifToolService?> find({
    final bool showDiscoveryMessage = true,
  }) async {
    final isWindows = Platform.isWindows;
    final exiftoolNames = isWindows
        ? ['exiftool.exe', 'exiftool']
        : ['exiftool'];

    // 1) PATH
    for (final name in exiftoolNames) {
      try {
        final result = await Process.run(name, ['-ver']);
        if (result.exitCode == 0) {
          if (showDiscoveryMessage) {
            final version = result.stdout.toString().trim();
            logPrint('ExifTool found in PATH: $name (version $version)');
          }
          return ExifToolService(name);
        }
      } catch (_) {}
    }

    // 2) Binary / script dirs and relatives (like 4.2.1)
    String? binDir;
    try {
      binDir = File(Platform.resolvedExecutable).parent.path;
      if (showDiscoveryMessage) {
        logPrint('Binary directory: $binDir');
      }
    } catch (_) {}

    final scriptPath = Platform.script.toFilePath();
    final scriptDir = scriptPath.isNotEmpty ? File(scriptPath).parent.path : null;
    if (scriptDir != null && showDiscoveryMessage) {
      logPrint('Script directory: $scriptDir');
    }

    final List<String?> candidateDirs = [
      binDir,
      scriptDir,
      if (binDir != null) path.join(binDir, 'exif_tool'),
      if (scriptDir != null) path.join(scriptDir, 'exif_tool'),
      Directory.current.path,
      path.join(Directory.current.path, 'exif_tool'),
      if (scriptDir != null) path.dirname(scriptDir),
      if (binDir != null) path.dirname(binDir),
      if (binDir != null) path.join(path.dirname(binDir), 'exif_tool'),
    ];

    for (final dir in candidateDirs) {
      if (dir == null || dir.isEmpty) continue;
      for (final exeName in exiftoolNames) {
        final exiftoolFile = File(path.join(dir, exeName));
        if (await exiftoolFile.exists()) {
          try {
            final result = await Process.run(exiftoolFile.path, ['-ver']);
            if (result.exitCode == 0) {
              if (showDiscoveryMessage) {
                final version = result.stdout.toString().trim();
                logPrint('[ExifToolService] ExifTool found: ${exiftoolFile.path} (version $version)');
              }
              return ExifToolService(exiftoolFile.path);
            }
          } catch (_) {}
        }
      }
    }

    // 3) Common install paths
    final commonPaths = isWindows
        ? [
            r'C:\Program Files\exiftool\exiftool.exe',
            r'C:\Program Files (x86)\exiftool\exiftool.exe',
            r'C:\exiftool\exiftool.exe',
          ]
        : [
            '/usr/bin/exiftool',
            '/usr/local/bin/exiftool',
            '/opt/homebrew/bin/exiftool',
          ];

    for (final p in commonPaths) {
      if (await File(p).exists()) {
        try {
          final result = await Process.run(p, ['-ver']);
          if (result.exitCode == 0) {
            if (showDiscoveryMessage) {
              final version = result.stdout.toString().trim();
              logPrint('[ExifToolService] ExifTool found: $p (version $version)');
            }
            return ExifToolService(p);
          }
        } catch (_) {}
      }
    }

    return null;
  }

  /// Start persistent ExifTool process (not used by batching, but kept available).
  Future<void> startPersistentProcess() async {
    if (_persistentProcess != null || _isDisposed || _isStarting) return;
    _isStarting = true;
    try {
      _persistentProcess = await Process.start(exiftoolPath, [
        '-stay_open',
        'True',
        '-@',
        '-',
      ]);

      _outputSubscription = _persistentProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleOutput);

      _errorSubscription = _persistentProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleError);
    } catch (e) {
      logWarning('[ExifToolService] Failed to start ExifTool persistent process: $e');
      _persistentProcess = null;
    } finally {
      _isStarting = false;
    }
  }

  void _handleOutput(final String line) {
    if (line.startsWith('{ready}')) {
      if (_pendingCommands.isNotEmpty) {
        final commandId = _pendingCommands.keys.last;
        final output = _commandOutputs[commandId] ?? '';
        _pendingCommands[commandId]!.complete(output);
        _pendingCommands.remove(commandId);
        _commandOutputs.remove(commandId);
      }
    } else {
      if (_pendingCommands.isNotEmpty) {
        final currentCommandId = _pendingCommands.keys.last;
        _commandOutputs[currentCommandId] =
            '${_commandOutputs[currentCommandId] ?? ''}$line\n';
      }
    }
  }

  void _handleError(final String line) {
    logPrint('[ExifToolService] ExifTool error: $line');
  }

  /// One-shot execution. Batch minimizes launches, but we still use one-shot here.
  Future<String> executeCommand(final List<String> args) async => _executeOneShot(args);

  Future<String> _executeOneShot(final List<String> args) async {
    try {
      final result = await Process.run(exiftoolPath, args);
      if (result.exitCode != 0) {
        logWarning('[ExifToolService] ExifTool command failed with exit code ${result.exitCode}. | Command: $exiftoolPath ${args.join(' ')}. | Stderr: ${result.stderr}');
        throw Exception('ExifTool command failed: ${result.stderr}');
      }
      // logPrint('[ExifToolService] ${result.stdout.toString()}');
      return result.stdout.toString();
    } catch (e) {
      logWarning('[ExifToolService] ExifTool one-shot execution failed: $e');
      rethrow;
    }
  }

  /// Read EXIF (fast path).
  Future<Map<String, dynamic>> readExifData(final File file) async {
    final args = ['-fast', '-j', '-n', file.path];
    final output = await executeCommand(args);
    if (output.trim().isEmpty) return {};
    try {
      final List<dynamic> jsonList = jsonDecode(output);
      if (jsonList.isNotEmpty && jsonList[0] is Map<String, dynamic>) {
        final data = Map<String, dynamic>.from(jsonList[0]);
        return data;
      }
      return {};
    } catch (e) {
      logWarning('[ExifToolService] Failed to parse ExifTool JSON output: $e');
      logWarning('[ExifToolService] Raw output: "$output"');
      return {};
    }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Common write flags for stability/consistency
  // NOTE:
  //  - -P preserves file times (mtime/atime) → prevents OS timestamp drift while writing tags.
  //  - -charset filename=UTF8 ensures UTF-8 filename handling consistently across platforms.
  //  - -overwrite_original keeps the "replace" semantics across filesystems (safer than _in_place_).
  //  - -api QuickTimeUTC=1 normalizes QuickTime time handling to UTC (no measurable slowdown).
  List<String> _commonWriteArgs() => <String>[
        '-P',
        '-charset',
        'filename=UTF8',
        '-overwrite_original',
        '-api',
        'QuickTimeUTC=1',
      ];

  /// Write EXIF data to a single file (classic argv).
  Future<void> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    if (exifData.isEmpty) return;

    final args = <String>[];
    args.addAll(_commonWriteArgs());
    for (final entry in exifData.entries) {
      args.add('-${entry.key}=${entry.value}');
    }
    args.add(file.path);

    final output = await executeCommand(args);
    if (output.contains('error') ||
        output.contains('Error') ||
        output.contains("weren't updated due to errors")) {
      throw Exception('ExifTool failed to write metadata to ${file.path}: $output');
    }
  }

  /// Batch write: multiple files in a single exiftool invocation (classic argv).
  Future<void> writeExifDataBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;
    final args = <String>[];
    args.addAll(_commonWriteArgs());

    for (final fileAndTags in batch) {
      final file = fileAndTags.key;
      final tags = fileAndTags.value;
      if (tags.isEmpty) continue;

      for (final e in tags.entries) {
        args.add('-${e.key}=${e.value}');
      }
      args.add(file.path);
    }

    final output = await executeCommand(args);
    if (output.contains('error') ||
        output.contains('Error') ||
        output.contains("weren't updated due to errors")) {
      throw Exception('ExifTool failed in batch write: $output');
    }
  }

  /// Batch write using an argfile (-@ file) to avoid command-line limits.
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;

    // Build argfile with common args once via -common_args.
    final StringBuffer buf = StringBuffer();
    buf.writeln('-common_args');
    for (final a in _commonWriteArgs()) {
      if (a.contains(' ')) {
        final parts = a.split(' ');
        for (final p in parts) {
          if (p.isNotEmpty) buf.writeln(p);
        }
      } else {
        buf.writeln(a);
      }
    }

    for (final fileAndTags in batch) {
      final file = fileAndTags.key;
      final tags = fileAndTags.value;
      if (tags.isEmpty) continue;

      for (final e in tags.entries) {
        buf.writeln('-${e.key}=${e.value}');
      }
      buf.writeln(file.path);
    }

    final tmp = await File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}exif_args_${DateTime.now().microsecondsSinceEpoch}.txt',
    ).create();
    await tmp.writeAsString(buf.toString());

    try {
      final output = await executeCommand(['-@', tmp.path]);
      if (output.contains('error') ||
          output.contains('Error') ||
          output.contains("weren't updated due to errors")) {
        throw Exception('ExifTool failed in batch (argfile) write: $output');
      }
    } finally {
      try {
        await tmp.delete();
      } catch (_) {
        /* ignore */
      }
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    for (final completer in _pendingCommands.values) {
      completer.completeError('ExifTool service disposed');
    }
    _pendingCommands.clear();
    _commandOutputs.clear();

    try { await _outputSubscription?.cancel(); } catch (_) {}
    _outputSubscription = null;

    try { await _errorSubscription?.cancel(); } catch (_) {}
    _errorSubscription = null;

    if (_persistentProcess != null) {
      try {
        _persistentProcess!.stdin.write('-stay_open\nFalse\n');
        await _persistentProcess!.stdin.flush();
        await _persistentProcess!.stdin.close();
      } catch (_) {}

      try {
        await _persistentProcess!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _persistentProcess!.kill();
            return -1;
          },
        );
      } catch (_) {
        try { _persistentProcess!.kill(); } catch (_) {}
      } finally {
        _persistentProcess = null;
      }
    }
  }
}
