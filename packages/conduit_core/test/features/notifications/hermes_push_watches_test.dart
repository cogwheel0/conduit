import 'package:checks/checks.dart';
import 'package:conduit_core/features/notifications/services/hermes_push_watches.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late HermesPushWatches watches;

  setUp(() {
    now = DateTime(2026, 10, 10, 12);
    watches = HermesPushWatches(now: () => now);
  });

  test('a session is watched from its record until its ttl ends', () {
    check(watches.isWatched('conn-1', 's-1')).isFalse();

    watches.record('conn-1', 's-1', ttl: const Duration(minutes: 10));
    check(watches.isWatched('conn-1', 's-1')).isTrue();

    now = now.add(const Duration(minutes: 9, seconds: 59));
    check(watches.isWatched('conn-1', 's-1')).isTrue();
    now = now.add(const Duration(seconds: 1));
    check(watches.isWatched('conn-1', 's-1')).isFalse();
  });

  test('a watch belongs to its connection and session', () {
    watches.record('conn-1', 's-1', ttl: const Duration(minutes: 10));

    check(watches.isWatched('conn-2', 's-1')).isFalse();
    check(watches.isWatched('conn-1', 's-2')).isFalse();
  });

  test('a later watch of the session extends it', () {
    watches.record('conn-1', 's-1', ttl: const Duration(minutes: 10));
    now = now.add(const Duration(minutes: 8));
    watches.record('conn-1', 's-1', ttl: const Duration(minutes: 10));

    now = now.add(const Duration(minutes: 5));
    check(watches.isWatched('conn-1', 's-1')).isTrue();
  });
}
