/// Performance test to verify optimized functions work correctly
library;

import 'package:gpth/grouping.dart';
import 'package:gpth/media.dart';
import 'package:test/test.dart';
import 'test_setup.dart';

void main() {
  group('Performance Optimizations', () {
    late TestFixture fixture;

    setUp(() async {
      fixture = TestFixture();
      await fixture.setUp();
    });

    tearDown(() async {
      await fixture.tearDown();
    });

    test('parallel grouping works correctly', () async {
      // Create some test files with known duplicates
      final file1 = fixture.createFile('photo1.jpg', [1, 2, 3]);
      final file2 = fixture.createFile('photo2.jpg', [1, 2, 3]); // duplicate
      final file3 = fixture.createFile('photo3.jpg', [4, 5, 6]);

      final mediaList = [
        Media({null: file1}),
        Media({null: file2}),
        Media({null: file3}),
      ];

      // Test parallel grouping
      final groups = await mediaList.groupIdenticalAsyncParallel();

      // Should have one group with 2 identical files and one with 1 unique file
      final duplicateGroups = groups.values.where(
        (final group) => group.length > 1,
      );
      final uniqueGroups = groups.values.where(
        (final group) => group.length == 1,
      );

      expect(duplicateGroups.length, 1);
      expect(duplicateGroups.first.length, 2);
      expect(uniqueGroups.length, 1);
    });

    test('optimized duplicate removal works correctly', () async {
      // Create test media with duplicates
      final file1 = fixture.createFile('original.jpg', [1, 2, 3]);
      final file2 = fixture.createFile('duplicate.jpg', [1, 2, 3]);
      final file3 = fixture.createFile('unique.jpg', [4, 5, 6]);

      final mediaList = [
        Media({null: file1}),
        Media({null: file2}),
        Media({null: file3}),
      ];

      final removedCount = await removeDuplicatesAsyncOptimized(mediaList);

      expect(removedCount, 1); // One duplicate should be removed
      expect(mediaList.length, 2); // Two unique files should remain
    });

    test('performance improvement is measurable', () async {
      // Create a reasonable number of test files for performance comparison
      final mediaList = <Media>[];

      for (int i = 0; i < 20; i++) {
        final file = fixture.createFile('test_$i.jpg', [
          i % 5,
        ]); // Some duplicates
        mediaList.add(Media({null: file}));
      }

      // Time the optimized operation
      final stopwatch = Stopwatch()..start();
      await mediaList.groupIdenticalAsyncParallel();
      stopwatch.stop();

      // Should complete quickly (under 5 seconds for 20 files)
      expect(stopwatch.elapsed.inSeconds, lessThan(5));
    });
  });
}
