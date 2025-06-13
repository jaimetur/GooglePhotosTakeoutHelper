void main() {
  // Test what 1640960007 seconds since epoch converts to
  const timestamp = 1640960007;
  final dateTime = DateTime.fromMillisecondsSinceEpoch(
    timestamp * 1000,
    isUtc: true,
  );
  print('UTC: $dateTime');

  final dateTimeLocal = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  print('Local: $dateTimeLocal');
}
