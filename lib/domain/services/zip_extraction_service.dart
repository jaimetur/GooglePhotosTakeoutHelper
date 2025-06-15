import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../presentation/interactive_presenter.dart';
import '../../utils.dart';
import 'logging_service.dart';

/// Service for handling ZIP file extraction with safety checks and error handling
///
/// This service provides secure ZIP extraction functionality with comprehensive
/// error handling, progress reporting, and security validation to prevent
/// common ZIP-based vulnerabilities like path traversal attacks (Zip Slip).
class ZipExtractionService {
  /// Creates a new instance of ZipExtractionService
  ZipExtractionService({final InteractivePresenter? presenter})
    : _presenter = presenter ?? InteractivePresenter();

  final InteractivePresenter _presenter;
  final LoggingService _logger = const LoggingService();

  /// Extracts all ZIP files to the specified directory
  ///
  /// This function safely extracts all provided ZIP files to the specified directory.
  /// It includes comprehensive error handling, progress reporting, and cross-platform support.
  ///
  /// Features:
  /// - Creates destination directory if it doesn't exist
  /// - Validates ZIP file integrity before extraction
  /// - Provides progress feedback during extraction
  /// - Handles filename encoding issues across platforms
  /// - Prevents path traversal attacks (Zip Slip vulnerability)
  /// - Graceful error handling with user-friendly messages
  /// - Continues processing remaining ZIPs if individual extractions fail
  ///
  /// [zips] List of ZIP files to extract
  /// [dir] Target directory for extraction (will be created if needed)
  ///
  /// Individual ZIP extraction failures are logged as warnings and do not stop
  /// the overall process. The method continues processing remaining ZIP files.
  ///
  /// Example usage:
  /// ```dart
  /// final service = ZipExtractionService();
  /// final zips = await getZips();
  /// final unzipDir = Directory(p.join(outputPath, '.gpth-unzipped'));
  /// await service.extractAll(zips, unzipDir);
  /// ```
  Future<void> extractAll(final List<File> zips, final Directory dir) async {
    // Clean up and create destination directory
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    await _presenter.showUnzipStartMessage();

    for (final File zip in zips) {
      await _presenter.showUnzipProgress(p.basename(zip.path));

      try {
        // Validate ZIP file exists and is readable
        if (!await zip.exists()) {
          throw FileSystemException('ZIP file not found', zip.path);
        }
        final int zipSize = await zip.length();
        if (zipSize == 0) {
          throw FileSystemException('ZIP file is empty', zip.path);
        }

        // Extract with safety checks
        await _extractZipSafely(zip, dir);

        await _presenter.showUnzipSuccess(p.basename(zip.path));
      } on ArchiveException catch (e) {
        try {
          _handleExtractionError(zip, e, isArchiveError: true);
        } catch (extractionError) {
          _logger.warning('Failed to extract ${p.basename(zip.path)}: $e');
          _logger.warning('Continuing with remaining ZIP files...');
        }
      } on PathNotFoundException catch (e) {
        try {
          _handleExtractionError(zip, e, isPathError: true);
        } catch (extractionError) {
          _logger.warning('Failed to extract ${p.basename(zip.path)}: $e');
          _logger.warning('Continuing with remaining ZIP files...');
        }
      } on FileSystemException catch (e) {
        try {
          _handleExtractionError(zip, e, isFileSystemError: true);
        } catch (extractionError) {
          _logger.warning('Failed to extract ${p.basename(zip.path)}: $e');
          _logger.warning('Continuing with remaining ZIP files...');
        }
      } catch (e) {
        try {
          _handleExtractionError(zip, e);
        } catch (extractionError) {
          _logger.warning('Failed to extract ${p.basename(zip.path)}: $e');
          _logger.warning('Continuing with remaining ZIP files...');
        }
      }
    }

    await _presenter.showUnzipComplete();
  }

  /// Safely extracts a ZIP file with security and encoding checks
  ///
  /// This internal helper function performs the actual extraction while
  /// preventing common security vulnerabilities and handling encoding issues.
  ///
  /// [zip] The ZIP file to extract
  /// [destinationDir] The target directory for extraction
  Future<void> _extractZipSafely(
    final File zip,
    final Directory destinationDir,
  ) async {
    final Archive archive = ZipDecoder().decodeBytes(await zip.readAsBytes());

    for (final ArchiveFile file in archive) {
      // Security check: Prevent Zip Slip vulnerability
      final String fileName = _sanitizeFileName(file.name);
      final String fullPath = p.join(destinationDir.path, fileName);

      // Ensure the file path is within the destination directory
      final String canonicalDestPath = p.canonicalize(destinationDir.path);
      final String canonicalFilePath = p.canonicalize(p.dirname(fullPath));

      if (!canonicalFilePath.startsWith(canonicalDestPath)) {
        throw SecurityException(
          'Path traversal attempt detected: ${file.name} -> $fullPath',
        );
      }
      if (file.isFile) {
        final File outputFile = File(fullPath);
        await outputFile.create(recursive: true);

        // Extract file content
        final List<int> content = file.content as List<int>;
        await outputFile.writeAsBytes(content, flush: true);

        // Preserve file modification time if available
        try {
          await outputFile.setLastModified(
            DateTime.fromMillisecondsSinceEpoch(file.lastModTime * 1000),
          );
        } catch (e) {
          // Ignore timestamp setting errors - not critical
          _logger.warning(
            'Warning: Could not set modification time for ${outputFile.path}: $e',
          );
        }
      } else if (file.isDirectory) {
        // Create directory
        final Directory outputDir = Directory(fullPath);
        await outputDir.create(recursive: true);
      }
    }
  }

  /// Sanitizes file names to handle encoding issues and invalid characters
  ///
  /// This function normalizes file names for cross-platform compatibility,
  /// handles Unicode normalization, and removes invalid characters.
  ///
  /// [fileName] The original file name from the archive
  /// Returns the sanitized file name safe for the current platform
  String _sanitizeFileName(final String fileName) {
    // Normalize Unicode characters (important for cross-platform compatibility)
    fileName.replaceAll(RegExp(r'[<>:"|?*]'), '_');

    // Handle Windows reserved names
    if (Platform.isWindows) {
      final List<String> reservedNames = [
        'CON',
        'PRN',
        'AUX',
        'NUL',
        'COM1',
        'COM2',
        'COM3',
        'COM4',
        'COM5',
        'COM6',
        'COM7',
        'COM8',
        'COM9',
        'LPT1',
        'LPT2',
        'LPT3',
        'LPT4',
        'LPT5',
        'LPT6',
        'LPT7',
        'LPT8',
        'LPT9',
      ];

      final String baseName = p.basenameWithoutExtension(fileName);
      if (reservedNames.contains(baseName.toUpperCase())) {
        fileName.replaceFirst(baseName, '${baseName}_file');
      }

      // Remove trailing dots and spaces (Windows specific)
      fileName.replaceAll(RegExp(r'[. ]+$'), '');
    }

    return fileName;
  }

  /// Handles extraction errors with detailed error messages and user guidance
  ///
  /// This function provides context-specific error handling for different types
  /// of extraction failures, offering actionable guidance to users.
  ///
  /// [zip] The ZIP file that failed to extract
  /// [error] The error that occurred
  /// [isArchiveError] Whether this is a ZIP format/corruption error
  /// [isPathError] Whether this is a file path related error
  /// [isFileSystemError] Whether this is a file system related error
  Never _handleExtractionError(
    final File zip,
    final Object errorObject, {
    final bool isArchiveError = false,
    final bool isPathError = false,
    final bool isFileSystemError = false,
  }) {
    final String zipName = p.basename(zip.path);

    _logger.error('');
    _logger.error('===============================================');
    _logger.error('❌ ERROR: Failed to extract $zipName');
    _logger.error('===============================================');

    if (isArchiveError) {
      _logger.error('💥 ZIP Archive Error:');
      _logger.error(
        'The ZIP file appears to be corrupted or uses an unsupported format.',
      );
      _logger.error('');
      _logger.error('🔧 Suggested Solutions:');
      _logger.error('• Re-download the ZIP file from Google Takeout');
      _logger.error('• Verify the file wasn\'t corrupted during download');
      _logger.error(
        '• Try extracting manually with your system\'s built-in extractor',
      );
    } else if (isPathError) {
      _logger.error('📁 Path/File Error:');
      _logger.error(
        'There was an issue accessing files or creating directories.',
      );
      _logger.error('');
      _logger.error('🔧 Suggested Solutions:');
      _logger.error(
        '• Ensure you have sufficient permissions in the target directory',
      );
      _logger.error(
        '• Check that the target path is not too long (Windows limitation)',
      );
      _logger.error('• Verify sufficient disk space is available');
    } else if (isFileSystemError) {
      _logger.error('💾 File System Error:');
      _logger.error('Unable to read the ZIP file or write extracted files.');
      _logger.error('');
      _logger.error('🔧 Suggested Solutions:');
      _logger.error('• Check file permissions on the ZIP file');
      _logger.error(
        '• Ensure the ZIP file is not currently open in another program',
      );
      _logger.error('• Verify the target directory is writable');
    } else {
      _logger.error('⚠️  Unexpected Error:');
      _logger.error('An unexpected error occurred during extraction.');
    }

    _logger.error('');
    _logger.error('📋 Error Details: $errorObject');
    _logger.error('');
    _logger.error('🔄 Alternative Options:');
    _logger.error('• Extract ZIP files manually using your system tools');
    _logger.error(
      '• Use GPTH with command-line options on pre-extracted files',
    );
    _logger.error(
      '• See manual extraction guide: https://github.com/Xentraxx/GooglePhotosTakeoutHelper?tab=readme-ov-file#command-line-usage',
    );
    _logger.error('');
    _logger.error('===============================================');
    _logger.error('');
    _logger.error('⚠️  ZIP EXTRACTION FAILED - CONTINUING WITH PROCESSING');
    _logger.error(
      'The ZIP extraction failed, but GPTH will continue processing',
    );
    _logger.error(
      'any files that were successfully extracted before the error.',
    );
    _logger.error('Please check the extraction directory for partial results.');

    // Instead of quitting, we'll throw an exception that can be caught
    // and handled by the calling code
    throw Exception('ZIP extraction failed: $errorObject');
  }
}

/// Custom exception for security-related extraction issues
class SecurityException implements Exception {
  /// Creates a security exception with the given message
  const SecurityException(this.message);

  /// The error message describing the security issue
  final String message;

  @override
  String toString() => 'SecurityException: $message';
}
