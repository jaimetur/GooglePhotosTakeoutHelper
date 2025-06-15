/// Interactive workflow tests have been deprecated
///
/// These tests are for the deprecated InteractiveWorkflow class that has been
/// removed in favor of direct access to ConsolidatedInteractiveService.
///
/// MIGRATION GUIDE:
/// Old: InteractiveWorkflow.methodName()
/// New: ServiceContainer.instance.interactiveService.methodName()
///
/// This test file is kept for documentation but all tests are disabled.
library;

import 'package:test/test.dart';

void main() {
  group('InteractiveWorkflow (DEPRECATED)', () {
    test('migration notice', () {
      // This class has been deprecated. Use ServiceContainer.instance.interactiveService directly
      print('InteractiveWorkflow has been deprecated.');
      print('Use ServiceContainer.instance.interactiveService instead.');
      expect(true, isTrue);
    });
  });
}
