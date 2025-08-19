// FILE: lib/infrastructure/exiftool_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/services/core/logging_service.dart';

/// Infrastructure service for ExifTool external process management
class ExifToolService with LoggerMixin {
  /// Path to exiftool executable
  ExifToolService(this.exiftoolPath);

  final String exiftoolPath;

  // Optional persistent process plumbing (we still use one-shot by default)
  Process? _persistentProcess;
  StreamSubscription<String>? _outputSub;
  StreamSubscription<String>? _errorSub;
  final Map<int, Completer<String>> _pending = {};
  final Map<int, String> _outputs = {};
  bool _disposed = false;
  bool _starting = false;

  /// Factory method to find exiftool with 4.2.1-style path discovery (+PATH/common dirs).
  static Future<ExifToolService?> find({
    bool showDiscoveryMessage = true,
  }) async {
    final isWindows = Platform.isWindows;
    final exifNames = isWindows ? ['exiftool.exe', 'exiftool'] : ['exiftool'];

    // 1) Try PATH
    for (final name in exifNames) {
      try {
        final result = await Process.run(name, const ['-ver']);
        if (result.exitCode == 0) {
          if (showDiscoveryMessage) {
            final version = result.stdout.toString().trim();
            print('ExifTool found in PATH: $name (version $version)');
          }
          return ExifToolService(name);
        }
      } catch (_) {}
    }

    // 2) Resolve binary dir and script dir (4.2.1 behavior)
    String? binDir;
    try {
      binDir = File(Platform.resolvedExecutable).parent.path;
      if (showDiscoveryMessage) {
        print('Binary directory: $binDir');
      }
    } catch (_) {}

    final scriptPath = Platform.script.toFilePath();
    final scriptDir =
        scriptPath.isNotEmpty ? File(scriptPath).parent.path : null;
    if (scriptDir != null && showDiscoveryMessage) {
      print('Script directory: $scriptDir');
    }

    // 3) Candidate directories (4.2.1 relative lookup)
    final List<String?> candidateDirs = [
      binDir, // alongside compiled binary
      scriptDir, // alongside script
      if (binDir != null) p.join(binDir, 'exif_tool'),
      if (scriptDir != null) p.join(scriptDir, 'exif_tool'),
      Directory.current.path,
      p.join(Directory.current.path, 'exif_tool'),
      if (scriptDir != null) p.dirname(scriptDir), // parent of script dir
      if (binDir != null) p.dirname(binDir), // parent of binary dir
      if (binDir != null) p.join(p.dirname(binDir), 'exif_tool'),
    ];

    for (final dir in candidateDirs) {
      if (dir == null || dir.isEmpty) continue;
      for (final exeName in exifNames) {
        final exe = File(p.join(dir, exeName));
        if (await exe.exists()) {
          try {
            final result = await Process.run(exe.path, const ['-ver']);
            if (result.exitCode == 0) {
              if (showDiscoveryMessage) {
                final version = result.stdout.toString().trim();
                print('ExifTool found: ${exe.path} (version $version)');
              }
              return ExifToolService(exe.path);
            }
          } catch (_) {}
        }
      }
    }

    // 4) Common installation paths
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

    for (final path in commonPaths) {
      final f = File(path);
      if (await f.exists()) {
        try {
          final result = await Process.run(path, const ['-ver']);
          if (result.exitCode == 0) {
            if (showDiscoveryMessage) {
              final version = result.stdout.toString().trim();
              print('ExifTool found: $path (version $version)');
            }
            return ExifToolService(path);
          }
        } catch (_) {}
      }
    }

    return null;
  }

  /// One-shot execution (fast startup on modern OSes; persistent is optional)
  Future<String> executeCommand(final List<String> args) async {
    try {
      final result = await Process.run(exiftoolPath, args);
      if (result.exitCode != 0) {
        logger.error('ExifTool command failed: ${result.stderr}');
        throw Exception('ExifTool command failed: ${result.stderr}');
      }
      return result.stdout.toString();
    } catch (e) {
      logger.error('ExifTool one-shot execution failed: $e');
      rethrow;
    }
  }

  /// Read tags with -fast and JSON output
  Future<Map<String, dynamic>> readExifData(final File file) async {
    final output = await executeCommand(['-fast', '-j', '-n', file.path]);
    if (output.trim().isEmpty) return {};
    try {
      final List<dynamic> jsonList = jsonDecode(output);
      if (jsonList.isNotEmpty && jsonList[0] is Map<String, dynamic>) {
        return Map<String, dynamic>.from(jsonList[0]);
      }
      return {};
    } catch (_) {
      return {};
    }
  }

  /// Single-file write
  Future<void> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    if (exifData.isEmpty) return;
    final args = <String>['-overwrite_original'];
    for (final e in exifData.entries) {
      args.add('-${e.key}=${e.value}');
    }
    args.add(file.path);

    final out = await executeCommand(args);
    if (out.contains('error') ||
        out.contains('Error') ||
        out.contains("weren't updated due to errors")) {
      throw Exception('ExifTool failed to write metadata: $out');
    }
  }

  /// Multi-file write (inline args)
  Future<void> writeExifDataBatch(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;
    final args = <String>['-overwrite_original'];
    for (final entry in batch) {
      for (final exif in entry.value.entries) {
        args.add('-${exif.key}=${exif.value}');
      }
      args.add(entry.key.path);
    }
    final out = await executeCommand(args);
    if (out.contains('error') || out.contains('Error')) {
      throw Exception('ExifTool failed on batch: $out');
    }
  }

  /// Multi-file write using an argfile (-@) to reduce argv overhead
  Future<void> writeExifDataBatchViaArgFile(
    final List<MapEntry<File, Map<String, dynamic>>> batch,
  ) async {
    if (batch.isEmpty) return;

    // Build an argfile in /tmp
    final argFile = File(
      p.join(Directory.systemTemp.path, 'exiftool_args_${DateTime.now().microsecondsSinceEpoch}.txt'),
    );
    final sink = argFile.openWrite();
    sink.writeln('-overwrite_original');
    for (final entry in batch) {
      for (final exif in entry.value.entries) {
        sink.writeln('-${exif.key}=${exif.value}');
      }
      sink.writeln(entry.key.path);
    }
    await sink.close();

    try {
      final out = await executeCommand(['-@', argFile.path]);
      if (out.contains('error') || out.contains('Error')) {
        throw Exception('ExifTool failed on argfile batch: $out');
      }
    } finally {
      try {
        await argFile.delete();
      } catch (_) {}
    }
  }

  /// Optional persistent process (not required for batching, but kept for compatibility)
  Future<void> startPersistentProcess() async {
    if (_persistentProcess != null || _disposed || _starting) return;
    _starting = true;
    try {
      _persistentProcess = await Process.start(exiftoolPath, [
        '-stay_open',
        'True',
        '-@',
        '-',
      ]);

      _outputSub = _persistentProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleOut);

      _errorSub = _persistentProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleErr);
    } catch (e) {
      print('Failed to start ExifTool persistent process: $e');
      _persistentProcess = null;
    } finally {
      _starting = false;
    }
  }

  void _handleOut(String line) {
    if (line.startsWith('{ready}')) {
      if (_pending.isNotEmpty) {
        final id = _pending.keys.last;
        final out = _outputs[id] ?? '';
        _pending[id]!.complete(out);
        _pending.remove(id);
        _outputs.remove(id);
      }
    } else {
      if (_pending.isNotEmpty) {
        final id = _pending.keys.last;
        _outputs[id] = '${_outputs[id] ?? ''}$line\n';
      }
    }
  }

  void _handleErr(String line) {
    print('ExifTool error: $line');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final c in _pending.values) {
      c.completeError('ExifTool service disposed');
    }
    _pending.clear();
    _outputs.clear();

    await _outputSub?.cancel();
    await _errorSub?.cancel();

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
        _persistentProcess!.kill();
      } finally {
        _persistentProcess = null;
      }
    }
  }
}
