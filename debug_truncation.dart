import 'package:gpth/domain/services/metadata_matcher_service.dart';

void main() {
  print('Testing truncation suffix generation:');
  print('');

  const processedName = 'very_long_photo_filename_that_exceeds_limits.jpg';
  print('Processed name: $processedName (${processedName.length} chars)');

  final fullSupplementalPath = '$processedName.supplemental-metadata.json';
  print(
    'Full supplemental path: $fullSupplementalPath (${fullSupplementalPath.length} chars)',
  );
  print('');

  if (fullSupplementalPath.length > 51) {
    print('Truncation would be triggered. Expected truncated suffixes:');

    // This function is private, so I'll need to check if it's accessible or create our own test
    // For now, let's manually calculate what we expect

    // Available space: 51 - processedName.length - 1 (for dot) = 51 - 48 - 1 = 2
    final availableSpace = 51 - processedName.length - 1;
    print('Available space for suffix: $availableSpace chars');

    if (availableSpace >= '.json'.length) {
      print('Possible truncated files:');
      // Would try various truncations of "supplemental-metadata"
      final supplementalPart = 'supplemental-metadata';
      final maxSupplementalLength = availableSpace - '.json'.length;

      if (maxSupplementalLength > 0) {
        print('Max supplemental length: $maxSupplementalLength');
        print('This might not be enough for any meaningful truncation');
      }
    }
  }

  print('');
  print(
    'Test file we created: very_long_photo_filename_that_exceeds_limits.supplemental-meta.json',
  );
  print('This suggests the truncation should be: supplemental-meta (16 chars)');
  print('But our available space calculation shows only 2 chars available!');
}
