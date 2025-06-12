import 'dart:io';
import 'package:gpth/domain/services/metadata_matcher_service.dart';
import 'package:path/path.dart' as p;

void main() async {
  print('Testing numbered JSON file matching for extension fixing scenario:');
  print('');

  // Create a temporary directory
  final tempDir = Directory.systemTemp.createTempSync('test_json_matching');

  try {
    // Create test files
    final mediaFile = File(p.join(tempDir.path, 'IMG_2367(1).HEIC.jpg'));
    await mediaFile.writeAsBytes([]);

    final jsonFile = File(
      p.join(tempDir.path, 'IMG_2367.HEIC.supplemental-metadata(1).json'),
    );
    await jsonFile.writeAsString('{"test": "data"}');

    print('Created files:');
    print('- Media: ${p.basename(mediaFile.path)}');
    print('- JSON:  ${p.basename(jsonFile.path)}');
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
