// ignore_for_file: file_names

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'utils.dart';

ExiftoolInterface? exiftool;

/// Initializes the global ExiftoolInterface instance
///
/// Attempts to find and initialize exiftool, setting the global
/// [exifToolInstalled] flag accordingly. Also starts the persistent
/// process for improved performance.
///
/// Returns true if exiftool was found and initialized successfully
Future<bool> initExiftool() async {
  exiftool = await ExiftoolInterface.find();
  if (exiftool != null) {
    exifToolInstalled = true;

    // Start persistent process for better performance
    await exiftool!.startPersistentProcess();

    return true;
  } else {
    return false;
  }
}

/// Cleanup function to stop the persistent ExifTool process
/// Should be called when the application is shutting down
Future<void> cleanupExiftool() async {
  await exiftool?.dispose();
}

/// Cross-platform interface for exiftool (read/write EXIF data)
///
/// Supports both traditional process-per-operation mode and persistent
/// stay-open mode for improved performance.
class ExiftoolInterface {
  ExiftoolInterface._(this.exiftoolPath);

  final String exiftoolPath;
  // Persistent process management
  Process? _persistentProcess;
  StreamSubscription<String>? _outputSubscription;
  StreamSubscription<String>? _errorSubscription;
  final Map<int, Completer<String>> _pendingCommands = {};
  final Map<int, List<String>> _commandOutputs = {};
  final Map<int, List<String>> _commandErrors = {};
  int _commandCounter = 0;
  bool _isStarting = false;

  final StreamController<String> _inputController = StreamController<String>();

  /// Attempts to find exiftool in PATH and returns an instance, or null if not found
  static Future<ExiftoolInterface?> find() async {
    final String exe = Platform.isWindows ? 'exiftool.exe' : 'exiftool';

    // Try finding exiftool in system PATH
    final String? path = await _which(exe);
    if (path != null) {
      return ExiftoolInterface._(path);
    }

    // Get the directory where the current executable (e.g., gpth.exe) resides
    String? binDir;
    try {
      binDir = File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      binDir = null;
    }

    // Try to also get the location of the main script (may not be reliable in compiled mode)
    // ignore: unnecessary_nullable_for_final_variable_declarations
    final String? scriptPath = Platform.script.toFilePath();
    final String? scriptDir = scriptPath != null
        ? File(scriptPath).parent.path
        : null;

    // Collect possible directories where exiftool might be located
    final List<String?> candidateDirs = [
      binDir, // Same directory as gpth.exe
      scriptDir, // Same directory as main.dart or main script
      p.join(
        binDir ?? '',
        'exif_tool',
      ), // subfolder "exif_tool" under executable directory
      p.join(
        scriptDir ?? '',
        'exif_tool',
      ), // subfolder "exif_tool" under script directory
      Directory.current.path, // Current working directory
      p.join(
        Directory.current.path,
        'exif_tool',
      ), // exif_tool under current working directory
      p.dirname(scriptDir ?? ''), // One level above script directory (fallback)
    ];

    // Try each candidate directory and return if exiftool is found
    for (final dir in candidateDirs) {
      if (dir == null) continue;
      final exiftoolFile = File(p.join(dir, exe));
      if (await exiftoolFile.exists()) {
        return ExiftoolInterface._(exiftoolFile.path);
      }
    }

    // Not found anywhere
    return null;
  }

  /// Reads all EXIF data from [file] and returns as a Map
  Future<Map<String, dynamic>> readExif(final File file) async {
    // Check if file exists before trying to read it
    if (!await file.exists()) {
      throw FileSystemException('File not found', file.path);
    }

    final args = ['-j', '-n'];

    // On Windows, explicitly set UTF-8 encoding for Unicode character support
    if (Platform.isWindows) {
      args.addAll(['-charset', 'filename=UTF8']);
      args.addAll(['-charset', 'exif=UTF8']);
    }

    args.add(file.path);

    final result = await Process.run(exiftoolPath, args);

    if (result.exitCode != 0) {
      log(
        'exiftool returned a non 0 code for reading ${file.path} with error: ${result.stderr}',
        level: 'error',
      );
    }
    try {
      final List<dynamic> jsonList = jsonDecode(result.stdout);
      if (jsonList.isEmpty) return {};
      final map = Map<String, dynamic>.from(jsonList.first);
      map.remove('SourceFile');
      return map;
    } on FormatException catch (_) {
      // this is when json is bad
      return {};
    } on FileSystemException catch (_) {
      // this happens for issue #143
      // "Failed to decode data using encoding 'utf-8'"
      // maybe this will self-fix when dart itself support more encodings
      return {};
    } on NoSuchMethodError catch (_) {
      // this is when tags like photoTakenTime aren't there
      return {};
    }
  }

  /// Reads only the specified EXIF tags from [file] and returns as a Map
  Future<Map<String, dynamic>> readExifBatch(
    final File file,
    final List<String> tags,
  ) async {
    final String filepath = file.path;

    // Check if file exists before trying to read it
    if (!await file.exists()) {
      throw FileSystemException('File not found', file.path);
    }

    if (tags.isEmpty) {
      return <String, dynamic>{};
    }

    // Try persistent process first, fall back to traditional method
    try {
      final args = <String>[];

      // On Windows, explicitly set UTF-8 encoding for Unicode character support
      if (Platform.isWindows) {
        args.addAll(['-charset', 'filename=UTF8']);
        args.addAll(['-charset', 'exif=UTF8']);
      }

      args.addAll(tags.map((final tag) => '-$tag'));
      args.add(filepath);

      final result = await _executePersistentCommand(args);

      if (result.trim().isEmpty) {
        return {};
      }

      final List<dynamic> jsonList = jsonDecode(result);
      if (jsonList.isEmpty) return {};
      final map = Map<String, dynamic>.from(jsonList.first);
      map.remove('SourceFile');
      return map;
    } catch (e) {
      if (isVerbose) {
        print(
          '[ExifTool] Persistent process failed for ${file.path}, falling back: $e',
        );
      }

      // Fall back to traditional method
      final args = <String>['-j', '-n'];

      // On Windows, explicitly set UTF-8 encoding for Unicode character support
      if (Platform.isWindows) {
        args.addAll(['-charset', 'filename=UTF8']);
        args.addAll(['-charset', 'exif=UTF8']);
      }

      args.addAll(tags.map((final tag) => '-$tag'));
      args.add(filepath);

      final result = await Process.run(exiftoolPath, args);

      if (result.exitCode != 0) {
        log(
          'exiftool returned a non 0 code for reading ${file.path} with error: ${result.stderr}',
          level: 'error',
        );
      }
      try {
        final List<dynamic> jsonList = jsonDecode(result.stdout);
        if (jsonList.isEmpty) return {};
        final map = Map<String, dynamic>.from(jsonList.first);
        map.remove('SourceFile');
        return map;
      } on FormatException catch (_) {
        // this is when json is bad
        return {};
      } on FileSystemException catch (_) {
        // this happens for issue #143
        // "Failed to decode data using encoding 'utf-8'"
        // maybe this will self-fix when dart itself support more encodings
        return {};
      } on NoSuchMethodError catch (_) {
        // this is when tags like photoTakenTime aren't there
        return {};
      }
    }
  }

  /// Writes multiple EXIF tags to [file]. [tags] is a map of tag name to value.
  Future<bool> writeExifBatch(
    final File file,
    final Map<String, String> tags,
  ) async {
    final String filepath = file.path;

    // Check if file exists before trying to write to it
    if (!await file.exists()) {
      throw FileSystemException('File not found', file.path);
    }

    try {
      final args = <String>['-overwrite_original'];

      // On Windows, explicitly set UTF-8 encoding for Unicode character support
      if (Platform.isWindows) {
        args.addAll(['-charset', 'filename=UTF8']);
        args.addAll(['-charset', 'exif=UTF8']);
      }

      tags.forEach((final tag, final value) => args.add('-$tag=$value'));
      args.add(filepath);

      await _executePersistentCommand(args);
      return true;
    } catch (e) {
      if (isVerbose) {
        print('[ExifTool] Write operation failed for ${file.path}: $e');
      }

      // Log the error in the same format as before for consistency
      log(
        '[Step 5/8] Writing exif to file ${file.path} failed.'
        '\n${e.toString().replaceAll("Exception: ExifTool error: ", "").replaceAll(" - ${file.path.replaceAll('\\', '/')}", "")}',
        level: 'error',
        forcePrint: true,
      );
      return false;
    }
  }

  /// Starts the persistent ExifTool process in stay-open mode
  ///
  /// This eliminates process creation overhead for subsequent operations.
  /// The process will stay running and accept commands via stdin.
  Future<bool> startPersistentProcess() async {
    if (_persistentProcess != null || _isStarting) {
      return true; // Already started or starting
    }

    _isStarting = true;

    try {
      // Start ExifTool in stay-open mode
      _persistentProcess = await Process.start(exiftoolPath, [
        '-stay_open',
        'True',
        '-@',
        '-',
        '-common_args',
        '-j',
        '-n',
      ]);

      // Set up output stream processing
      _outputSubscription = _persistentProcess!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleOutput);

      // Set up error stream monitoring
      _errorSubscription = _persistentProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleError);

      // Set up input stream
      _inputController.stream.listen((final command) {
        _persistentProcess!.stdin.writeln(command);
      });

      log(
        '[ExifTool] Started persistent process (PID: ${_persistentProcess!.pid})',
      );

      _isStarting = false;
      return true;
    } catch (e) {
      if (isVerbose) {
        print('[ExifTool] Failed to start persistent process: $e');
      }
      _isStarting = false;
      return false;
    }
  }

  /// Stops the persistent ExifTool process
  Future<void> stopPersistentProcess() async {
    if (_persistentProcess == null) return;

    try {
      // Send exit command
      _inputController.add('-stay_open');
      _inputController.add('False');

      // Clean up subscriptions
      await _outputSubscription?.cancel();
      await _errorSubscription?.cancel();
      _outputSubscription = null;
      _errorSubscription = null;

      // Wait for process to exit or kill it
      await _persistentProcess!.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          _persistentProcess!.kill();
          return -1;
        },
      );

      if (isVerbose) {
        print('[ExifTool] Stopped persistent process');
      }
    } catch (e) {
      if (isVerbose) {
        print('[ExifTool] Error stopping persistent process: $e');
      }
      _persistentProcess?.kill();
    } finally {
      _persistentProcess = null;
      _pendingCommands.clear();
      _commandOutputs.clear();
      _commandErrors.clear();
      _commandCounter = 0;
    }
  }

  /// Handles output from the persistent ExifTool process
  void _handleOutput(final String line) {
    if (line.trim().isEmpty) return;

    // Look for command completion markers
    if (line.startsWith('{ready}')) {
      // ExifTool is ready for next command
      return;
    }

    // Try to find the command ID from the line
    // ExifTool outputs results followed by {ready<ID>}
    final readyMatch = RegExp(r'\{ready(\d+)\}').firstMatch(line);
    if (readyMatch != null) {
      final commandId = int.parse(readyMatch.group(1)!);
      final completer = _pendingCommands.remove(commandId);

      if (completer != null) {
        // Get accumulated output and errors for this command
        final outputs = _commandOutputs.remove(commandId) ?? [];
        final errors = _commandErrors.remove(commandId) ?? [];
        // Check if there were any errors (but not warnings)
        final hasErrors = errors.any(
          (final error) =>
              error.contains('Error:') ||
              error.contains("weren't updated due to errors") ||
              error.contains('File not found') ||
              (error.contains('not yet supported') &&
                  !error.startsWith('Warning:')),
        );

        if (hasErrors) {
          // Complete with error information
          completer.completeError(
            Exception('ExifTool error: ${errors.join('; ')}'),
          );
        } else {
          // Complete successfully with output (warnings are okay)
          completer.complete(outputs.join('\n'));
        }
      }
      return;
    }

    // Accumulate output for the current command
    // Find which command this output belongs to (use the latest pending command)
    if (_pendingCommands.isNotEmpty) {
      final latestCommandId = _pendingCommands.keys.reduce(
        (final a, final b) => a > b ? a : b,
      );
      _commandOutputs.putIfAbsent(latestCommandId, () => []).add(line);
    }
  }

  /// Handles error output from the persistent ExifTool process
  void _handleError(final String line) {
    if (line.trim().isEmpty) return;

    if (isVerbose) {
      print('[ExifTool Error] $line');
    }

    // Accumulate errors for the current command
    if (_pendingCommands.isNotEmpty) {
      final latestCommandId = _pendingCommands.keys.reduce(
        (final a, final b) => a > b ? a : b,
      );
      _commandErrors.putIfAbsent(latestCommandId, () => []).add(line);
    }
  }

  /// Executes a command using the persistent ExifTool process
  Future<String> _executePersistentCommand(final List<String> args) async {
    if (_persistentProcess == null && !await startPersistentProcess()) {
      throw Exception('Failed to start persistent ExifTool process');
    }

    final commandId = ++_commandCounter;
    final completer = Completer<String>();
    _pendingCommands[commandId] = completer;
    try {
      // Send command arguments
      args.forEach(_inputController.add);

      // Send execute command with ID
      _inputController.add('-execute$commandId');

      // Wait for result with timeout
      final result = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pendingCommands.remove(commandId);
          throw TimeoutException(
            'ExifTool command timed out',
            const Duration(seconds: 30),
          );
        },
      );

      return result;
    } catch (e) {
      _pendingCommands.remove(commandId);
      rethrow;
    }
  }

  /// Reads EXIF data using persistent process with fallback to traditional method
  Future<Map<String, dynamic>> readExifPersistent(final File file) async {
    try {
      // Try persistent process first
      final args = <String>[];

      // On Windows, set UTF-8 encoding
      if (Platform.isWindows) {
        args.addAll(['-charset', 'filename=UTF8', '-charset', 'exif=UTF8']);
      }

      args.add(file.path);

      final result = await _executePersistentCommand(args);

      if (result.trim().isEmpty) {
        return {};
      }

      final List<dynamic> jsonList = jsonDecode(result);
      if (jsonList.isEmpty) return {};
      final map = Map<String, dynamic>.from(jsonList.first);
      map.remove('SourceFile');
      return map;
    } catch (e) {
      if (isVerbose) {
        print(
          '[ExifTool] Persistent process failed for ${file.path}, falling back: $e',
        );
      }

      // Fall back to traditional method
      return readExif(file);
    }
  }

  /// Writes EXIF data using persistent process with fallback to traditional method
  Future<bool> writeExifPersistent(
    final File file,
    final Map<String, String> tags,
  ) async {
    try {
      // Try persistent process first
      final args = <String>['-overwrite_original'];

      // On Windows, set UTF-8 encoding
      if (Platform.isWindows) {
        args.addAll(['-charset', 'filename=UTF8', '-charset', 'exif=UTF8']);
      }

      tags.forEach((final tag, final value) => args.add('-$tag=$value'));
      args.add(file.path);

      await _executePersistentCommand(args);
      return true;
    } catch (e) {
      if (isVerbose) {
        print(
          '[ExifTool] Persistent process failed for ${file.path}, falling back: $e',
        );
      }
      // Fall back to traditional method
      return writeExifBatch(file, tags);
    }
  }

  /// Dispose method to clean up resources
  /// Should be called when the ExiftoolInterface is no longer needed
  Future<void> dispose() async {
    await stopPersistentProcess();
    await _inputController.close();
  }
}

/// Cross-platform helper to find an executable in system PATH
///
/// Similar to Unix 'which' or Windows 'where' commands.
///
/// [bin] Executable name to search for
/// Returns full path to executable or null if not found
Future<String?> _which(final String bin) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    bin,
  ]);
  if (result.exitCode != 0) return null;
  final output = result.stdout.toString();
  final lines = output
      .split(RegExp(r'[\r\n]+'))
      .where((final l) => l.trim().isNotEmpty)
      .toList();
  return lines.isEmpty ? null : lines.first.trim();
}
