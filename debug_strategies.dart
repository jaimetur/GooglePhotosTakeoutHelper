import 'package:gpth/domain/services/metadata_matcher_service.dart';

void main() {
  print('Testing strategy transformations for extension fixing scenario:');
  print('Input filename: IMG_2367(1).HEIC.jpg');
  print('');
  
  final strategies = JsonFileMatcher.getAllStrategies(includeAggressive: true);
  
  for (int i = 0; i < strategies.length; i++) {
    final strategy = strategies[i];
    final result = strategy.transform('IMG_2367(1).HEIC.jpg');
    print('Strategy ${i + 1}: ${strategy.name}');
    print('  Result: $result');
    print('  Would look for: $result.supplemental-metadata.json');
    print('');
  }
}
