import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Test to demonstrate memory usage improvement
void main() {
  print('Testing memory usage improvement for hash calculation...\n');

  // Create a large test file (10MB)
  final testFile = File('large_test_file.tmp');
  final largeData = Uint8List(10 * 1024 * 1024); // 10MB
  for (int i = 0; i < largeData.length; i++) {
    largeData[i] = i % 256;
  }
  testFile.writeAsBytesSync(largeData);

  try {
    print('File size: ${testFile.lengthSync() / (1024 * 1024)} MB');

    // Test old approach (loads entire file)
    print('\n--- OLD APPROACH (loads entire file) ---');
    final stopwatch1 = Stopwatch()..start();
    final oldHash = sha256.convert(testFile.readAsBytesSync());
    stopwatch1.stop();
    print('Time taken: ${stopwatch1.elapsedMilliseconds}ms');
    print('Hash: ${oldHash.toString().substring(0, 16)}...');

    // Test new approach (streaming)
    print('\n--- NEW APPROACH (streaming) ---');
    final stopwatch2 = Stopwatch()..start();
    final newHash = _calculateHashStreamingSync(testFile);
    stopwatch2.stop();
    print('Time taken: ${stopwatch2.elapsedMilliseconds}ms');
    print('Hash: ${newHash.toString().substring(0, 16)}...');

    // Verify they produce the same result
    print('\n--- VERIFICATION ---');
    print('Hashes match: ${oldHash.toString() == newHash.toString()}');

    print('\nMemory usage improvement:');
    print(
      '- Old: Loads entire ${testFile.lengthSync() / (1024 * 1024)} MB into memory',
    );
    print('- New: Uses 64KB chunks (${64 * 1024 / 1024} MB max memory)');
    print(
      '- Memory reduction: ${((testFile.lengthSync() - (64 * 1024)) / testFile.lengthSync() * 100).toStringAsFixed(1)}%',
    );
  } finally {
    // Clean up
    if (testFile.existsSync()) {
      testFile.deleteSync();
    }
  }
}

/// Replicated streaming hash calculation from the improved Media class
Digest _calculateHashStreamingSync(final File file) {
  final output = _DigestSink();
  final input = sha256.startChunkedConversion(output);

  try {
    const chunkSize = 64 * 1024; // 64KB chunks
    final fileHandle = file.openSync();

    try {
      while (true) {
        final chunk = fileHandle.readSync(chunkSize);
        if (chunk.isEmpty) break;
        input.add(chunk);
      }
    } finally {
      fileHandle.closeSync();
    }

    input.close();
    return output.value;
  } catch (e) {
    rethrow;
  }
}

/// Simple digest collector for streaming hash calculation
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(final Digest data) {
    value = data;
  }

  @override
  void close() {}
}
