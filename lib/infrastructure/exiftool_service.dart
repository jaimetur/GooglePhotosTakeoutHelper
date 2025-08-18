import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/services/core/logging_service.dart';

/// ExifToolService: proceso persistente con -stay_open True
///
/// API pública:
///   - Future<Map<String, dynamic>> readExifData(File file)
///   - Future<void> writeExifData(File file, Map<String, dynamic> tags)
///
/// Notas:
///  - Usa -j (JSON) / -n (valores numéricos crudos)
///  - Delimitamos respuestas con un token único vía `-echo3`
///  - Un único proceso por instancia (puedes tener una global en ServiceContainer)
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

  Future<void> _ensureStarted() async {
    if (_proc != null) return;
    if (_starting) {
      // Espera a que alguien más termine de arrancar
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
    // Rellenamos buffers y detectamos token de final
    // Formato token: ----GPTH-READY-<seq>----
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
        // Orfano: limpiar buffers
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

    // Enviamos args + echo + execute
    // echo3 escribe al STDOUT el token de listo.
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

  /// Lee metadatos EXIF de un fichero y devuelve un Map<String, dynamic>
  Future<Map<String, dynamic>> readExifData(File file) async {
    final args = <String>[
      ...commonReadArgs,
      file.path,
    ];
    final res = await _send(args);
    if (res.stderr.isNotEmpty) {
      // ExifTool suele mandar warnings por stderr; no tratarlos como fallo duro.
      logDebug('[exiftool stderr] ${res.stderr}');
    }
    try {
      final json = jsonDecode(res.stdout);
      if (json is List && json.isNotEmpty && json.first is Map) {
        return (json.first as Map).cast<String, dynamic>();
      }
    } catch (e) {
      // Algunos formatos no devuelven JSON limpio en ciertos casos.
      logWarning('Failed to parse exiftool JSON for ${file.path}: $e');
    }
    return <String, dynamic>{};
  }

  /// Escribe tags con exiftool en UNA sola llamada.
  /// Tags se pasa como {'DateTimeOriginal': '"2020:01:01 12:00:00"', 'GPSLatitude':'...'} etc.
  Future<void> writeExifData(File file, Map<String, dynamic> tags) async {
    if (tags.isEmpty) return;

    final args = <String>[
      ...commonWriteArgs,
      // Convertimos tags → -TAG=VALUE
      ...tags.entries.map((e) => '-${e.key}=${e.value}'),
      file.path,
    ];

    final res = await _send(args);
    if (res.stderr.isNotEmpty) {
      logDebug('[exiftool write stderr] ${res.stderr}');
    }
    // exiftool devuelve texto libre; si algo crítico falla, suele salir por stderr.
  }
}

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
