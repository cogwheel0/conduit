import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';
import 'package:test/test.dart';

void main() {
  test('Hermes schedule validation mirrors the server input forms', () {
    check(isValidHermesSchedule('0 9 * * 1')).isTrue();
    check(isValidHermesSchedule('0 22-2 * * 5-1')).isTrue();
    check(isValidHermesSchedule('0 0 * * 7')).isTrue();
    check(isValidHermesSchedule('0 9 * * * 30')).isTrue();
    check(isValidHermesSchedule('0 0 * * 6 0')).isTrue();
    check(isValidHermesSchedule('0 9 * * * * 2027')).isTrue();
    check(isValidHermesSchedule('every 30m')).isTrue();
    check(isValidHermesSchedule('EVERY 2 hours')).isTrue();
    check(isValidHermesSchedule('45m')).isTrue();
    check(isValidHermesSchedule('2027-04-05T09:30:00Z')).isTrue();
    check(isValidHermesSchedule('2027-04-05T09:30:00+05:30')).isTrue();
    check(isValidHermesSchedule('2027-04-05t09:30')).isTrue();
    check(isValidHermesSchedule('2027-04-05 09:30')).isTrue();
    check(isValidHermesSchedule('60 9 * * 1')).isFalse();
    check(isValidHermesSchedule('0 9 * * * 2027')).isFalse();
    check(isValidHermesSchedule('0 0 * * 7 0')).isFalse();
    check(isValidHermesSchedule('0 0 * * 7 0 2027')).isFalse();
    check(isValidHermesSchedule('0 9 * * * * 2100')).isFalse();
    check(isValidHermesSchedule('0 9 * *')).isFalse();
    check(isValidHermesSchedule('0 9 * FOO MON')).isFalse();
    check(isValidHermesSchedule('every soon')).isFalse();
    check(isValidHermesSchedule('2027-99-99T09:30')).isFalse();
    check(isValidHermesSchedule('2027-02-29T09:30')).isFalse();
    check(isValidHermesSchedule('2027-04-05T25:30')).isFalse();
  });

  test('named months and weekdays are valid cron fields', () {
    check(isValidHermesSchedule('0 9 * JAN MON')).isTrue();
    check(isValidHermesSchedule('30 18 * * MON')).isTrue();
    check(isValidHermesSchedule('30 18 * * mon-fri')).isTrue();
    check(isValidHermesSchedule('0 9 * JAN-MAR MON,WED,FRI')).isTrue();
    check(isValidHermesSchedule('0 9 * * SUN')).isTrue();
    // A name belongs only in its own field.
    check(isValidHermesSchedule('0 9 MON * *')).isFalse();
    check(isValidHermesSchedule('0 9 * * JAN')).isFalse();
    check(isValidHermesSchedule('0 9 * MON *')).isFalse();
    check(isValidHermesSchedule('30 18 * * FUNDAY')).isFalse();
  });

  test('one-shot delays and bare units are valid', () {
    check(isValidHermesSchedule('in 30m')).isTrue();
    check(isValidHermesSchedule('IN 2 hours')).isTrue();
    check(isValidHermesSchedule('in 1d')).isTrue();
    check(isValidHermesSchedule('hour')).isTrue();
    check(isValidHermesSchedule('day')).isTrue();
    check(isValidHermesSchedule('every hour')).isTrue();
    check(isValidHermesSchedule('in')).isFalse();
    check(isValidHermesSchedule('in soon')).isFalse();
    check(isValidHermesSchedule('in 30')).isFalse();
  });

  test('natural day and time phrases are valid, with or without every', () {
    for (final phrase in [
      'every monday 9am',
      'Every Monday at 9:30pm',
      'every day at noon',
      'every weekday 14:00',
      'every weekend at midnight',
      'every mon, wed and fri at 7',
      'weekdays at 9am',
      'daily 6:15am',
      'monday 9am',
      'sat 12pm',
    ]) {
      check(because: phrase, isValidHermesSchedule(phrase)).isTrue();
    }
    for (final phrase in [
      'every monday',
      'every monday at',
      'every blursday 9am',
      'every monday 25:00',
      'every monday 9:75',
      'every monday 13pm',
      'every monday 0am',
      'weekdays at',
      'weekdays',
      'blursday 9am',
    ]) {
      check(because: phrase, isValidHermesSchedule(phrase)).isFalse();
    }
  });

  test('the job draft check reports each field', () {
    final valid = validateHermesJobDraft(
      name: ' Morning brief ',
      prompt: 'Summarize my inbox',
      schedule: ' 0 9 * * * ',
    );
    check(hermesJobDraftIsValid(valid)).isTrue();

    final empty = validateHermesJobDraft(name: ' ', prompt: '', schedule: ' ');
    check(empty.name).equals(HermesJobFieldError.required);
    check(empty.prompt).equals(HermesJobFieldError.required);
    check(empty.schedule).equals(HermesJobFieldError.required);
    check(hermesJobDraftIsValid(empty)).isFalse();

    // Limits count code points, so an emoji is one character.
    final longName = '😀' * kMaxHermesJobNameCharacters;
    check(
      validateHermesJobDraft(
        name: longName,
        prompt: 'x',
        schedule: 'every 5m',
      ).name,
    ).isNull();
    final tooLong = validateHermesJobDraft(
      name: '$longName!',
      prompt: 'x' * (kMaxHermesJobPromptCharacters + 1),
      schedule: 'soon',
    );
    check(tooLong.name).equals(HermesJobFieldError.tooLong);
    check(tooLong.prompt).equals(HermesJobFieldError.tooLong);
    check(tooLong.schedule).equals(HermesJobFieldError.invalidSchedule);
  });
}
