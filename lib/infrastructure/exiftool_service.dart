import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Infrastructure service for ExifTool external process management
class ExifToolService {
  /// Constructor for dependency injection
  ExifToolService(this.exiftoolPath);

  final String exiftoolPath;

  // Persistent process management
  Process? _persistentProcess;
  StreamSubscription<String>? _outputSubscription;
  StreamSubscription<String>? _errorSubscription;
  final Map<int, Completer<String>> _pendingCommands = {};
  final Map<int, String> _commandOutputs = {};
  final int _commandIdCounter = 0;
  bool _isDisposed = false;

  /// Factory method to find and create ExifTool service
  static Future<ExifToolService?> find() async {
    final isWindows = Platform.isWindows;

    // Common ExifTool executable names
    final exiftoolNames = isWindows
        ? ['exiftool.exe', 'exiftool']
        : ['exiftool'];

    // Check if ExifTool is in PATH
    for (final name in exiftoolNames) {
      try {
        final result = await Process.run(name, ['-ver']);
        if (result.exitCode == 0) {
          return ExifToolService(name);
        }
      } catch (e) {
        // Continue to next option
      }
    }

    // If not found in PATH, check common installation directories
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
      if (await File(path).exists()) {
        try {
          final result = await Process.run(path, ['-ver']);
          if (result.exitCode == 0) {
            return ExifToolService(path);
          }
        } catch (e) {
          // Continue to next option
        }
      }
    }

    return null;
  }

  /// Start persistent ExifTool process for better performance
  Future<void> startPersistentProcess() async {
    if (_persistentProcess != null || _isDisposed) return;

    try {
      _persistentProcess = await Process.start(exiftoolPath, [
        '-stay_open',
        'True',
        '-@',
        '-',
      ]);

      // Set up output handling
      _outputSubscription = _persistentProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleOutput);

      _errorSubscription = _persistentProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleError);
    } catch (e) {
      print('Failed to start ExifTool persistent process: $e');
      _persistentProcess = null;
    }
  }

  /// Handle output from persistent process
  void _handleOutput(final String line) {
    if (line.startsWith('{ready}')) {
      final commandId = _commandIdCounter - 1;
      if (_pendingCommands.containsKey(commandId)) {
        final output = _commandOutputs[commandId] ?? '';
        _pendingCommands[commandId]!.complete(output);
        _pendingCommands.remove(commandId);
        _commandOutputs.remove(commandId);
      }
    } else {
      final currentCommandId = _commandIdCounter - 1;
      if (_pendingCommands.containsKey(currentCommandId)) {
        _commandOutputs[currentCommandId] =
            '${_commandOutputs[currentCommandId] ?? ''}$line\n';
      }
    }
  }

  /// Handle error output from persistent process
  void _handleError(final String line) {
    print('ExifTool error: $line');
  }

  /// Execute ExifTool command
  Future<String> executeCommand(final List<String> args) async =>
      _executeOneShot(args);

  /// Execute ExifTool command as one-shot process
  Future<String> _executeOneShot(final List<String> args) async {
    try {
      final result = await Process.run(exiftoolPath, args);
      if (result.exitCode != 0) {
        print('ExifTool command failed with exit code ${result.exitCode}');
        print('Command: $exiftoolPath ${args.join(' ')}');
        print('Error output: ${result.stderr}');
        throw Exception(
          'ExifTool command failed with exit code ${result.exitCode}: ${result.stderr}',
        );
      }
      return result.stdout.toString();
    } catch (e) {
      print('ExifTool one-shot execution failed: $e');
      rethrow;
    }
  }

  /// Read EXIF data from file
  Future<Map<String, dynamic>> readExifData(final File file) async {
    final args = ['-j', '-n', file.path];
    final output = await executeCommand(args);

    if (output.trim().isEmpty) {
      print('ExifTool returned empty output for file: ${file.path}');
      return {};
    }

    try {
      final List<dynamic> jsonList = jsonDecode(output);
      if (jsonList.isNotEmpty && jsonList[0] is Map<String, dynamic>) {
        final data = Map<String, dynamic>.from(jsonList[0]);

        // Normalize GPS reference values
        if (data.containsKey('GPSLatitudeRef')) {
          final latRef = data['GPSLatitudeRef'];
          if (latRef == 'North') {
            data['GPSLatitudeRef'] = 'N';
          } else if (latRef == 'South') {
            data['GPSLatitudeRef'] = 'S';
          }
        }
        if (data.containsKey('GPSLongitudeRef')) {
          final lngRef = data['GPSLongitudeRef'];
          if (lngRef == 'East') {
            data['GPSLongitudeRef'] = 'E';
          } else if (lngRef == 'West') {
            data['GPSLongitudeRef'] = 'W';
          }
        }

        return data;
      }
      return {};
    } catch (e) {
      print('Failed to parse ExifTool JSON output: $e');
      print('Raw output was: "$output"');
      return {};
    }
  }

  /// Write EXIF data to file
  Future<void> writeExifData(
    final File file,
    final Map<String, dynamic> exifData,
  ) async {
    if (exifData.isEmpty) return;

    final args = <String>['-overwrite_original'];

    // Add each EXIF tag as an argument
    for (final entry in exifData.entries) {
      args.add('-${entry.key}=${entry.value}');
    }

    args.add(file.path);

    try {
      final output = await executeCommand(args);

      if (output.contains('error') ||
          output.contains('Error') ||
          output.contains("weren't updated due to errors")) {
        print('ExifTool may have encountered an error writing to ${file.path}');
        print('Output: $output');
        throw Exception(
          'ExifTool failed to write metadata to ${file.path}: $output',
        );
      }
    } catch (e) {
      // Handle unsupported file formats gracefully - don't throw for these
      if (e.toString().contains('is not yet supported') ||
          e.toString().contains('file format not supported') ||
          e.toString().contains("Can't currently write RIFF AVI files") ||
          e.toString().contains('AVI files')) {
        print(
          'ExifTool does not support writing to this file format: ${file.path}',
        );
        return; // Return normally instead of throwing
      }
      // Re-throw other exceptions (like file not found)
      rethrow;
    }
  }

  /// Dispose of resources and cleanup
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    // Cancel pending commands
    for (final completer in _pendingCommands.values) {
      completer.completeError('ExifTool service disposed');
    }
    _pendingCommands.clear();
    _commandOutputs.clear();

    // Cancel subscriptions
    await _outputSubscription?.cancel();
    await _errorSubscription?.cancel();

    // Cleanup persistent process
    if (_persistentProcess != null) {
      try {
        _persistentProcess!.stdin.write('-stay_open\nFalse\n');
        await _persistentProcess!.stdin.flush();
        await _persistentProcess!.stdin.close();

        final exitCode = await _persistentProcess!.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            _persistentProcess!.kill();
            return -1;
          },
        );

        print('ExifTool process exited with code $exitCode');
      } catch (e) {
        print('Error disposing ExifTool process: $e');
        _persistentProcess!.kill();
      } finally {
        _persistentProcess = null;
      }
    }
  }
}
