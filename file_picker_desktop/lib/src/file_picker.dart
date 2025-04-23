import 'file_picker_result.dart';
import 'file_type.dart';

abstract class FilePicker {
  Future<FilePickerResult?> pickFiles({
    required String dialogTitle,
    required FileType type,
    List<String>? allowedExtensions,
    required bool allowMultiple,
    required bool withData,
    required bool withReadStream,
  }) async =>
      throw UnimplementedError('pickFiles() has not been implemented.');

  Future<String?> getDirectoryPath({
    required String dialogTitle,
  }) async =>
      throw UnimplementedError('getDirectoryPath() has not been implemented.');

  Future<String?> saveFile({
    required String dialogTitle,
    required FileType type,
    List<String>? allowedExtensions,
    String? defaultFileName,
  }) async =>
      throw UnimplementedError('saveFile() has not been implemented');
}
