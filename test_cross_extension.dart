import 'dart:io';
import 'package:gpth/domain/services/metadata_matcher_service.dart';
import 'package:path/path.dart' as p;

void main() async {
  print('Testing cross-extension matching for MP4 → HEIC JSON:');
  print('');

  // Create a temporary directory
  final tempDir = Directory.systemTemp.createTempSync('test_cross_extension');

  try {
    // Create test files
    final mp4File = File(p.join(tempDir.path, 'IMG_2367.MP4'));
    await mp4File.writeAsBytes([]);

    final heicJsonFile = File(
      p.join(tempDir.path, 'IMG_2367.HEIC.supplemental-metadata.json'),
    );
    await heicJsonFile.writeAsString('{"test": "data"}');

    print('Created files:');
    print('- Media: ${p.basename(mp4File.path)}');
    print('- JSON:  ${p.basename(heicJsonFile.path)}');
    print('');

    // Test the matching with tryhard=true (includes aggressive strategies)
    final result = await JsonFileMatcher.findJsonForFile(
      mp4File,
      tryhard: true,
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
