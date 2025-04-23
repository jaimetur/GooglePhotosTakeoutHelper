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

import 'dart:async';
import 'dart:typed_data';

class PlatformFile {
  const PlatformFile({
    required this.name,
    this.size,
    this.path,
    this.bytes,
    this.readStream,
  });

  /// The absolute path for a cached copy of this file. It can be used to create a
  /// file instance with a descriptor for the given path.
  /// ```
  /// final File myFile = File(platformFile.path);
  /// ```
  final String? path;

  /// File name including its extension.
  final String name;

  /// Byte data for this file. Particurlarly useful if you want to manipulate its data
  /// or easily upload to somewhere else.
  final Uint8List? bytes;

  /// File content as stream
  final Stream<List<int>>? readStream;

  /// The file size in bytes.
  final int? size;

  /// File extension for this file.
  String? get extension => name.split('.').last;
}
