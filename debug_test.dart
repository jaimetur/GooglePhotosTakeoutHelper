import 'dart:convert';
import 'dart:io';

import 'package:gpth/domain/services/date_extraction/json_date_extractor.dart';
import 'package:path/path.dart' as p;

void main() async {
  // Create a temporary test JSON file
  final tempDir = Directory.systemTemp.createTempSync();
  final jsonFile = File(p.join(tempDir.path, 'test.json'));

  // Write a JSON file with the same format as Google Photos Takeout
  final jsonContent = jsonEncode({
    'title': 'test.jpg',
    'description': '',
    'imageViews': '1',
    'creationTime': {
      'timestamp': '1702198242',
      'formatted': '10.12.2023, 08:50:42 UTC',
    },
    'photoTakenTime': {
      'timestamp': '1640960007',
      'formatted': '31.12.2021, 14:13:27 UTC',
    },
  });

  await jsonFile.writeAsString(jsonContent);

  print('JSON content:');
  print(jsonContent);
  print('\nTimestamp 1640960007 converts to:');
  print(
    'UTC: ${DateTime.fromMillisecondsSinceEpoch(1640960007 * 1000, isUtc: true)}',
  );
  print('Local: ${DateTime.fromMillisecondsSinceEpoch(1640960007 * 1000)}');

  print('\nFunction result:');
  final result = await jsonDateTimeExtractor(jsonFile);
  print('Result: $result');

  // Clean up
  await tempDir.delete(recursive: true);
}
