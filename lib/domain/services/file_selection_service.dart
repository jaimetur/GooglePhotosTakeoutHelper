import 'dart:io';

import 'package:file_picker_desktop/file_picker_desktop.dart';
import 'package:path/path.dart' as p;

import '../../presentation/interactive_presenter.dart';
import '../../utils.dart';

/// Service for handling file and directory selection via UI dialogs
///
/// This service provides a clean interface for file picker operations,
/// validation, and user feedback during file/directory selection.
class FileSelectionService {
  /// Creates a new instance of FileSelectionService
  FileSelectionService({final InteractivePresenter? presenter})
    : _presenter = presenter ?? InteractivePresenter();

  final InteractivePresenter _presenter;

  /// Prompts user to select input directory using file picker dialog
  ///
  /// Returns the selected Directory
  /// Throws if dialog fails or user cancels
  Future<Directory> selectInputDirectory() async {
    await _presenter.promptForInputDirectory();
    _presenter.showPressEnterPrompt();
    final String? dir = await getDirectoryPath(
      dialogTitle: 'Select unzipped folder:',
    );
    await _sleep(1);
    if (dir == null) {
      error('Duh, something went wrong with selecting - try again!');
      return selectOutputDirectory();
    }
    await _presenter.showInputDirectoryConfirmation();
    return Directory(dir);
  }

  /// Prompts user to select output directory using file picker dialog
  ///
  /// Returns the selected Directory
  /// Recursively asks again if dialog fails
  Future<Directory> selectOutputDirectory() async {
    await _presenter.promptForOutputDirectory();
    _presenter.showPressEnterPrompt();
    final String? dir = await getDirectoryPath(
      dialogTitle: 'Select output folder:',
    );
    await _sleep(1);
    if (dir == null) {
      error('Duh, something went wrong with selecting - try again!');
      return selectOutputDirectory();
    }
    await _presenter.showOutputDirectoryConfirmation();
    return Directory(dir);
  }

  /// Asks user for zip files with ui dialogs
  ///
  /// This function prompts the user to select Google Takeout ZIP files through a file picker dialog.
  /// It validates that only ZIP and TGZ files are selected and provides feedback about the total size.
  ///
  /// Returns a List of File objects representing the selected ZIP files.
  ///
  /// Throws [SystemExit] with exit code 69 if dialog fails or 6969 if no files selected.
  ///
  /// Example usage:
  /// ```dart
  /// final service = FileSelectionService();
  /// final zips = await service.selectZipFiles();
  /// print('Selected ${zips.length} ZIP files');
  /// ```
  Future<List<File>> selectZipFiles() async {
    await _presenter.promptForZipFiles();
    _presenter.showPressEnterPrompt();
    final FilePickerResult? files = await pickFiles(
      dialogTitle: 'Select all Takeout zips:',
      type: FileType.custom,
      allowedExtensions: <String>['zip', 'tgz'],
      allowMultiple: true,
    );
    await _sleep(1);
    if (files == null) {
      error('Duh, something went wrong with selecting - try again!');
      quit(69);
    }
    if (files.count == 0) {
      error('No files selected - try again :/');
      quit(6969);
    }
    if (files.count == 1) {
      await _presenter.showSingleZipWarning();
      _presenter.showPressEnterPrompt();
    }
    if (!_validateZipFiles(files.files)) {
      _presenter.showFileList(
        files.files.map((final PlatformFile e) => p.basename(e.path!)).toList(),
      );
      error('Not all files you selected are zips :/ please do this again');
      quit(6969);
    }
    // potentially shows user they selected too little ?
    final totalSize = filesize(
      files.files
          .map((final PlatformFile e) => File(e.path!).statSync().size)
          .reduce((final int a, final int b) => a + b),
    );
    await _presenter.showZipSelectionSuccess(files.count, totalSize);
    return files.files.map((final PlatformFile e) => File(e.path!)).toList();
  }

  /// Validates that all selected files are ZIP or TGZ files
  bool _validateZipFiles(final List<PlatformFile> files) => files.every(
    (final PlatformFile e) =>
        File(e.path!).statSync().type == FileSystemEntityType.file &&
        RegExp(r'\.(zip|tgz)$').hasMatch(e.path!),
  );

  /// Sleep helper for better UX
  Future<void> _sleep(final num seconds) async {
    await Future<void>.delayed(
      Duration(milliseconds: (seconds * 1000).toInt()),
    );
  }
}
