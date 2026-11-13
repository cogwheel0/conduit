import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';
import 'package:test/test.dart';

void main() {
  group('parseHermesCronSchedule', () {
    test('reads each cadence the English sentence words', () {
      const cases = <String, HermesCadence?>{
        '': HermesCadence(HermesCadenceKind.none),
        '* * * * *': HermesCadence(HermesCadenceKind.everyMinute),
        '*/1 * * * *': HermesCadence(HermesCadenceKind.everyMinute),
        '*/15 * * * *': HermesCadence(
          HermesCadenceKind.everyMinutes,
          every: 15,
        ),
        '0 * * * *': HermesCadence(HermesCadenceKind.everyHour, minute: 0),
        '5 */1 * * *': HermesCadence(HermesCadenceKind.everyHour, minute: 5),
        '30 */6 * * *': HermesCadence(
          HermesCadenceKind.everyHours,
          every: 6,
          minute: 30,
        ),
        '0 8 * * *': HermesCadence(HermesCadenceKind.daily, hour: 8, minute: 0),
        '15 9 * * MON-FRI': HermesCadence(
          HermesCadenceKind.weekdays,
          hour: 9,
          minute: 15,
        ),
        '0 10 * * sat,sun': HermesCadence(
          HermesCadenceKind.weekends,
          hour: 10,
          minute: 0,
        ),
        '45 17 * * 7': HermesCadence(
          HermesCadenceKind.weekly,
          hour: 17,
          minute: 45,
          weekday: 0,
        ),
        '0 6 22 * *': HermesCadence(
          HermesCadenceKind.monthly,
          hour: 6,
          minute: 0,
          day: 22,
        ),
        // Shown as written.
        'every 1h': null,
        '0 9 1 JAN *': null,
        '0 9-17 * * *': null,
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        check(because: key, parseHermesCronSchedule(key)).equals(value);
      }
    });

    test('the English sentence is unchanged', () {
      const cases = <String, String>{
        '': 'No schedule',
        '*/15 * * * *': 'Every 15 minutes',
        '5 * * * *': 'Every hour at :05',
        '30 */6 * * *': 'Every 6 hours at :30',
        '0 */2 * * *': 'Every 2 hours',
        '0 8 * * *': 'Every day at 8:00 AM',
        '15 21 * * 1-5': 'Weekdays at 9:15 PM',
        '0 0 * * 0,6': 'Weekends at 12:00 AM',
        '45 17 * * THU': 'Every Thursday at 5:45 PM',
        '0 12 * * *': 'Every day at 12:00 PM',
        '0 6 22 * *': 'Monthly on the 22nd at 6:00 AM',
        '0 6 13 * *': 'Monthly on the 13th at 6:00 AM',
        'every  1h': 'every 1h',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        check(because: key, describeHermesCronSchedule(key)).equals(value);
      }
    });
  });
}
