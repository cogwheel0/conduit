import 'package:checks/checks.dart';
import 'package:conduit_core/network/upload_timeout.dart';
import 'package:test/test.dart';

void main() {
  test('gives a small upload five minutes', () {
    check(uploadTimeoutForBytes(0)).equals(const Duration(minutes: 5));
    check(
      uploadTimeoutForBytes(1024 * 1024),
    ).equals(const Duration(minutes: 5));
  });

  test('gives a large upload its time at 128 KiB/s plus two minutes', () {
    check(
      uploadTimeoutForBytes(128 * 1024 * 600),
    ).equals(const Duration(seconds: 720));
  });
}
