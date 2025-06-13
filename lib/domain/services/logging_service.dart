import 'dart:io';
import '../models/processing_config_model.dart';

/// Service for application logging with colored output and level filtering
///
/// Extracted from utils.dart to provide a clean, testable logging interface
/// that can be easily mocked and configured for different environments.
class LoggingService {
  /// Creates a new instance of LoggingService
  const LoggingService({this.isVerbose = false, this.enableColors = true});

  /// Creates a logging service from processing configuration
  factory LoggingService.fromConfig(final ProcessingConfig config) =>
      LoggingService(
        isVerbose: config.verbose,
        enableColors:
            !Platform.isWindows || Platform.environment['TERM'] != null,
      );

  /// Whether verbose logging is enabled
  final bool isVerbose;

  /// Whether to use colored output (disable for file logging)
  final bool enableColors;

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
    log(message, level: 'warning', forcePrint: forcePrint);
  }

  /// Logs an error message
  void error(final String message) {
    log(message, level: 'error');
  }

  /// Logs a debug message (only in verbose mode)
  void debug(final String message) {
    log(message, level: 'debug');
  }

  /// Formats a message with level and color coding
  String _formatMessage(final String message, final String level) {
    final String levelUpper = level.toUpperCase();

    if (!enableColors) {
      return '[$levelUpper] $message';
    }

    final String color = _levelColors[level.toLowerCase()] ?? '';
    const String reset = '\x1B[0m';

    return '\r$color[$levelUpper] $message$reset';
  }

  /// Creates a child logger with the same configuration
  LoggingService copyWith({final bool? isVerbose, final bool? enableColors}) =>
      LoggingService(
        isVerbose: isVerbose ?? this.isVerbose,
        enableColors: enableColors ?? this.enableColors,
      );

  /// Prints error message to stderr with newline
  void errorToStderr(final Object? object) => stderr.write('$object\n');

  /// Exits the program with optional code, showing interactive message if needed
  ///
  /// [code] Exit code (default: 1)
  Never quit([final int code = 1]) {
    if (Platform.environment['INTERACTIVE'] == 'true') {
      print(
        '[gpth ${code != 0 ? 'quitted :(' : 'finished :)'} (code $code) - '
        'press enter to close]',
      );
      stdin.readLineSync();
    }
    exit(code);
  }

  /// Formats a [Duration] as a string: "Xs" if < 1 min, otherwise "Xm Ys".
  String formatDuration(final Duration duration) {
    if (duration.inSeconds < 60) {
      return '${duration.inSeconds}s';
    } else {
      final minutes = duration.inMinutes;
      final seconds = duration.inSeconds % 60;
      return '${minutes}m ${seconds}s';
    }
  }
}

/// Extension to add logging capabilities to any class
mixin LoggerMixin {
  LoggingService? _logger;

  /// Gets or creates a logger instance
  LoggingService get logger => _logger ??= const LoggingService();

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
  void logError(final String message) {
    logger.error(message);
  }

  /// Logs a debug message
  void logDebug(final String message) {
    logger.debug(message);
  }
}
