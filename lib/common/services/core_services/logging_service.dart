import 'dart:io';
import 'package:gpth/gpth_lib_exports.dart';

/// Service for application logging with colored output and level filtering
///
/// Extracted from utils.dart to provide a clean, testable logging interface
/// that can be easily mocked and configured for different environments.
class LoggingService {
  /// Creates a new instance of LoggingService
  LoggingService({this.isVerbose = false, this.enableColors = true, this.saveLog = false}) {
    if (saveLog) _initFileSink();
  }

  /// Creates a logging service from processing configuration
  factory LoggingService.fromConfig(final ProcessingConfig config) =>
      LoggingService(
        isVerbose: config.verbose,
        enableColors:
            !Platform.isWindows || Platform.environment['TERM'] != null,
        saveLog: ServiceContainer.instance.globalConfig.saveLog,
      );

  /// Test override for quit/exit to prevent actual process termination in tests
  static void Function(int code)? testExitOverride;

  /// Whether verbose logging is enabled
  final bool isVerbose;

  /// Whether to use colored output (disable for file logging)
  final bool enableColors;

  /// Whether to also save logs to a file
  final bool saveLog;

  /// Creation timestamp used for per-instance information (file uses global timestamp)
  final DateTime _createdAt = DateTime.now();

  /// Global shared timestamp for the log filename (ensures a single file per process)
  static String? _globalTimestamp;

  /// Global shared sink and path so all instances write to the same file
  static IOSink? _globalSink;
  static String? _globalLogFilePath;

  /// Session header guard (avoid duplicating the header across instances)
  static bool _sessionHeaderWritten = false;

  /// Collected warning messages during processing
  final List<String> _warnings = [];

  /// Collected error messages during processing
  final List<String> _errors = [];

  /// Path of the log file if file logging is enabled (mirrors global path)
  String? _logFilePath;

  /// Sink used to persist logs to disk (points to global sink)
  IOSink? _fileSink;

  /// Log levels with associated colors
  static const Map<String, String> _levelColors = {
    'error': '\x1B[31m', // Red
    'warning': '\x1B[33m', // Yellow
    'info': '\x1B[32m', // Green
    'debug': '\x1B[36m', // Cyan
  };

  /// Logs a message with the specified level
  ///
  /// [message] The message to log
  /// [level] Log level: 'info', 'warning', 'error', 'debug'
  /// [forcePrint] If true, prints even when verbose mode is disabled
  void log(
    final String message, {
    final String level = 'info',
    final bool forcePrint = false,
  }) {
    // Always persist to file if enabled (without ANSI sequences)
    if (_fileSink != null) {
      final String plain = _formatPlainMessage(message, level);
      _writeToFile(plain);
    }

    // Print to console respecting verbosity / forcePrint
    if (isVerbose || forcePrint) {
      final String output = _formatMessage(message, level);
      print(output);
    }
  }

  /// Logs an info message
  void info(final String message, {final bool forcePrint = false}) {
    log(message, forcePrint: forcePrint);
  }

  /// Logs a warning message
  void warning(final String message, {final bool forcePrint = false}) {
    _warnings.add(message);
    log(message, level: 'warning', forcePrint: forcePrint);
  }

  /// Logs an error message
  void error(final String message, {final bool forcePrint = false}) {
    _errors.add(message);
    log(message, level: 'error', forcePrint: forcePrint);
  }

  /// Logs a debug message (only in verbose mode)
  void debug(final String message, {final bool forcePrint = false}) {
    log(message, level: 'debug', forcePrint: forcePrint);
  }

  /// Formats a message with level and color coding (for console)
  String _formatMessage(final String message, final String level) {
    final String levelUpper = level.toUpperCase();

    if (!enableColors) {
      return '[$levelUpper] $message';
    }

    final String color = _levelColors[level.toLowerCase()] ?? '';
    const String reset = '\x1B[0m';

    return '\r$color[$levelUpper] $message$reset';
  }

  /// Formats a message without ANSI (for file)
  String _formatPlainMessage(final String message, final String level) {
    final String levelUpper = level.toUpperCase();
    return '[$levelUpper] $message';
  }

  /// Creates a child logger with the same configuration
  LoggingService copyWith({final bool? isVerbose, final bool? enableColors, final bool? saveLog}) =>
      LoggingService(
        isVerbose: isVerbose ?? this.isVerbose,
        enableColors: enableColors ?? this.enableColors,
        saveLog: saveLog ?? this.saveLog,
      );

  /// Gets all collected warning messages
  List<String> get warnings => List.unmodifiable(_warnings);

  /// Gets all collected error messages
  List<String> get errors => List.unmodifiable(_errors);

  /// Gets the absolute path of the log file if enabled
  String? get logFilePath => _logFilePath;

  /// Whether file logging is currently enabled and sink is open
  bool get isFileLoggingEnabled => _fileSink != null;

  /// Clears all collected warning and error messages
  void clearCollectedMessages() {
    _warnings.clear();
    _errors.clear();
  }

  /// Prints error message to stderr with newline
  void errorToStderr(final Object? object) {
    stderr.write('$object\n');
    if (_fileSink != null) _writeToFile('[STDERR] $object');
  }

  /// Exits the program with optional code, showing interactive message if needed
  ///
  /// [code] Exit code (default: 1)
  Never quit([final int code = 1]) {
    // Allow tests to intercept exit to avoid terminating the test process
    final override = testExitOverride;
    if (override != null) {
      override(code);
      throw _LoggingTestExitException(code);
    }

    if (Platform.environment['INTERACTIVE'] == 'true') {
      print('[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - press enter to close]');
      stdin.readLineSync();
    }
    // Best-effort flush/close without awaiting (keep method signature sync)
    try { _globalSink?.flush(); } catch (_) {}
    try { _globalSink?.close(); } catch (_) {}
    _fileSink = null;
    _globalSink = null;
    exit(code);
  }

  /// Initializes the file sink and directory, using a global session timestamp.
  void _initFileSink() {
    try {
      // Reuse global sink if already initialized
      if (_globalSink != null && _globalLogFilePath != null) {
        _fileSink = _globalSink;
        _logFilePath = _globalLogFilePath;
        return;
      }

      final Directory dir = Directory('Logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Use (or set) a global timestamp so every instance writes to the same file
      final String ts = _globalTimestamp ??= _tsForFilename(DateTime.now());
      final String candidatePath = '${dir.path}${Platform.pathSeparator}gpth-v${version}_$ts.log';
      final File f = File(candidatePath);

      // Create file explicitly (Windows/Google Drive can fail with append-open on non-existing files)
      if (!f.existsSync()) f.createSync(recursive: true);

      IOSink sink;
      String pathUsed;

      // Primary attempt: normal path + write (not append)
      try {
        pathUsed = f.absolute.path;
        sink = f.openWrite(mode: FileMode.write);
      } on FileSystemException {
        // Windows fallback: try extended-length path (\\?\)
        if (Platform.isWindows) {
          final String ext = _toExtendedWindowsPath(f.absolute.path);
          final File f2 = File(ext);
          if (!f2.existsSync()) f2.createSync(recursive: true);
          pathUsed = f2.path;
          sink = f2.openWrite(mode: FileMode.write);
        } else {
          rethrow;
        }
      }

      // Assign globals so every new instance will reuse the same sink/path
      _globalSink = sink;
      _globalLogFilePath = pathUsed;
      _fileSink = _globalSink;
      _logFilePath = _globalLogFilePath;

      // Session header only once per process
      if (!_sessionHeaderWritten) {
        _globalSink!.writeln('[INFO] ===== GPTH Logging started ${_createdAt.toIso8601String()} =====');
        _globalSink!.writeln('[INFO] Log file: $_globalLogFilePath');
        _globalSink!.writeln('[INFO] Platform: ${Platform.operatingSystem} ${Platform.version.split(' ').first}');
        _globalSink!.writeln('[INFO] GPTH Version: $version');
        _sessionHeaderWritten = true;
      }
    } catch (e) {
      // If file sink fails, keep console logging; do not crash the app.
      _fileSink = null;
      _logFilePath = null;
      _globalSink = null;
      _globalLogFilePath = null;
    }

    // Last-resort fallback to system temp if globals are still null
    if (_globalSink == null || _globalLogFilePath == null) {
      try {
        final Directory tmp = Directory.systemTemp;
        final String ts = _globalTimestamp ??= _tsForFilename(DateTime.now());
        final String altPath = '${tmp.path}${Platform.pathSeparator}gpth_$ts.log';
        final File alt = File(altPath);
        if (!alt.existsSync()) alt.createSync(recursive: true);
        _globalLogFilePath = alt.absolute.path;
        _globalSink = alt.openWrite(mode: FileMode.write);
        _fileSink = _globalSink;
        _logFilePath = _globalLogFilePath;

        if (!_sessionHeaderWritten) {
          _globalSink!.writeln('[INFO] ===== GPTH Logging started ${_createdAt.toIso8601String()} =====');
          _globalSink!.writeln('[INFO] Log file: $_globalLogFilePath');
          _globalSink!.writeln('[INFO] Platform: ${Platform.operatingSystem} ${Platform.version.split(' ').first}');
          _sessionHeaderWritten = true;
        }
      } catch (_) {
        _fileSink = null;
        _logFilePath = null;
        _globalSink = null;
        _globalLogFilePath = null;
      }
    }
  }

  /// Writes a single line to the log file without ANSI control codes.
  void _writeToFile(final String line) {
    try {
      _fileSink?.writeln(line);
    } catch (_) {
      // Swallow file I/O errors to avoid breaking the application flow.
    }
  }

  /// Formats timestamp as yyyymmdd-hhmmss for filenames.
  String _tsForFilename(final DateTime dt) {
    String two(final int v) => v < 10 ? '0$v' : '$v';
    final String y = dt.year.toString().padLeft(4, '0');
    final String m = two(dt.month);
    final String d = two(dt.day);
    final String h = two(dt.hour);
    final String mi = two(dt.minute);
    final String s = two(dt.second);
    return '$y$m$d-$h$mi$s';
  }

  /// Converts an absolute Windows path to extended-length form (\\?\ or \\?\UNC\)
  String _toExtendedWindowsPath(final String absPath) {
    // Already extended or device path
    if (absPath.startsWith(r'\\?\') || absPath.startsWith(r'\\.\')) return absPath;
    // UNC path
    if (absPath.startsWith(r'\\')) return r'\\?\UNC\' + absPath.substring(2);
    return r'\\?\' + absPath;
  }

  /// Closes the file sink gracefully (optional; console logging unaffected).
  void close() {
    try { _globalSink?.flush(); } catch (_) {}
    try { _globalSink?.close(); } catch (_) {}
    _fileSink = null;
    _globalSink = null;
  }
}

/// Extension to add logging capabilities to any class
mixin LoggerMixin {
  LoggingService? _logger;

  /// Shared default logger so that all classes using this mixin write to the same session/file
  static LoggingService? _sharedDefaultLogger;

  /// Gets or creates a logger instance with default configuration
  // ignore: prefer_expression_function_bodies
  LoggingService get logger {
    // Always use a default logger to avoid circular dependencies
    // Services that need specific logging configuration should inject it explicitly
    if (_logger != null) return _logger!;
    // Create (or reuse) a shared default logger that respects global saveLog setting
    return _logger ??= _sharedDefaultLogger ??= _createDefaultLoggerFromGlobalConfig();
  }

  /// Sets a custom logger
  set logger(final LoggingService newLogger) => _logger = newLogger;

  /// Logs an info message
  void logInfo(final String message, {final bool forcePrint = false}) {
    logger.info(message, forcePrint: forcePrint);
  }

  /// Logs a warning message
  void logWarning(final String message, {final bool forcePrint = false}) {
    logger.warning(message, forcePrint: forcePrint);
  }

  /// Logs an error message
  void logError(final String message, {final bool forcePrint = false}) {
    logger.error(message, forcePrint: forcePrint);
  }

  /// Logs a debug message
  void logDebug(final String message, {final bool forcePrint = false}) {
    logger.debug(message, forcePrint: forcePrint);
  }

  /// Creates the default logger reading ServiceContainer.instance.globalConfig.saveLog
  static LoggingService _createDefaultLoggerFromGlobalConfig() {
    bool save = false;
    try {
      // Defensive: in case ServiceContainer or globalConfig is not initialized yet
      final sc = ServiceContainer.instance;
      final cfg = sc.globalConfig;
      save = cfg.saveLog == true;
    } catch (_) {
      save = false;
    }
    final bool colors = !Platform.isWindows || Platform.environment['TERM'] != null;
    return LoggingService(isVerbose: false, enableColors: colors, saveLog: save);
  }
}

/// Exception thrown by quit when test override is active
class _LoggingTestExitException implements Exception {
  const _LoggingTestExitException(this.code);
  final int code;

  @override
  String toString() =>
      'Application attempted to quit with exit code $code. '
      'This indicates a fatal error or completion condition was reached. '
      'In production, this would terminate the application immediately. '
      'Review the logs above for the specific reason for termination.';
}
