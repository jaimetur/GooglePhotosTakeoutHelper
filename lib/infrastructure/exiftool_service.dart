import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/services/core/logging_service.dart';

/// Persistent ExifTool wrapper.
/// Keeps a single `exiftool` process alive (-stay_open True) and multiplexes
/// requests using a unique token printed via -echo3.
///
/// Public API:
///   - static Future<ExifToolService?> find({dynamic preferredOrConfig, bool showDiscoveryMessage = true})
///   - Future<void> startPersistentProcess()
///   - Future<Map<String, dynamic>> readExifData(File file)
///   - Future<void> writeExifData(File file, Map<String, dynamic> tags)
class ExifToolService with LoggerMixin {
  ExifToolService({
    this.exiftoolPath = 'exiftool',
    this.commonReadArgs = const ['-j', '-n'],
    this.commonWriteArgs = const ['-overwrite_original'],
  });

  final String exiftoolPath;
  final List<String> commonReadArgs;
  final List<String> commonWriteArgs;

  Process? _proc;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final _stdoutBuffer = StringBuffer();
  final _stderrBuffer = StringBuffer();
  int _seq = 0;
  final _pending = <int, _RequestCompleter>{};
  bool _starting = false;

  // ── Discovery used by ServiceContainer ─────────────────────────────────────

  /// Finds a usable exiftool binary. Supports:
  ///   - preferredOrConfig: string path or config-like object exposing
  ///       `exifToolPath` or `exiftoolPath`
  ///   - showDiscoveryMessage: prints a one-liner when a path is found
  static Future<ExifToolService?> find({
    dynamic preferredOrConfig,
    bool showDiscoveryMessage = true,
  }) async {
    String? chosenPath;

    // 1) Preferred explicit path (string)
    if (preferredOrConfig is String && preferredOrConfig.isNotEmpty) {
      if (await _isExiftoolUsable(preferredOrConfig)) {
        chosenPath = preferredOrConfig;
      }
    }

    // 2) Config-like object with exifToolPath / exiftoolPath
    if (chosenPath == null && preferredOrConfig != null) {
      try {
        final p = _readPathFromConfigLikeObject(preferredOrConfig);
        if (p != null && await _isExiftoolUsable(p)) {
          chosenPath = p;
        }
      } catch (_) {
        // ignore and try PATH
      }
    }

    // 3) PATH
    if (chosenPath == null && await _isExiftoolUsable('exiftool')) {
      chosenPath = 'exiftool';
    }

    // 4) Common locations
    if (chosenPath == null) {
      const common = <String>[
        '/usr/bin/exiftool',
        '/usr/local/bin/exiftool',
        r'C:\Windows\exiftool.exe',
        r'C:\Program Files\exiftool\exiftool.exe',
      ];
      for (final c in common) {
        if (await _isExiftoolUsable(c)) {
          chosenPath = c;
          break;
        }
      }
    }

    if (chosenPath == null) return null;

    if (showDiscoveryMessage) {
      // Use logger mixin printing to stdout; no instance required.
      // ignore: avoid_print
      print('[INFO] Found exiftool at: $chosenPath');
    }

    return ExifToolService(exiftoolPath: chosenPath);
  }

  /// Explicit startup (optional). Lazy-start happens on first request anyway.
  Future<void> startPersistentProcess() => _ensureStarted();

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

  static Future<bool> _isExiftoolUsable(String path) async {
    try {
      final res = await Process.run(path, ['-ver']);
      return res.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ── Persistent process lifecycle ───────────────────────────────────────────

  Future<void> _ensureStarted() async {
    if (_proc != null) return;
    if (_starting) {
      while (_proc == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return;
    }
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

      logDebug('ExifTool started in persistent mode.');
    } catch (e) {
      _proc = null;
      logError('Failed to start exiftool: $e');
      rethrow;
    } finally {
      _starting = false;
    }
  }

  void _onStdoutLine(String line) {
    // Response terminator: ----GPTH-READY-<seq>----
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
      ...commonReadArgs,
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
      ...commonWriteArgs,
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
