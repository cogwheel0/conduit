import 'package:checks/checks.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:test/test.dart';

// Fixtures are the literal strings the pinned Open WebUI schedule control
// writes (src/lib/components/automations/ScheduleDropdown.svelte, buildRrule),
// worked out by hand from its template rather than produced by this client.
const _once = 'DTSTART:20261007T090500\nRRULE:FREQ=DAILY;COUNT=1';
const _daily = 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0';
const _weekly = 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE;BYHOUR=18;BYMINUTE=30';

void main() {
  group('the controls write what the web control writes', () {
    test('one time', () {
      check(
        const OnceAutomationSchedule(
          year: 2026,
          month: 10,
          day: 7,
          hour: 9,
          minute: 5,
        ).toRrule(),
      ).equals(_once);
    });

    test('daily', () {
      check(const DailyAutomationSchedule(hour: 9, minute: 0).toRrule())
          .equals(_daily);
    });

    test(
      'weekly lists days Monday first whatever order they were chosen in',
      () {
        check(
          const WeeklyAutomationSchedule(
            hour: 18,
            minute: 30,
            days: {'WE', 'MO'},
          ).toRrule(),
        ).equals(_weekly);
      },
    );
  });

  group('a supported rule is read into controls', () {
    test('one time', () {
      check(AutomationSchedule.parse(_once)).equals(
        const OnceAutomationSchedule(
          year: 2026,
          month: 10,
          day: 7,
          hour: 9,
          minute: 5,
        ),
      );
    });

    test('daily', () {
      check(AutomationSchedule.parse(_daily))
          .equals(const DailyAutomationSchedule(hour: 9, minute: 0));
    });

    test('weekly', () {
      check(AutomationSchedule.parse(_weekly)).equals(
        const WeeklyAutomationSchedule(
          hour: 18,
          minute: 30,
          days: {'MO', 'WE'},
        ),
      );
    });

    // The web control appends days in the order they were tapped, and the
    // server stores whatever it was sent.
    test('weekly in tap order, and with other whitespace or case', () {
      check(
        AutomationSchedule.parse(
          'rrule:freq=weekly;byday=WE,MO;byhour=18;byminute=30',
        ),
      ).equals(
        const WeeklyAutomationSchedule(
          hour: 18,
          minute: 30,
          days: {'MO', 'WE'},
        ),
      );
      check(
        AutomationSchedule.parse(
          'DTSTART:20261007T090500\r\nRRULE:FREQ=DAILY;COUNT=1',
        ),
      ).isA<OnceAutomationSchedule>();
    });

    test('a supported rule reads back to the rule it came from', () {
      for (final rule in [_once, _daily, _weekly]) {
        check(
          AutomationSchedule.parse(rule).toRrule(),
          because: rule,
        ).equals(rule);
      }
    });
  });

  // Anything the controls cannot reproduce is kept whole. Reading it into
  // controls would silently rewrite it on the next save.
  group('an unsupported rule is kept exactly as stored', () {
    final rules = <String, String>{
      'hourly': 'RRULE:FREQ=HOURLY;BYMINUTE=0',
      'monthly': 'RRULE:FREQ=MONTHLY;BYMONTHDAY=15;BYHOUR=9;BYMINUTE=0',
      'every other day': 'RRULE:FREQ=DAILY;INTERVAL=2;BYHOUR=9;BYMINUTE=0',
      'every five minutes': 'RRULE:FREQ=MINUTELY;INTERVAL=5',
      'ends on a date':
          'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0;UNTIL=20271231T000000',
      'a limited count': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0;COUNT=3',
      'a zone on the start':
          'DTSTART;TZID=America/New_York:20261007T090000\n'
          'RRULE:FREQ=DAILY;COUNT=1',
      'a UTC start': 'DTSTART:20261007T090000Z\nRRULE:FREQ=DAILY;COUNT=1',
      'a start on a recurring rule':
          'DTSTART:20261007T090000\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0',
      'a count of one on a weekly rule':
          'DTSTART:20261007T090000\nRRULE:FREQ=WEEKLY;COUNT=1',
      'a one-time start with seconds':
          'DTSTART:20261007T090030\nRRULE:FREQ=DAILY;COUNT=1',
      'weekly with no days': 'RRULE:FREQ=WEEKLY;BYHOUR=9;BYMINUTE=0',
      'weekly with an unknown day':
          'RRULE:FREQ=WEEKLY;BYDAY=MO,XX;BYHOUR=9;BYMINUTE=0',
      'weekly with a repeated day':
          'RRULE:FREQ=WEEKLY;BYDAY=MO,MO;BYHOUR=9;BYMINUTE=0',
      'an hour that does not exist': 'RRULE:FREQ=DAILY;BYHOUR=24;BYMINUTE=0',
      'several hours': 'RRULE:FREQ=DAILY;BYHOUR=9,17;BYMINUTE=0',
      'a repeated key': 'RRULE:FREQ=DAILY;BYHOUR=9;BYHOUR=10;BYMINUTE=0',
      'a date that does not exist':
          'DTSTART:20260230T090000\nRRULE:FREQ=DAILY;COUNT=1',
      'a count with no start': 'RRULE:FREQ=DAILY;COUNT=1',
      'two rules': 'RRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0\nRRULE:FREQ=DAILY;BYHOUR=10;BYMINUTE=0',
      'an empty rule': '',
      'text that is not a rule': 'every morning',
    };

    for (final MapEntry(:key, :value) in rules.entries) {
      test(key, () {
        final schedule = AutomationSchedule.parse(value);

        check(schedule).isA<RawAutomationSchedule>();
        check(schedule.toRrule()).equals(value);
      });
    }
  });
}
