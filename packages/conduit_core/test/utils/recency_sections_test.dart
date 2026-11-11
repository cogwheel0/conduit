import 'package:checks/checks.dart';
import 'package:conduit_core/utils/recency_sections.dart';
import 'package:test/test.dart';

void main() {
  group('recencySectionFor in the local zone', () {
    // Just after midnight, where a 24-hour window would still say "today"
    // for last night.
    final now = DateTime(2026, 11, 8, 0, 30);

    RecencySection at(DateTime timestamp) =>
        recencySectionFor(timestamp, now: now);

    test('splits today from yesterday at local midnight', () {
      check(at(DateTime(2026, 11, 8))).equals(RecencySection.today);
      check(at(DateTime(2026, 11, 7, 23, 59, 59))).equals(
        RecencySection.yesterday,
      );
      check(at(DateTime(2026, 11, 7))).equals(RecencySection.yesterday);
    });

    test('previous 7 days covers two to seven calendar days ago', () {
      check(at(DateTime(2026, 11, 6, 23, 59))).equals(
        RecencySection.previous7Days,
      );
      check(at(DateTime(2026, 11, 1))).equals(RecencySection.previous7Days);
      check(at(DateTime(2026, 10, 31, 23, 59))).equals(
        RecencySection.previous30Days,
      );
    });

    test('previous 30 days ends 30 calendar days ago', () {
      check(at(DateTime(2026, 10, 9))).equals(RecencySection.previous30Days);
      check(at(DateTime(2026, 10, 8, 23, 59))).equals(
        RecencySection.month(2026, 10),
      );
    });

    test('older items fall in their own month and year', () {
      check(at(DateTime(2026, 9, 29, 16))).equals(
        RecencySection.month(2026, 9),
      );
      check(at(DateTime(2025, 12, 31, 23, 59))).equals(
        RecencySection.month(2025, 12),
      );
    });

    test('a timestamp later than now counts as today', () {
      check(at(DateTime(2026, 11, 9, 8))).equals(RecencySection.today);
    });

    test('reads a UTC instant on the local calendar day', () {
      // Five minutes before local midnight, whatever the machine's zone.
      final instant = DateTime(2026, 11, 7, 23, 55).toUtc();
      check(instant.isUtc).isTrue();
      check(at(instant)).equals(RecencySection.yesterday);
    });
  });

  group('recencySectionFor in UTC', () {
    test('uses UTC calendar days when now is UTC', () {
      final now = DateTime.utc(2026, 11, 8, 0, 30);
      check(
        recencySectionFor(DateTime.utc(2026, 11, 7, 23, 30), now: now),
      ).equals(RecencySection.yesterday);
      check(
        recencySectionFor(DateTime.utc(2026, 11, 8, 0, 5), now: now),
      ).equals(RecencySection.today);
    });

    test('converts a local timestamp into UTC first', () {
      final now = DateTime.utc(2026, 11, 8, 12);
      final local = DateTime.utc(2026, 11, 7, 23, 30).toLocal();
      check(local.isUtc).isFalse();
      check(recencySectionFor(local, now: now)).equals(
        RecencySection.yesterday,
      );
    });

    test('the month of an old item is its UTC month', () {
      final now = DateTime.utc(2026, 11, 8, 12);
      check(
        recencySectionFor(DateTime.utc(2026, 8, 31, 23, 59), now: now),
      ).equals(RecencySection.month(2026, 8));
    });
  });

  group('calendarDaysBetween', () {
    test('counts dates, not 24-hour periods', () {
      check(
        calendarDaysBetween(DateTime(2026, 11, 7, 23, 59), DateTime(2026, 11, 8)),
      ).equals(1);
      check(
        calendarDaysBetween(DateTime(2026, 11, 8), DateTime(2026, 11, 8, 23)),
      ).equals(0);
    });

    test('is one day per date across daylight-saving changes', () {
      // US and EU transitions of 2026; local days are 23 or 25 hours long
      // where the zone observes them.
      for (final (from, to) in [
        (DateTime(2026, 3, 7, 12), DateTime(2026, 3, 9, 0, 30)),
        (DateTime(2026, 3, 28, 12), DateTime(2026, 3, 30, 0, 30)),
        (DateTime(2026, 10, 24, 12), DateTime(2026, 10, 26, 0, 30)),
        (DateTime(2026, 10, 31, 12), DateTime(2026, 11, 2, 0, 30)),
      ]) {
        check(calendarDaysBetween(from, to)).equals(2);
      }
    });

    test('is negative when the first date is later', () {
      check(
        calendarDaysBetween(DateTime(2026, 11, 9), DateTime(2026, 11, 8)),
      ).equals(-1);
    });
  });

  group('RecencySection', () {
    test('sorts newest first, months by year then month', () {
      final shuffled = [
        RecencySection.month(2025, 12),
        RecencySection.previous30Days,
        RecencySection.month(2026, 1),
        RecencySection.today,
        RecencySection.month(2026, 9),
        RecencySection.previous7Days,
        RecencySection.yesterday,
      ]..sort();
      check(shuffled).deepEquals([
        RecencySection.today,
        RecencySection.yesterday,
        RecencySection.previous7Days,
        RecencySection.previous30Days,
        RecencySection.month(2026, 9),
        RecencySection.month(2026, 1),
        RecencySection.month(2025, 12),
      ]);
    });

    test('months are equal by value', () {
      check(RecencySection.month(2026, 9)).equals(RecencySection.month(2026, 9));
      check(
        RecencySection.month(2026, 9).hashCode,
      ).equals(RecencySection.month(2026, 9).hashCode);
      check(RecencySection.month(2026, 9)).not(
        (it) => it.equals(RecencySection.month(2025, 9)),
      );
    });

    test('rejects a month outside 1-12', () {
      check(() => RecencySection.month(2026, 13)).throws<RangeError>();
      check(() => RecencySection.month(2026, 0)).throws<RangeError>();
    });
  });

  group('groupByRecency', () {
    final now = DateTime(2026, 11, 8, 17);

    test('groups newest section first and keeps item order', () {
      final items = [
        ('a', DateTime(2026, 11, 8, 16, 25)),
        ('b', DateTime(2026, 11, 8, 13)),
        ('c', DateTime(2026, 11, 7, 11)),
        ('d', DateTime(2026, 11, 5, 16)),
        ('e', DateTime(2026, 10, 27)),
        ('f', DateTime(2026, 9, 29)),
        ('g', DateTime(2025, 9, 2)),
      ];
      final groups = groupByRecency(
        items,
        timestampOf: (item) => item.$2,
        now: now,
      );
      check(groups.map((group) => group.section).toList()).deepEquals([
        RecencySection.today,
        RecencySection.yesterday,
        RecencySection.previous7Days,
        RecencySection.previous30Days,
        RecencySection.month(2026, 9),
        RecencySection.month(2025, 9),
      ]);
      check(
        groups.first.items.map((item) => item.$1).toList(),
      ).deepEquals(['a', 'b']);
    });

    test('leaves out sections without items', () {
      final groups = groupByRecency(
        [DateTime(2026, 11, 8, 9), DateTime(2026, 8, 3)],
        timestampOf: (timestamp) => timestamp,
        now: now,
      );
      check(groups.map((group) => group.section).toList()).deepEquals([
        RecencySection.today,
        RecencySection.month(2026, 8),
      ]);
    });

    test('sorts out-of-order input into sections without reordering them', () {
      final groups = groupByRecency(
        [
          ('old', DateTime(2026, 8, 3)),
          ('new', DateTime(2026, 11, 8, 9)),
          ('older', DateTime(2026, 7, 1)),
          ('newer', DateTime(2026, 11, 8, 10)),
        ],
        timestampOf: (item) => item.$2,
        now: now,
      );
      check(
        groups.map((group) => group.items.map((item) => item.$1).toList()),
      ).deepEquals([
        ['new', 'newer'],
        ['old'],
        ['older'],
      ]);
    });

    test('is empty for no items', () {
      check(
        groupByRecency(
          const <DateTime>[],
          timestampOf: (timestamp) => timestamp,
          now: now,
        ),
      ).isEmpty();
    });
  });

  group('recencyStampKindFor', () {
    // Wednesday 11 November 2026, just after midnight.
    final now = DateTime(2026, 11, 11, 0, 30);

    RecencyStampKind at(DateTime timestamp) =>
        recencyStampKindFor(timestamp, now: now);

    test('dates today by its time and the day before as yesterday', () {
      check(at(DateTime(2026, 11, 11))).equals(RecencyStampKind.time);
      check(at(DateTime(2026, 11, 10, 23, 59)))
          .equals(RecencyStampKind.yesterday);
    });

    test('names the weekday for two to six days ago', () {
      check(at(DateTime(2026, 11, 9))).equals(RecencyStampKind.weekday);
      check(at(DateTime(2026, 11, 5))).equals(RecencyStampKind.weekday);
    });

    test('dates anything from a week ago, whose weekday is today\'s', () {
      check(at(DateTime(2026, 11, 4, 23, 59))).equals(RecencyStampKind.date);
      check(at(DateTime(2025, 12, 24))).equals(RecencyStampKind.date);
    });

    test('a timestamp ahead of now, from clock skew, is today', () {
      check(at(DateTime(2026, 11, 12, 9))).equals(RecencyStampKind.time);
    });

    test('reads a UTC instant on the local calendar day', () {
      final instant = DateTime(2026, 11, 10, 23, 59).toUtc();
      check(at(instant)).equals(RecencyStampKind.yesterday);
    });
  });
}
