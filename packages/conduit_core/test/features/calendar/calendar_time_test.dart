import 'package:checks/checks.dart';
import 'package:conduit_core/features/calendar/calendar_time.dart';
import 'package:test/test.dart';

// Every expected instant below was computed with Python's zoneinfo, not with
// the code under test.

/// A zone given as its UTC offset and the instants (epoch milliseconds, UTC)
/// where the offset changes, so DST can be tested without the device's own
/// zone.
final class _Zone implements CalendarZone {
  const _Zone(this._initial, [this._changes = const []]);

  final Duration _initial;
  final List<(int utcMs, Duration offset)> _changes;

  @override
  Duration offsetAt(DateTime utcInstant) {
    var offset = _initial;
    for (final (at, next) in _changes) {
      if (utcInstant.millisecondsSinceEpoch >= at) offset = next;
    }
    return offset;
  }
}

// America/New_York in 2026: EST until 2026-03-08 07:00Z, EDT until
// 2026-11-01 06:00Z, EST after.
const _newYork = _Zone(Duration(hours: -5), [
  (1772953200000, Duration(hours: -4)),
  (1793512800000, Duration(hours: -5)),
]);

// Australia/Sydney in 2026: AEDT until 2026-04-04 16:00Z, AEST until
// 2026-10-03 16:00Z, AEDT after.
const _sydney = _Zone(Duration(hours: 11), [
  (1775318400000, Duration(hours: 10)),
  (1791043200000, Duration(hours: 11)),
]);

const _kolkata = _Zone(Duration(hours: 5, minutes: 30));

CalendarWallTime _wall(int y, int m, int d, [int hour = 0, int minute = 0]) =>
    CalendarWallTime(y, m, d, hour, minute);

void main() {
  group('reading an instant', () {
    test('shows the wall clock the zone has at that instant', () {
      check(wallTimeAt(1791293400000000000, _newYork))
          .equals(_wall(2026, 10, 6, 9, 30));
      check(wallTimeAt(1791259200000000000, _kolkata))
          .equals(_wall(2026, 10, 6, 9, 30));
    });

    test('drops seconds and nanoseconds without rounding up', () {
      // 17:09:27.123456789 in New York.
      check(wallTimeAt(1791320967123456789, _newYork))
          .equals(_wall(2026, 10, 6, 17, 9));
    });

    test('counts an instant before 1970 toward the past', () {
      check(floorDiv(-1, 1000)).equals(-1);
      check(floorDiv(-1000, 1000)).equals(-1);
      check(floorDiv(1, 1000)).equals(0);
      // 1969-12-31T23:59Z.
      check(wallTimeAt(-60000000000, const _Zone(Duration.zero)))
          .equals(_wall(1969, 12, 31, 23, 59));
    });
  });

  group('turning a wall clock into an instant', () {
    final cases = <String, (CalendarZone, CalendarWallTime, int)>{
      'an ordinary New York morning': (
        _newYork,
        _wall(2026, 10, 6, 9, 30),
        1791293400000000000,
      ),
      'a half-hour zone': (
        _kolkata,
        _wall(2026, 10, 6, 9, 30),
        1791259200000000000,
      ),
      'before New York springs forward': (
        _newYork,
        _wall(2026, 3, 8, 1, 30),
        1772951400000000000,
      ),
      // 02:30 does not exist; it is read with the offset before the change.
      'inside the skipped New York hour': (
        _newYork,
        _wall(2026, 3, 8, 2, 30),
        1772955000000000000,
      ),
      'after New York springs forward': (
        _newYork,
        _wall(2026, 3, 8, 3, 30),
        1772955000000000000,
      ),
      // 01:30 happens twice; the first one wins.
      'inside the repeated New York hour': (
        _newYork,
        _wall(2026, 11, 1, 1, 30),
        1793511000000000000,
      ),
      'inside the skipped Sydney hour': (
        _sydney,
        _wall(2026, 10, 4, 2, 30),
        1791045000000000000,
      ),
      'inside the repeated Sydney hour': (
        _sydney,
        _wall(2026, 4, 5, 2, 30),
        1775316600000000000,
      ),
      'midnight the day the clocks go back': (
        _newYork,
        _wall(2026, 11, 1),
        1793505600000000000,
      ),
      'midnight the day after the clocks go back': (
        _newYork,
        _wall(2026, 11, 2),
        1793595600000000000,
      ),
    };

    for (final MapEntry(:key, value: (zone, wall, expected)) in cases.entries) {
      test(key, () {
        check(nanosecondsFromWallTime(wall, zone)).equals(expected);
      });
    }

    test('an instant read back gives the same wall clock outside a gap', () {
      for (final (zone, wall) in <(CalendarZone, CalendarWallTime)>[
        (_newYork, _wall(2026, 10, 6, 9, 30)),
        (_newYork, _wall(2026, 3, 8, 3, 30)),
        (_sydney, _wall(2026, 10, 4, 3, 30)),
        (_kolkata, _wall(2026, 1, 1)),
      ]) {
        check(wallTimeAt(nanosecondsFromWallTime(wall, zone), zone))
            .equals(wall);
      }
    });
  });

  group('an edit that changed nothing', () {
    test('keeps the stored nanoseconds when the clock reads the same', () {
      const stored = 1791320967123456789;
      final shown = wallTimeAt(stored, _newYork);

      check(
        resolveEditedNanoseconds(
          originalNanoseconds: stored,
          edited: shown,
          zone: _newYork,
        ),
      ).equals(stored);
    });

    test('a changed clock becomes the minute the user picked', () {
      const stored = 1791320967123456789;

      check(
        resolveEditedNanoseconds(
          originalNanoseconds: stored,
          edited: _wall(2026, 10, 6, 17, 10),
          zone: _newYork,
        ),
      ).equals(1791321000000000000);
    });
  });

  group('range bounds', () {
    test('are ISO 8601 with the zone offset in force at each end', () {
      final range = CalendarRange.days(
        _wall(2026, 10, 6, 15, 45),
        14,
        zone: _newYork,
      );

      check(range.startIso).equals('2026-10-06T00:00:00-04:00');
      check(range.endIso).equals('2026-10-20T00:00:00-04:00');
      check(range.startNs).equals(1791259200000000000);
      check(range.endNs).equals(1792468800000000000);
    });

    test('keep a half-hour offset', () {
      final range = CalendarRange.days(_wall(2026, 10, 6), 1, zone: _kolkata);

      check(range.startIso).equals('2026-10-06T00:00:00+05:30');
      check(range.endIso).equals('2026-10-07T00:00:00+05:30');
    });

    test('take their own offsets across a clock change', () {
      final range = CalendarRange.days(_wall(2026, 10, 28), 7, zone: _newYork);

      check(range.startIso).equals('2026-10-28T00:00:00-04:00');
      check(range.endIso).equals('2026-11-04T00:00:00-05:00');
      check(range.startNs).equals(1793160000000000000);
      check(range.endNs).equals(1793768400000000000);
    });

    test('shift by whole days and keep their length', () {
      final next = CalendarRange.days(
        _wall(2026, 10, 6),
        14,
        zone: _newYork,
      ).shifted(14, zone: _newYork);

      check(next.firstDay).equals(_wall(2026, 10, 20));
      check(next.dayCount).equals(14);
    });
  });

  group('days an item touches', () {
    final range = CalendarRange.days(_wall(2026, 10, 6), 14, zone: _newYork);

    List<CalendarWallTime> days(int startNs, int? endNs) => daysInRange(
      daySpan(startNs: startNs, endNs: endNs, zone: _newYork),
      range,
    );

    test('an all-day span written to 23:59 covers each of its days', () {
      // 2026-10-12T00:00 to 2026-10-14T23:59, New York.
      check(days(1791777600000000000, 1792036740000000000)).deepEquals([
        _wall(2026, 10, 12),
        _wall(2026, 10, 13),
        _wall(2026, 10, 14),
      ]);
    });

    test('an end exactly at the next midnight does not spill a day', () {
      check(days(1791777600000000000, 1792036800000000000)).deepEquals([
        _wall(2026, 10, 12),
        _wall(2026, 10, 13),
        _wall(2026, 10, 14),
      ]);
    });

    test('an event with no end, or an end before its start, is one day', () {
      check(days(1791293400000000000, null)).deepEquals([_wall(2026, 10, 6)]);
      check(days(1791293400000000000, 1791293400000000000 - 1))
          .deepEquals([_wall(2026, 10, 6)]);
    });

    test('is clipped to the range', () {
      final narrow = CalendarRange.days(_wall(2026, 10, 13), 1, zone: _newYork);

      check(
        daysInRange(
          daySpan(
            startNs: 1791777600000000000,
            endNs: 1792036740000000000,
            zone: _newYork,
          ),
          narrow,
        ),
      ).deepEquals([_wall(2026, 10, 13)]);
    });

    test('an all-day event kept as UTC midnight falls on the day before in '
        'a zone behind UTC', () {
      // 2026-10-12T00:00Z is 2026-10-11 20:00 in New York. The device zone is
      // what the user chose, so that is the day it is shown on.
      check(daySpan(startNs: 1791763200000000000, zone: _newYork).first)
          .equals(_wall(2026, 10, 11));
    });
  });
}
