/*
This code has been copied from: https://github.com/miguelpruivo/flutter_file_picker

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

import 'platform_file.dart';

class FilePickerResult {
  const FilePickerResult(this.files);

  /// Picked files.
  final List<PlatformFile> files;

  /// Whether this pick contains only a single resource.
  bool get isSinglePick => files.length == 1;

  /// The count of picked files.
  int get count => files.length;

  /// A `List<String>` containing all paths from picked files.
  ///
  /// This may or not be available and will typically reference cached copies of
  /// original files (which can be accessed through its URI property).
  List<String?> get paths => files.map((file) => file.path).toList();

  /// A `List<String>` containing all names from picked files with their extensions.
  List<String?> get names => files.map((file) => file.name).toList();
}
