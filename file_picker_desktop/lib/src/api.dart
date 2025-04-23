/*
This code has been copied with minor modifications from:
https://github.com/miguelpruivo/flutter_file_picker

MIT License

Copyright (c) 2018 Miguel Ruivo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NON INFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

import 'package:file_picker_desktop/src/file_picker.dart';

import 'file_picker_result.dart';
import 'file_picker_utils.dart';
import 'file_type.dart';

/// Opens a dialog to let the user select a directory and returns its absolute
/// path.
///
/// [dialogTitle] is displayed at the top of the file selection dialog. This
/// string can be used to specify instructions to the user.
///
/// Returns a [Future<String>] which resolves to the absolute path of the
/// directory, if the user selected a directory. Returns [null] if aborted.
///
/// Throws [UnimplementedError] for unsupported platforms. May throw an
/// [Exception] if the executable for opening the directory picker dialog could
/// not be found or the result of the dialog couldn't be interpreted.
Future<String?> getDirectoryPath({
  String dialogTitle = 'Please select a directory:',
}) {
  FilePicker? filePicker = instantiateFilePickerForCurrentPlatform();
  return filePicker.getDirectoryPath(dialogTitle: dialogTitle);
}

/// Opens a dialog to let the user select one or multiple files and retrieves
/// the file(s) from the underlying platform.
///
/// [dialogTitle] is displayed at the top of the file selection dialog. This
/// string can be used to specify instructions to the user.
///
/// The file type filter [type] defaults to [FileType.any]. Optionally,
/// [allowedExtensions] might be provided as a list of strings which represent
/// the allowed file extension (e.g. `['pdf', 'svg', 'jpg']`).
/// [allowMultiple], which defaults to [false], defines whether the user may
/// pick more than one file.
///
/// If [withData] is set, picked files will have its byte data immediately
/// available on memory as `Uint8List` which can be useful if you are picking it
/// for server upload or similar. However, have in mind that enabling this may
/// result in out of memory issues if you pick multiple huge files. Use
/// [withReadStream] instead. Defaults to `false`.
///
/// If [withReadStream] is set, picked files will have its byte data available
/// as a [Stream<List<int>>] which can be useful for uploading and processing
/// large files. Defaults to `false`.
///
/// The result is wrapped in a [FilePickerResult] which contains helper getters
/// with useful information regarding the picked [List<PlatformFile>].
/// Returns [null] if aborted.
///
/// Throws [UnimplementedError] on unsupported platforms. Throws [ArgumentError]
/// if the given combination of arguments is invalid. May throw an [Exception]
/// if the executable for opening the file picker dialog could not be found or
/// the result of the dialog couldn't be interpreted.
Future<FilePickerResult?> pickFiles({
  String dialogTitle = 'Please select file(s):',
  FileType type = FileType.any,
  List<String>? allowedExtensions,
  bool allowMultiple = false,
  bool withData = false,
  bool withReadStream = false,
}) {
  validateFileFilter(type, allowedExtensions);

  FilePicker? filePicker = instantiateFilePickerForCurrentPlatform();
  return filePicker.pickFiles(
    dialogTitle: dialogTitle,
    type: type,
    allowedExtensions: allowedExtensions,
    allowMultiple: allowMultiple,
    withData: withData,
    withReadStream: withReadStream,
  );
}

/// Opens a save file dialog which lets the user select a location and a file
/// name to save a file.
///
/// [defaultFileName] can be set to a non-empty string to provide a default file
/// name.
///
/// The file type filter [type] defaults to [FileType.any]. Optionally,
/// [allowedExtensions] might be provided as a list of strings which represent
/// the allowed file extension (e.g. `['pdf', 'svg', 'jpg']`). [type] and
/// [allowedExtensions] are just a proposal to the user as the save file dialog
/// does not enforce these restrictions.
///
/// Returns a [Future<String?>] which resolves to the absolute path of the
/// selected file, if the user selected a file. Returns [null] if aborted.
/// Attention: this function does not actually save a file. It only opens the
/// dialog to let the user choose a location and file name. This function only
/// returns the **path** to this (non-existing) file.
///
/// Throws [UnimplementedError] on unsupported platforms. Throws [ArgumentError]
/// if the given combination of arguments is invalid. May throw an [Exception]
/// if the executable for opening the save file dialog could not be found or the
/// result of the dialog couldn't be interpreted.
Future<String?> saveFile({
  String dialogTitle = 'Please select the file destination:',
  FileType type = FileType.any,
  List<String>? allowedExtensions,
  String? defaultFileName,
}) {
  validateFileFilter(type, allowedExtensions);

  FilePicker? filePicker = instantiateFilePickerForCurrentPlatform();
  return filePicker.saveFile(
    allowedExtensions: allowedExtensions,
    dialogTitle: dialogTitle,
    defaultFileName: defaultFileName,
    type: type,
  );
}
