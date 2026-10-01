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
    check(isValidHermesSchedule('60 9 * * 1')).isFalse();
    check(isValidHermesSchedule('0 9 * * * 2027')).isFalse();
    check(isValidHermesSchedule('0 0 * * 7 0')).isFalse();
    check(isValidHermesSchedule('0 0 * * 7 0 2027')).isFalse();
    check(isValidHermesSchedule('0 9 * * * * 2100')).isFalse();
    check(isValidHermesSchedule('0 9 * *')).isFalse();
    check(isValidHermesSchedule('0 9 * JAN MON')).isFalse();
    check(isValidHermesSchedule('every soon')).isFalse();
    check(isValidHermesSchedule('2027-99-99T09:30')).isFalse();
    check(isValidHermesSchedule('2027-02-29T09:30')).isFalse();
    check(isValidHermesSchedule('2027-04-05T25:30')).isFalse();
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
