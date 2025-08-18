import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/services/core/logging_service.dart';

/// Persistent ExifTool wrapper with classic discovery API.
///
/// Public API:
///   - static Future<ExifToolService?> find([dynamic maybePreferredOrConfig])
///     * If String  => treat as preferred path
///     * If config  => try cfg.exifToolPath / cfg.exiftoolPath
///     * Else       => search in PATH (which/where) and common locations
///   - Future<void> startPersistentProcess()
///   - Future<Map<String, dynamic>> readExifData(File file)
///   - Future<void> writeExifData(File file, Map<String, dynamic> tags)
class ExifToolService with LoggerMixin {
  ExifToolService._(this._resolvedPath);

  final String _resolvedPath;

  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final _stdoutBuffer = StringBuffer();
  final _stderrBuffer = StringBuffer();
  int _seq = 0;
  final _pending = <int, _RequestCompleter>{};
  bool _starting = false;

  /// Classic discovery (restored signature used by your codebase).
  ///
  /// Order:
  ///  1) If [maybePreferredOrConfig] is a non-empty String => use if usable.
  ///  2) If it's a config-like object with exifToolPath / exiftoolPath => use if usable.
  ///  3) Try PATH via `which exiftool` / `where exiftool`.
  ///  4) Try a few common locations.
  static Future<ExifToolService?> find([dynamic maybePreferredOrConfig]) async {
    String? path;

    // 1) Preferred explicit path (string)
    if (maybePreferredOrConfig is String && maybePreferredOrConfig.isNotEmpty) {
      if (await _isExiftoolUsable(maybePreferredOrConfig)) {
        path = maybePreferredOrConfig;
      }
    }

    // 2) Config-like object (exifToolPath / exiftoolPath)
    if (path == null && maybePreferredOrConfig != null) {
      try {
        final p = _readPathFromConfigLikeObject(maybePreferredOrConfig);
        if (p != null && await _isExiftoolUsable(p)) {
          path = p;
        }
      } catch (_) {
        // ignore and continue
      }
    }

    // 3) PATH
    if (path == null) {
      final which = Platform.isWindows ? 'where' : 'which';
      try {
        final res = await Process.run(which, ['exiftool']);
        if (res.exitCode == 0) {
          final out = (res.stdout as String).trim();
          if (out.isNotEmpty) {
            // first line is the path on most systems
            final candidate = out.split(RegExp(r'\r?\n')).first.trim();
            if (candidate.isNotEmpty && await _isExiftoolUsable(candidate)) {
              path = candidate;
            }
          }
        }
      } catch (_) {
        // ignore and try common locations
      }
    }

    // 4) Common locations
    if (path == null) {
      const common = <String>[
        '/usr/bin/exiftool',
        '/usr/local/bin/exiftool',
        r'C:\Windows\exiftool.exe',
        r'C:\Program Files\exiftool\exiftool.exe',
      ];
      for (final c in common) {
        if (await _isExiftoolUsable(c)) {
          path = c;
          break;
        }
      }
    }

    if (path == null) return null;
    return ExifToolService._(path);
  }

  static Future<bool> _isExiftoolUsable(String path) async {
    try {
      final res = await Process.run(path, const ['-ver']);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static String? _readPathFromConfigLikeObject(dynamic cfg) {
    try {
      final p1 = (cfg as dynamic).exifToolPath;
      if (p1 is String && p1.isNotEmpty) return p1;
    } catch (_) {}
    try {
      final p2 = (cfg as dynamic).exiftoolPath;
      if (p2 is String && p2.isNotEmpty) return p2;
    } catch (_) {}
    return null;
  }

  /// Optional explicit startup; the process will also lazy-start on first request.
  Future<void> startPersistentProcess() => _ensureStarted();

  // ── Persistent process lifecycle ───────────────────────────────────────────

  Future<void> _ensureStarted() async {
    if (_proc != null) return;
    if (_starting) {
      // Wait until the other caller completes startup.
      while (_proc == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return;
    }
    _starting = true;
    try {
      _proc = await Process.start(
        _resolvedPath,
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

      logDebug('ExifTool started in persistent mode: $_resolvedPath');
    } catch (e) {
      _proc = null;
      logError('Failed to start exiftool ($_resolvedPath): $e');
      rethrow;
    } finally {
      _starting = false;
    }
  }

  void _onStdoutLine(String line) {
    // Each request ends with token: ----GPTH-READY-<seq>----
    if (line.startsWith('----GPTH-READY-')) {
      final idStr = line.replaceAll(RegExp(r'[^0-9]'), '');
      final id = int.tryParse(idStr);
      if (id != null && _pending.containsKey(id)) {
        final req = _pending.remove(id)!;
        final out = _stdoutBuffer.toString();
        _stdoutBuffer.clear();
        final err = _stderrBuffer.toString();
        _stderrBuffer.clear();
        req.complete(out, err);
      } else {
        // Orphan token: clear buffers to avoid mixing
        _stdoutBuffer.clear();
        _stderrBuffer.clear();
      }
    } else {
      _stdoutBuffer.writeln(line);
    }
  }

  void _onStderrLine(String line) {
    _stderrBuffer.writeln(line);
  }

  void _onExited() {
    logWarning('ExifTool process exited.');
    _proc = null;
  }

  Future<void> dispose() async {
    if (_proc == null) return;
    try {
      _sendRaw(['-stay_open', 'False']);
    } catch (_) {}
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _proc = null;
  }

  Future<_Response> _send(List<String> args) async {
    await _ensureStarted();
    final id = ++_seq;
    final c = _RequestCompleter(id);
    _pending[id] = c;

    final payload = <String>[
      ...args,
      '-echo3',
      '----GPTH-READY-$id----',
      '-execute',
    ];
    _sendRaw(payload);

    return c.future.timeout(
      const Duration(minutes: 2),
      onTimeout: () {
        _pending.remove(id);
        return _Response('', 'Timeout waiting for exiftool');
      },
    );
  }

  void _sendRaw(List<String> lines) {
    if (_proc == null) throw StateError('exiftool not started');
    final sink = _proc!.stdin;
    for (final l in lines) {
      sink.writeln(l);
    }
  }

  // ── Public read/write API ──────────────────────────────────────────────────

  /// Reads EXIF as Map<String, dynamic> using `-j -n`.
  Future<Map<String, dynamic>> readExifData(File file) async {
    final args = <String>[
      '-j',
      '-n',
      file.path,
    ];
    final res = await _send(args);
    if (res.stderr.isNotEmpty) {
      logDebug('[exiftool stderr] ${res.stderr}');
    }
    try {
      final json = jsonDecode(res.stdout);
      if (json is List && json.isNotEmpty && json.first is Map) {
        return (json.first as Map).cast<String, dynamic>();
      }
    } catch (e) {
      logWarning('Failed to parse exiftool JSON for ${file.path}: $e');
    }
    return <String, dynamic>{};
  }

  /// Writes tags in a single exiftool call.
  /// Example: {'DateTimeOriginal': '"2020:01:01 12:00:00"', 'GPSLatitude': '40.1'}
  Future<void> writeExifData(File file, Map<String, dynamic> tags) async {
    if (tags.isEmpty) return;

    final args = <String>[
      '-overwrite_original',
      ...tags.entries.map((e) => '-${e.key}=${e.value}'),
      file.path,
    ];

    final res = await _send(args);
    if (res.stderr.isNotEmpty) {
      logDebug('[exiftool write stderr] ${res.stderr}');
    }
  }
}

// ── Internal helpers ─────────────────────────────────────────────────────────

class _RequestCompleter {
  _RequestCompleter(this.id);
  final int id;
  final _c = Completer<_Response>();
  Future<_Response> get future => _c.future;
  void complete(String stdout, String stderr) {
    if (!_c.isCompleted) _c.complete(_Response(stdout, stderr));
  }
}

class _Response {
  _Response(this.stdout, this.stderr);
  final String stdout;
  final String stderr;
}
