import 'dart:io';
import 'package:gpth/domain/services/metadata_matcher_service.dart';
import 'package:path/path.dart' as p;

void main() async {
  print('Testing filename truncation logic:');
  print('');

  // Create a temporary directory
  final tempDir = Directory.systemTemp.createTempSync('test_truncation');

  try {
    const longBaseName = 'very_long_photo_filename_that_exceeds_limits';

    // Create test files
    final mediaFile = File(p.join(tempDir.path, '$longBaseName.jpg'));
    await mediaFile.writeAsBytes([]);

    final truncatedJsonFile = File(
      p.join(tempDir.path, '$longBaseName.supplemental-meta.json'),
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
    final fullName = '$longBaseName.jpg.supplemental-metadata.json';
    print('- $fullName (${fullName.length} chars)');
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

      // Let's try with tryhard mode
      final tryhardResult = await JsonFileMatcher.findJsonForFile(
        mediaFile,
        tryhard: true,
      );
      if (tryhardResult != null) {
        print(
          'SUCCESS with tryhard: Found JSON file: ${p.basename(tryhardResult.path)}',
        );
      } else {
        print('FAILED even with tryhard mode');
      }
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
