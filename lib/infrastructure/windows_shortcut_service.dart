import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import '../domain/services/core/logging_service.dart';

/// Service for creating Windows .lnk shortcut files
///
/// Extracted from utils.dart to isolate Windows-specific shortcut creation
/// logic and provide better testability and maintainability.
class WindowsShortcutService with LoggerMixin {
  /// Creates a new instance of WindowsShortcutService
  WindowsShortcutService();

  /// Cached GUIDs for performance (avoid repeated parsing)
  static const String _clsidShellLinkString =
      '{00021401-0000-0000-C000-000000000046}';
  static const String _iidShellLinkString =
      '{000214F9-0000-0000-C000-000000000046}';
  static const String _iidPersistFileString =
      '{0000010b-0000-0000-C000-000000000046}';

  /// Creates a Windows shortcut (.lnk file) using native Win32 API first,
  /// falling back to PowerShell if needed
  ///
  /// [shortcutPath] Path where the shortcut will be created
  /// [targetPath] Path to the target file/folder
  /// Throws Exception if both native and PowerShell methods fail
  Future<void> createShortcut(
    final String shortcutPath,
    final String targetPath,
  ) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows shortcuts are only supported on Windows');
    }

    // Ensure target path is absolute
    final String absoluteTargetPath = p.isAbsolute(targetPath)
        ? targetPath
        : p.absolute(targetPath);

    // Thread-safe directory creation with retry logic for race conditions
    final Directory parentDir = Directory(p.dirname(shortcutPath));
    await _ensureDirectoryExistsSafe(parentDir);

    // Thread-safe target existence verification with retry
    await _verifyTargetExistsSafe(absoluteTargetPath);

    // Try native Win32 API first
    try {
      await _createShortcutNative(shortcutPath, absoluteTargetPath);
      return;
    } catch (e) {
      logDebug(
        'Native shortcut creation failed, falling back to PowerShell: $e',
      );
    }

    // Fallback to PowerShell
    await _createShortcutPowerShell(shortcutPath, absoluteTargetPath);
  }

  /// Safely ensures a directory exists, handling race conditions
  ///
  /// [directory] The directory to create
  /// Retries up to 3 times with delays to handle concurrent creation
  Future<void> _ensureDirectoryExistsSafe(final Directory directory) async {
    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 50);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        return; // Success
      } catch (e) {
        // Check if directory was created by another thread
        if (await directory.exists()) {
          return; // Another thread created it, we're good
        }

        if (attempt == maxRetries) {
          throw Exception(
            'Failed to create directory after $maxRetries attempts: $e',
          );
        }

        // Wait before retry to reduce contention
        await Future.delayed(retryDelay);
      }
    }
  }

  /// Safely verifies target exists, handling race conditions
  ///
  /// [targetPath] The target file/directory path to verify
  /// Retries up to 3 times with delays to handle file system delays
  Future<void> _verifyTargetExistsSafe(final String targetPath) async {
    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 10);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      if (File(targetPath).existsSync() || Directory(targetPath).existsSync()) {
        return; // Target exists
      }

      if (attempt == maxRetries) {
        throw Exception('Target path does not exist: $targetPath');
      }

      // Small delay to handle file system propagation delays
      await Future.delayed(retryDelay);
    }
  }

  /// Creates a Windows shortcut using native Win32 API
  ///
  /// [shortcutPath] Path where the shortcut will be created
  /// [targetPath] Path to the target file/folder
  /// Throws Exception if Win32 API calls fail
  Future<void> _createShortcutNative(
    final String shortcutPath,
    final String targetPath,
  ) async {
    // Run the synchronous COM operations in a separate isolate to avoid blocking
    await Isolate.run(() => _createShortcutSync(shortcutPath, targetPath));
  }

  /// Synchronous COM shortcut creation (runs in isolate)
  ///
  /// [shortcutPath] Path where the shortcut will be created
  /// [targetPath] Path to the target file/folder
  void _createShortcutSync(final String shortcutPath, final String targetPath) {
    using((final Arena arena) {
      // Initialize COM with optimized threading model
      var hr = _initializeCOMSafe();
      if (FAILED(hr)) {
        throw Exception('Failed to initialize COM: 0x${hr.toRadixString(16)}');
      }

      IShellLink? shellLink;
      IPersistFile? persistFile;

      try {
        // Create the ShellLink COM object using cached GUIDs
        final shellLinkPtr = arena<COMObject>();

        // Use cached GUID constants for better performance
        final clsidShellLink = GUIDFromString(_clsidShellLinkString);
        final iidShellLink = GUIDFromString(_iidShellLinkString);

        hr = CoCreateInstance(
          clsidShellLink,
          nullptr,
          CLSCTX_INPROC_SERVER,
          iidShellLink,
          shellLinkPtr.cast<Pointer<COMObject>>(),
        );

        if (FAILED(hr)) {
          throw Exception(
            'Failed to create IShellLink: 0x${hr.toRadixString(16)}',
          );
        }

        shellLink = IShellLink(shellLinkPtr);

        // Convert strings to UTF16 once and reuse
        final targetPathPtr = targetPath.toNativeUtf16(allocator: arena);

        // Set the target path
        hr = shellLink.setPath(targetPathPtr);
        if (FAILED(hr)) {
          throw Exception(
            'Failed to set target path: 0x${hr.toRadixString(16)}',
          );
        }

        // Set working directory (directory of target)
        final workingDir = p.dirname(targetPath);
        if (workingDir != targetPath) {
          // Only set if different from target
          final workingDirPtr = workingDir.toNativeUtf16(allocator: arena);
          hr = shellLink.setWorkingDirectory(workingDirPtr);
          if (FAILED(hr)) {
            // Non-critical error, continue
            logDebug(
              'Warning: Failed to set working directory: 0x${hr.toRadixString(16)}',
            );
          }
        }

        // Query for IPersistFile interface using cached GUID
        final persistFilePtr = arena<COMObject>();
        final iidPersistFile = GUIDFromString(_iidPersistFileString);

        hr = shellLink.queryInterface(
          iidPersistFile,
          persistFilePtr.cast<Pointer<COMObject>>(),
        );

        if (FAILED(hr)) {
          throw Exception(
            'Failed to get IPersistFile: 0x${hr.toRadixString(16)}',
          );
        }

        persistFile = IPersistFile(persistFilePtr);

        // Save the shortcut with optimized retry logic
        _saveShortcutOptimized(persistFile, shortcutPath, arena);

        logDebug('Successfully created native Windows shortcut: $shortcutPath');
      } catch (e) {
        // Clean exception handling - cleanup happens in finally
        rethrow;
      } finally {
        // Always release COM interfaces to prevent memory leaks
        // Release in reverse order of acquisition for safety
        _safeReleaseCOMInterface(() => persistFile?.release(), 'IPersistFile');
        _safeReleaseCOMInterface(() => shellLink?.release(), 'IShellLink');

        // Always uninitialize COM
        try {
          CoUninitialize();
        } catch (e) {
          logDebug('Warning: Failed to uninitialize COM: $e');
        }
      }
    });
  }

  /// Safely releases a COM interface with error handling
  ///
  /// [releaseFunc] Function that performs the release
  /// [interfaceName] Name of interface for error reporting
  void _safeReleaseCOMInterface(
    final void Function() releaseFunc,
    final String interfaceName,
  ) {
    try {
      releaseFunc();
    } catch (e) {
      logDebug('Warning: Failed to release $interfaceName: $e');
    }
  }

  /// Optimized shortcut saving with minimal retry overhead
  ///
  /// [persistFile] The IPersistFile interface
  /// [shortcutPath] Path where the shortcut will be saved
  /// [arena] Memory arena for string allocation
  void _saveShortcutOptimized(
    final IPersistFile persistFile,
    final String shortcutPath,
    final Arena arena,
  ) {
    // Convert path to UTF16 once
    final shortcutPathPtr = shortcutPath.toNativeUtf16(allocator: arena);

    // First attempt - most shortcuts succeed on first try
    var hr = persistFile.save(shortcutPathPtr, TRUE);
    if (SUCCEEDED(hr)) {
      return; // Success on first try - optimal path
    }

    // Retry logic for edge cases only
    const int maxRetries = 2;
    const int retryDelayMs = 50;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      // Short delay to allow file system to settle
      sleep(const Duration(milliseconds: retryDelayMs));

      hr = persistFile.save(shortcutPathPtr, TRUE);
      if (SUCCEEDED(hr)) {
        return; // Success
      }

      if (attempt == maxRetries) {
        throw Exception(
          'Failed to save shortcut after ${maxRetries + 1} attempts: 0x${hr.toRadixString(16)}',
        );
      }
    }
  }

  /// Safely initializes COM, handling threading issues
  ///
  /// Returns the HRESULT from COM initialization
  int _initializeCOMSafe() {
    // Try apartment-threaded first (most compatible)
    var hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

    // If already initialized with different mode, that's usually OK
    if (hr == RPC_E_CHANGED_MODE) {
      return S_OK;
    }

    // If failed, try multi-threaded as fallback
    if (FAILED(hr)) {
      hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      if (hr == RPC_E_CHANGED_MODE) {
        return S_OK;
      }
    }

    return hr;
  }

  /// Creates a Windows shortcut using PowerShell (fallback method)
  ///
  /// [shortcutPath] Path where the shortcut will be created
  /// [targetPath] Path to the target file/folder
  /// Throws Exception if PowerShell command fails
  Future<void> _createShortcutPowerShell(
    final String shortcutPath,
    final String targetPath,
  ) async {
    // Properly escape paths for PowerShell by wrapping in single quotes and escaping internal single quotes
    final String escapedShortcutPath = shortcutPath.replaceAll("'", "''");
    final String escapedTargetPath = targetPath.replaceAll("'", "''");

    const int maxRetries = 3;
    const Duration retryDelay = Duration(milliseconds: 200);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        final ProcessResult res = await Process.run('powershell.exe', <String>[
          '-ExecutionPolicy',
          'Bypass',
          '-NoLogo',
          '-NonInteractive',
          '-NoProfile',
          '-Command',
          // Use single quotes to properly handle paths with spaces and special characters
          // ignore: no_adjacent_strings_in_list
          '\$ws = New-Object -ComObject WScript.Shell; '
              '\$s = \$ws.CreateShortcut(\'$escapedShortcutPath\'); '
              '\$s.TargetPath = \'$escapedTargetPath\'; '
              '\$s.Save()',
        ]);

        if (res.exitCode == 0) {
          logDebug('Successfully created PowerShell shortcut: $shortcutPath');
          return; // Success
        }

        // Check if shortcut was created despite error code (sometimes happens)
        if (File(shortcutPath).existsSync()) {
          logDebug(
            'PowerShell shortcut created despite error code: $shortcutPath',
          );
          return;
        }

        if (attempt == maxRetries) {
          throw Exception(
            'PowerShell failed to create shortcut after $maxRetries attempts: ${res.stderr}',
          );
        }

        // Log retry attempt
        logDebug(
          'PowerShell shortcut creation attempt $attempt failed, retrying: ${res.stderr}',
        );

        // Wait before retry to reduce contention
        await Future.delayed(retryDelay);
      } catch (e) {
        if (attempt == maxRetries) {
          throw Exception(
            'PowerShell shortcut creation failed after $maxRetries attempts: $e',
          );
        }

        logDebug(
          'PowerShell shortcut creation attempt $attempt threw exception, retrying: $e',
        );
        await Future.delayed(retryDelay);
      }
    }
  }
}
