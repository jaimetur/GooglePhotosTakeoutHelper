import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/services/core/logging_service.dart';

/// ExifTool infrastructure service (4.2.2-style) with 4.2.1/4.2.2 discovery
/// semantics for bin/script/parent directories, plus batch helpers.
///
/// Highlights:
/// - Discovery:
///   * PATH first
///   * Relative search around binary/script/parents (same as 4.2.1/4.2.2)
///   * which/where fallback
///   * common install paths (+ Windows exiftool(-k).exe)
/// - Execution:
///   * One-shot by default (compatible with 4.2.1 behavior)
///   * Optional persistent process with tokenized responses (faster on bulk)
/// - Batch write helpers:
///   * writeExifDataBatchSameTags: same tag set to many files
///   * writeExifDataBatchPerFile: different tag sets per file (uses persistent)
class ExifToolService with LoggerMixin {
  ExifToolService(this.exiftoolPath);

  final String exiftoolPath;

  // ── Persistent process state ────────────────────────────────────────────────
  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final _stdoutBuf = StringBuffer();
  final _stderrBuf = StringBuffer();
  final _pending = <int, _Req>{};
  int _seq = 0;
  bool _starting = false;
  bool _disposed = false;

  // Debug discovery via GPTH_EXIFTOOL_DEBUG=1
  static bool get _debugDiscovery =>
      (Platform.environment['GPTH_EXIFTOOL_DEBUG'] ?? '') == '1';
  static void _d(String m) {
    if (_debugDiscovery) {
      // ignore: avoid_print
      print('[EXIFTOOL-DISCOVERY] $m');
    }
  }

  // ── Discovery (keeps 4.2.1/4.2.2 relative search order) ────────────────────
  static Future<ExifToolService?> find({
    bool showDiscoveryMessage = true,
  }) async {
    final isWindows = Platform.isWindows;
    final exiftoolNames = isWindows
        ? <String>['exiftool.exe', 'exiftool', 'exiftool(-k).exe']
        : <String>['exiftool'];

    // 1) PATH first
    for (final name in exiftoolNames) {
      try {
        final r = await Process.run(name, const ['-ver']);
        if (r.exitCode == 0) {
          if (showDiscoveryMessage) {
            final v = r.stdout.toString().trim();
            print('ExifTool found in PATH: $name (version $v)');
          }
          return ExifToolService(name);
        }
      } catch (_) {/* continue */}
    }

    // 2) Relative search around the binary/script/parents
    String? binDir;
    try {
      binDir = File(Platform.resolvedExecutable).parent.path;
      if (showDiscoveryMessage) {
        print('Binary directory: $binDir');
      }
    } catch (_) {
      binDir = null;
    }

    final String? scriptPath = Platform.script.toFilePath();
    final String? scriptDir =
        (scriptPath != null && scriptPath.isNotEmpty) ? File(scriptPath).parent.path : null;
    if (scriptDir != null && showDiscoveryMessage) {
      print('Script directory: $scriptDir');
    }

    final candidateDirs = <String?>[
      binDir,
      scriptDir,
      if (binDir != null) p.join(binDir, 'exif_tool'),
      if (scriptDir != null) p.join(scriptDir, 'exif_tool'),
      Directory.current.path,
      p.join(Directory.current.path, 'exif_tool'),
      if (scriptDir != null) p.dirname(scriptDir),
      if (binDir != null) p.dirname(binDir),
      if (binDir != null) p.join(p.dirname(binDir), 'exif_tool'),
    ];

    for (final dir in candidateDirs) {
      if (dir == null || dir.isEmpty) continue;
      for (final exeName in exiftoolNames) {
        final f = File(p.join(dir, exeName));
        if (await f.exists()) {
          try {
            final r = await Process.run(f.path, const ['-ver']);
            if (r.exitCode == 0) {
              if (showDiscoveryMessage) {
                final v = r.stdout.toString().trim();
                print('ExifTool found: ${f.path} (version $v)');
              }
              return ExifToolService(f.path);
            }
          } catch (_) {/* continue */}
        }
      }
    }

    // 3) which/where fallback
    final which = Platform.isWindows ? 'where' : 'which';
    try {
      final r = await Process.run(which, const ['exiftool']);
      if (r.exitCode == 0) {
        final out = (r.stdout as String).trim();
        final lines = out.split(RegExp(r'\r?\n')).where((s) => s.trim().isNotEmpty);
        for (final cand in lines) {
          try {
            final r2 = await Process.run(cand.trim(), const ['-ver']);
            if (r2.exitCode == 0) {
              if (showDiscoveryMessage) {
                final v = r2.stdout.toString().trim();
                print('ExifTool found via $which: $cand (version $v)');
              }
              return ExifToolService(cand.trim());
            }
          } catch (_) {/* continue */}
        }
      } else {
        _d('$which exitCode=${r.exitCode}, stderr="${r.stderr}"');
      }
    } catch (e) {
      _d('$which threw: $e');
    }

    // 4) Common install paths
    final common = isWindows
        ? <String>[
            r'C:\Program Files\exiftool\exiftool.exe',
            r'C:\Program Files (x86)\exiftool\exiftool.exe',
            r'C:\exiftool\exiftool.exe',
          ]
        : <String>[
            '/usr/bin/exiftool',
            '/usr/local/bin/exiftool',
            '/opt/homebrew/bin/exiftool',
          ];

    for (final path in common) {
      if (await File(path).exists()) {
        try {
          final r = await Process.run(path, const ['-ver']);
          if (r.exitCode == 0) {
            if (showDiscoveryMessage) {
              final v = r.stdout.toString().trim();
              print('ExifTool found: $path (version $v)');
            }
            return ExifToolService(path);
          }
        } catch (_) {/* continue */}
      }
    }

    return null;
  }

  // ── Persistent process (optional, tokenized) ───────────────────────────────
  Future<void> startPersistentProcess() async {
    if (_proc != null || _starting || _disposed) return;
    _starting = true;
    try {
      _proc = await Process.start(
        exiftoolPath,
        const ['-stay_open', 'True', '-@', '-'],
        mode: ProcessStartMode.detachedWithStdio,
      );

      _stdoutSub = _proc!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onStdoutLine, onDone: _onExited);
      _stderrSub = _proc!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onStderrLine, onDone: _onExited);

      logDebug('ExifTool started (persistent): $exiftoolPath');
    } catch (e) {
      logError('Failed to start exiftool persistently: $e');
      _proc = null;
    } finally {
      _starting = false;
    }
  }

  void _onStdoutLine(String line) {
    if (line.startsWith('----GPTH-READY-')) {
      final idStr = line.replaceAll(RegExp(r'[^0-9]'), '');
      final id = int.tryParse(idStr);
      final req = (id != null) ? _pending.remove(id) : null;
      final out = _stdoutBuf.toString();
      final err = _stderrBuf.toString();
      _stdoutBuf.clear();
      _stderrBuf.clear();
      req?._complete(out, err);
      return;
    }
    _stdoutBuf.writeln(line);
  }

  void _onStderrLine(String line) {
    _stderrBuf.writeln(line);
  }

  void _onExited() {
    logWarning('ExifTool persistent process exited.');
    _proc = null;
  }

  Future<_Resp> _sendPersistent(List<String> args) async {
    await _ensureStarted();
    final id = ++_seq;
    final req = _Req(id);
    _pending[id] = req;

    final payload = <String>[
      ...args,
      '-echo3',
      '----GPTH-READY-$id----',
      '-execute',
    ];
    final sink = _proc!.stdin;
    for (final l in payload) {
      sink.writeln(l);
    }

    return req.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        _pending.remove(id);
        return _Resp('', 'Timeout waiting for exiftool');
      },
    );
  }

  Future<void> _ensureStarted() async {
    if (_proc != null) return;
    if (_starting) {
      while (_proc == null && !_disposed) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return;
    }
    await startPersistentProcess();
    if (_proc == null) {
      throw StateError('Failed to start exiftool persistent process.');
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final r in _pending.values.toList()) {
      r._complete('', 'Disposed');
    }
    _pending.clear();

    final p = _proc;
    _proc = null;

    try {
      await _stdoutSub?.cancel();
    } catch (_) {}
    _stdoutSub = null;
    try {
      await _stderrSub?.cancel();
    } catch (_) {}
    _stderrSub = null;

    if (p != null) {
      try {
        p.stdin.writeln('-stay_open');
        p.stdin.writeln('False');
        await p.stdin.flush();
        await p.stdin.close();
      } catch (_) {}
      try {
        await p.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            try {
              p.kill();
            } catch (_) {}
            return -1;
          },
        );
      } catch (_) {
        try {
          p.kill();
        } catch (_) {}
      }
    }
  }

  // ── Public API (one-shot by default; persistent optional) ──────────────────

  Future<String> executeCommand(List<String> args) async {
    final res = await Process.run(exiftoolPath, args);
    if (res.exitCode != 0) {
      logger.error('ExifTool command failed (code ${res.exitCode})');
      logger.error('Command: $exiftoolPath ${args.join(' ')}');
      logger.error('stderr: ${res.stderr}');
      throw Exception(
        'ExifTool command failed with exit code ${res.exitCode}: ${res.stderr}',
      );
    }
    return res.stdout.toString();
  }

  Future<String> executeCommandPersistent(List<String> args) async {
    final resp = await _sendPersistent(args);
    if (resp.stderr.isNotEmpty &&
        !resp.stderr.toLowerCase().contains('warning')) {
      logger.error('ExifTool persistent stderr: ${resp.stderr}');
    }
    return resp.stdout;
  }

  Future<Map<String, dynamic>> readExifData(
    File file, {
    bool usePersistent = false,
  }) async {
    final args = <String>['-fast', '-j', '-n', file.path];
    final output =
        usePersistent ? await executeCommandPersistent(args) : await executeCommand(args);

    if (output.trim().isEmpty) {
      print('ExifTool returned empty output for file: ${file.path}');
      return {};
    }

    try {
      final List<dynamic> json = jsonDecode(output);
      if (json.isNotEmpty && json.first is Map) {
        final data = (json.first as Map).cast<String, dynamic>();

        // Normalize GPS refs
        final latRef = data['GPSLatitudeRef'];
        if (latRef == 'North') data['GPSLatitudeRef'] = 'N';
        if (latRef == 'South') data['GPSLatitudeRef'] = 'S';

        final lonRef = data['GPSLongitudeRef'];
        if (lonRef == 'East') data['GPSLongitudeRef'] = 'E';
        if (lonRef == 'West') data['GPSLongitudeRef'] = 'W';

        return data;
      }
      return {};
    } catch (e) {
      print('Failed to parse ExifTool JSON output: $e');
      print('Raw output was: "$output"');
      return {};
    }
  }

  Future<void> writeExifData(
    File file,
    Map<String, dynamic> tags, {
    bool usePersistent = false,
  }) async {
    if (tags.isEmpty) return;
    final args = <String>['-overwrite_original', ..._tagsToArgs(tags), file.path];
    final out =
        usePersistent ? await executeCommandPersistent(args) : await executeCommand(args);

    if (out.contains('error') ||
        out.contains('Error') ||
        out.contains("weren't updated due to errors")) {
      print('ExifTool may have encountered an error writing to ${file.path}');
      print('Output: $out');
      throw Exception('ExifTool failed to write metadata to ${file.path}: $out');
    }
  }

  /// Batch: write the SAME tag set to many files (split in chunks).
  Future<void> writeExifDataBatchSameTags(
    List<File> files,
    Map<String, dynamic> tags, {
    bool usePersistent = false,
    int chunkSize = 64,
  }) async {
    if (files.isEmpty || tags.isEmpty) return;
    for (int i = 0; i < files.length; i += chunkSize) {
      final chunk = files.sublist(i, (i + chunkSize).clamp(0, files.length));
      final args = <String>['-overwrite_original', ..._tagsToArgs(tags)];
      args.addAll(chunk.map((f) => f.path));
      final out = usePersistent
          ? await executeCommandPersistent(args)
          : await executeCommand(args);

      if (out.contains('error') ||
          out.contains('Error') ||
          out.contains("weren't updated due to errors")) {
        throw Exception('ExifTool batch (same tags) reported issues: $out');
      }
    }
  }

  /// Batch: write DIFFERENT tag sets per file (uses persistent channel).
  Future<void> writeExifDataBatchPerFile(
    Map<File, Map<String, dynamic>> perFileTags, {
    int chunkSize = 32,
  }) async {
    if (perFileTags.isEmpty) return;
    await startPersistentProcess();

    final entries = perFileTags.entries.toList();
    for (int i = 0; i < entries.length; i += chunkSize) {
      final chunk = entries.sublist(i, (i + chunkSize).clamp(0, entries.length));

      final args = <String>['-overwrite_original'];
      for (final e in chunk) {
        args.addAll(_tagsToArgs(e.value));
        args.add(e.key.path);
      }

      final out = await executeCommandPersistent(args);
      if (out.contains('error') ||
          out.contains('Error') ||
          out.contains("weren't updated due to errors")) {
        throw Exception('ExifTool batch (per file) reported issues: $out');
      }
    }
  }

  List<String> _tagsToArgs(Map<String, dynamic> tags) {
    final args = <String>[];
    tags.forEach((k, v) => args.add('-$k=$v'));
    return args;
  }
}

class _Req {
  _Req(this.id);
  final int id;
  final _c = Completer<_Resp>();
  Future<_Resp> get future => _c.future;
  void _complete(String out, String err) {
    if (!_c.isCompleted) _c.complete(_Resp(out, err));
  }
}

class _Resp {
  _Resp(this.stdout, this.stderr);
  final String stdout;
  final String stderr;
}
