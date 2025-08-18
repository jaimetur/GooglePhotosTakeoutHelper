import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/services/core/logging_service.dart';

/// ExifToolService: proceso persistente con -stay_open True
///
/// API pública:
///   - static Future<ExifToolService?> find(...?)          // compat con ServiceContainer
///   - Future<void> startPersistentProcess()               // arranque explícito (compat)
///   - Future<Map<String, dynamic>> readExifData(File file)
///   - Future<void> writeExifData(File file, Map<String, dynamic> tags)
///
/// Notas:
///  - Usa -j (JSON) / -n (valores numéricos crudos) para lecturas.
///  - Delimitamos respuestas con un token único vía `-echo3`.
///  - Un único proceso por instancia (puedes mantener una global en ServiceContainer).
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

  // ───────────────────────────────────────────────────────────────────────────
  // Compatibilidad con ServiceContainer
  // ───────────────────────────────────────────────────────────────────────────

  /// Método de compatibilidad para el código que llama `ExifToolService.find(...)`.
  /// Ignora los argumentos que reciba y busca `exiftool` en PATH o en una ruta sugerida.
  ///
  /// Ejemplos de firmas que puede encontrarse en tu base:
  ///   - ExifToolService.find()
  ///   - ExifToolService.find(preferredPath)
  ///   - ExifToolService.find(config)  ← en este caso lo ignoramos y probamos PATH
  static Future<ExifToolService?> find([dynamic maybePreferredOrConfig]) async {
    // Si nos pasaron una cadena, la probamos primero como ruta preferida.
    if (maybePreferredOrConfig is String && maybePreferredOrConfig.isNotEmpty) {
      if (await _isExiftoolUsable(maybePreferredOrConfig)) {
        return ExifToolService(exiftoolPath: maybePreferredOrConfig);
      }
    }

    // Si nos pasaron un objeto "config" con algo tipo exifToolPath, intenta leerlo.
    try {
      final dynamic cfg = maybePreferredOrConfig;
      final String? pathFromCfg = (cfg != null && cfg is Object)
          ? _readPathFromConfigLikeObject(cfg)
          : null;
      if (pathFromCfg != null && await _isExiftoolUsable(pathFromCfg)) {
        return ExifToolService(exiftoolPath: pathFromCfg);
      }
    } catch (_) {
      // ignoramos: mejor intentar PATH
    }

    // Prueba PATH (el binario "exiftool")
    if (await _isExiftoolUsable('exiftool')) {
      return ExifToolService(exiftoolPath: 'exiftool');
    }

    // Algunos sistemas instalan como "exiftool.exe" o rutas típicas
    final commonCandidates = <String>[
      '/usr/bin/exiftool',
      '/usr/local/bin/exiftool',
      r'C:\Windows\exiftool.exe',
      r'C:\Program Files\exiftool\exiftool.exe',
    ];
    for (final c in commonCandidates) {
      if (await _isExiftoolUsable(c)) {
        return ExifToolService(exiftoolPath: c);
      }
    }

    return null; // no encontrado
  }

  /// Arranque explícito del proceso persistente (compat con ServiceContainer).
  /// Si no lo llamas, el servicio arrancará lazy en la primera operación.
  Future<void> startPersistentProcess() => _ensureStarted();

  // Intenta leer `exifToolPath` de un objeto de config "parecido".
  static String? _readPathFromConfigLikeObject(dynamic cfg) {
    try {
      // Soporta: cfg.exifToolPath
      final dynamic p1 = (cfg as dynamic).exifToolPath;
      if (p1 is String && p1.isNotEmpty) return p1;
    } catch (_) {}
    try {
      // Soporta: cfg.exiftoolPath
      final dynamic p2 = (cfg as dynamic).exiftoolPath;
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

  // ───────────────────────────────────────────────────────────────────────────
  // Proceso persistente
  // ───────────────────────────────────────────────────────────────────────────

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
    // Token de fin: ----GPTH-READY-<seq>----
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
        // Orfano: limpia buffers
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

  // ───────────────────────────────────────────────────────────────────────────
  // API pública de lectura/escritura
  // ───────────────────────────────────────────────────────────────────────────

  /// Lee metadatos EXIF de un fichero y devuelve un Map<String, dynamic>
  Future<Map<String, dynamic>> readExifData(File file) async {
    final args = <String>[
      ...commonReadArgs,
      file.path,
    ];
    final res = await _send(args);
    if (res.stderr.isNotEmpty) {
      // ExifTool suele mandar warnings por stderr; no es necesariamente error.
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

  /// Escribe tags con exiftool en **UNA sola llamada**.
  /// Tags se pasa como {'DateTimeOriginal': '"yyyy:MM:dd HH:mm:ss"', 'GPSLatitude':'...'} etc.
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
    // Si hubiera un error duro, exiftool suele salir por stderr;
    // aquí lo exponemos via logs (la llamada no lanza a menos que el proceso caiga).
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
