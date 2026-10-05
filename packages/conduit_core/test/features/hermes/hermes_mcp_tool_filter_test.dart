import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_mcp.dart';
import 'package:test/test.dart';

HermesMcpToolFilter _filter(Map<String, Object?> value) =>
    HermesMcpToolFilter.tryParse(value)!;

void main() {
  group('HermesMcpToolFilter equality', () {
    test('compares by content, whatever order the keys arrived in', () {
      final a = _filter({
        'include': ['search', 'fetch'],
        'resources': false,
      });
      final b = _filter({
        'resources': false,
        'include': ['search', 'fetch'],
      });

      check(a == b).isTrue();
      check(a.hashCode).equals(b.hashCode);
    });

    test('nested maps in a different order hash the same', () {
      final a = _filter({
        'extra': {'x': 1, 'y': 2},
        'include': ['a'],
      });
      final b = _filter({
        'include': ['a'],
        'extra': {'y': 2, 'x': 1},
      });

      check(a == b).isTrue();
      check(a.hashCode).equals(b.hashCode);
      check({a, b}).length.equals(1);
    });

    test('list order still matters', () {
      final a = _filter({
        'include': ['a', 'b'],
      });
      final b = _filter({
        'include': ['b', 'a'],
      });

      check(a == b).isFalse();
    });

    test('different content is not equal', () {
      final a = _filter({
        'include': ['a'],
      });
      final b = _filter({
        'include': ['a'],
        'prompts': false,
      });

      check(a == b).isFalse();
    });

    test('a single string and a list are different shapes', () {
      final single = _filter({'include': 'a'});
      final list = _filter({
        'include': ['a'],
      });

      check(single == list).isFalse();
    });
  });
}
