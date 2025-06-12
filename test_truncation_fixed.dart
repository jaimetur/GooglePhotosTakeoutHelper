import 'dart:io';
import 'package:gpth/domain/services/metadata_matcher_service.dart';
import 'package:path/path.dart' as p;

void main() async {
  print('Testing fixed filename truncation logic:');
  print('');

  // Create a temporary directory
  final tempDir = Directory.systemTemp.createTempSync('test_truncation_fixed');

  try {
    const baseName = 'long_filename_for_testing'; // 25 chars

    // Create test files
    final mediaFile = File(p.join(tempDir.path, '$baseName.jpg'));
    await mediaFile.writeAsBytes([]);

    final truncatedJsonFile = File(
      p.join(tempDir.path, '$baseName.jpg.supplemental-meta.json'),
    );
    await truncatedJsonFile.writeAsString('{"test": "data"}');

    print('Created files:');
    print(
      '- Media: ${p.basename(mediaFile.path)} (${p.basename(mediaFile.path).length} chars)',
    );
    print(
      '- JSON:  ${p.basename(truncatedJsonFile.path)} (${p.basename(truncatedJsonFile.path).length} chars)',
    );
    print('');

    print('Expected full supplemental filename would be:');
    final fullName = '$baseName.jpg.supplemental-metadata.json';
    print('- $fullName (${fullName.length} chars)');
    print('This exceeds 51 chars, so truncation should be triggered');
    print('');

    // Calculate what truncation should produce
    final processedName = '$baseName.jpg';
    final availableSpace = 51 - processedName.length - 1; // -1 for dot
    print('Available space for suffix: $availableSpace chars');
    print(
      'supplemental-meta.json is ${('supplemental-meta.json').length} chars',
    );
    print('');

    // Test the matching
    final result = await JsonFileMatcher.findJsonForFile(
      mediaFile,
      tryhard: false,
    );

    if (result != null) {
      print('SUCCESS: Found JSON file: ${p.basename(result.path)}');
    } else {
      print('FAILED: No JSON file found');
    }
  } finally {
    // Clean up
    try {
      await tempDir.delete(recursive: true);
    } catch (e) {
      print('Warning: Could not delete temp directory: $e');
    }
  }
}
