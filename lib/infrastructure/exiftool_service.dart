import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/services/core/logging_service.dart';

/// ExifToolService: persistent process wrapper around `exiftool`
///
/// Public API:
///   - static Future<ExifToolService?> find([preferredOrConfig], {bool showDiscoveryMessage = true})
///   - Future<void> startPersistentProcess()
///   - Future<Map<String, dynamic>> readExifData(File file)
///   - Future<void> writeExifData(File file, Map<String, dynamic> tags)
///
/// Notes:
///  - Uses `-stay_open True` + `-@ -` to keep a single process alive.
///  - Uses `-j -n` for reads (JSON + numeric/raw values).
///  - Uses a unique token via `-echo3` to delimit responses.
///  - One instance can be shared app-wide (e.g., via ServiceContainer).
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
  // Discovery expected by ServiceContainer
  // ───────────────────────────────────────────────────────────────────────────

  /// Flexible discovery method used by ServiceContainer.
  ///
  /// Supported call shapes:
  ///   - ExifToolService.find()
  ///   - ExifToolService.find('/custom/path/to/exiftool')
  ///   - ExifToolService.find(configLikeObjectWithPath)
  ///   - ExifToolService.find(showDiscoveryMessage: bool)
  ///   - ExifToolService.find('/path/or/config', showDiscoveryMessage: bool)
  static Future<ExifToolService?> find(
  [dynamic maybePreferredOrConfig],
  {bool showDiscoveryMessage = true},
  ) async {
  String? chosenPath;

  // 1) If a string is provided, treat it as a preferred binary path.
  if (maybePreferredOrConfig is String && maybePreferredOrConfig.isNotEmpty) {
  if (await _isExiftoolUsable(maybePreferredOrConfig)) {
  chosenPath = maybePreferredOrConfig;
  }
  }

  // 2) If a config-like object is provided, try to extract a path from it.
  if (chosenPath == null && maybePreferredOrConfig != null) {
  try {
  final String? pathFromCfg =
  _readPathFromConfigLikeObject(maybePreferredOrConfig);
  if (pathFromCfg != null && await _isExiftoolUsable(pathFromCfg)) {
  chosenPath = pathFromCfg;
  }
  } catch (_) {
  // Ignore and continue with PATH probing.
  }
  }

  // 3) Try PATH.
  if (chosenPath == null && await _isExiftoolUsable('exiftool')) {
  chosenPath = 'exiftool';
  }

  // 4) Try a few common locations.
  if (chosenPath == null) {
  final commonCandidates = <String>[
  '/usr/bin/exiftool',
  '/usr/local/bin/exiftool',
  r'C:\Windows\exiftool.exe',
  r'C:\Program Files\exiftool\exiftool.exe',
  ];
  for (final c in commonCandidates) {
  if (await _isExiftoolUsable(c)) {
  chosenPath = c;
  break;
  }
  }
  }

  if (chosenPath == null) return null;

  if (showDiscoveryMessage) {
  // Print via logger mixin for consistency with your logging.
  ExifToolService().logInfo('Found exiftool at: $chosenPath', forcePrint: true);
  }

  return ExifToolService(exiftoolPath: chosenPath);
  }

  /// Explicit startup of the persistent process, kept for ServiceContainer compatibility.
  /// If you do not call this, the process will be started lazily on the first operation.
  Future<void> startPersistentProcess() => _ensureStarted();

  /// Attempt to read a candidate path from a config-like object:
  ///   - cfg.exifToolPath
  ///   - cfg.exiftoolPath
  static String? _readPathFromConfigLikeObject(dynamic cfg) {
  try {
  final dynamic p1 = (cfg as dynamic).exifToolPath;
  if (p1 is String && p1.isNotEmpty) return p1;
  } catch (_) {}
  try {
  final dynamic p2 = (cfg as dynamic).exiftoolPath;
  if (p2 is String && p2.isNotEmpty) return p2;
  } catch (_) {}
  return null;
  }

  /// Checks whether exiftool at [path] can run (`exiftool -ver`).
  static Future<bool> _isExiftoolUsable(String path) async {
  try {
  final res = await Process.run(path, ['-ver']);
  return res.exitCode == 0;
  } catch (_) {
  return false;
  }
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Persistent process lifecycle
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> _ensureStarted() async {
  if (_proc != null) return;
  if (_starting) {
  // If another caller is already starting the process, wait until it's up.
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
  // Each request ends with a unique token: ----GPTH-READY-<seq>----
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
  // Orphaned token: clear buffers to avoid cross-contamination.
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

  // We send: args + -echo3 <token> + -execute
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
  // Public read/write API
  // ───────────────────────────────────────────────────────────────────────────

  /// Reads EXIF/metadata for [file] and returns a Map<String, dynamic>.
  /// Uses `-j -n` for compact, parseable JSON with numeric/raw values.
  Future<Map<String, dynamic>> readExifData(File file) async {
  final args = <String>[
  ...commonReadArgs,
  file.path,
  ];
  final res = await _send(args);
  if (res.stderr.isNotEmpty) {
  // ExifTool often writes warnings to stderr; not necessarily a hard error.
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

  /// Writes [tags] to [file] in a **single** exiftool invocation.
  /// Example tags:
  ///   {'DateTimeOriginal': '"2020:01:01 12:00:00"', 'GPSLatitude': '40.1', ...}
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
  // If exiftool encounters a hard error, it typically prints to stderr.
  // We log stderr but do not throw to keep the caller logic simple.
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal request/response helpers
// ─────────────────────────────────────────────────────────────────────────────

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
