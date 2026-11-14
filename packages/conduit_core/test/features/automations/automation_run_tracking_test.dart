import 'package:checks/checks.dart';
import 'package:conduit_core/features/automations/automation_run_tracking.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:test/test.dart';

AutomationRun _run(String id, int? at, {String status = 'success'}) =>
    AutomationRun(id: id, automationId: 't1', status: status, createdAtNs: at);

Automation _task({AutomationRun? lastRun, int? lastRunAt}) => Automation(
  id: 't1',
  userId: 'u1',
  name: 'Digest',
  data: const <String, dynamic>{},
  isActive: true,
  lastRun: lastRun,
  lastRunAtNs: lastRunAt,
);

void main() {
  group('AutomationRunBaseline', () {
    test('knows every run it was given and the newest time', () {
      final baseline = AutomationRunBaseline.of(
        runs: [_run('r1', 100), _run('r2', 300)],
        task: _task(lastRun: _run('r0', 50)),
      );
      check(baseline.knownIds).deepEquals({'r0', 'r1', 'r2'});
      check(baseline.newestBefore).equals(300);
    });

    test("the task's last run time counts when it is later", () {
      final baseline = AutomationRunBaseline.of(
        runs: [_run('r1', 100)],
        task: _task(lastRunAt: 500),
      );
      check(baseline.newestBefore).equals(500);
    });

    test('a new run at or after the newest time is the requested one', () {
      final baseline = AutomationRunBaseline.of(runs: [_run('r1', 100)]);
      final found = baseline.requestedRun([_run('r2', 100), _run('r1', 100)]);
      check(found).isNotNull().has((r) => r.id, 'id').equals('r2');
    });

    test('a new run older than the newest known one is not it', () {
      final baseline = AutomationRunBaseline.of(runs: [_run('r1', 100)]);
      check(baseline.requestedRun([_run('r1', 100), _run('late', 90)]))
          .isNull();
    });

    test('with no history, any new run is it, timed or not', () {
      const baseline = AutomationRunBaseline(knownIds: <String>{});
      check(baseline.requestedRun([_run('r1', null)]))
          .isNotNull()
          .has((r) => r.id, 'id')
          .equals('r1');
    });
  });

  test('mergeAutomationRuns puts the page first and keeps each run once', () {
    final merged = mergeAutomationRuns(
      [_run('r3', 3), _run('r2', 2)],
      [_run('r2', 2), _run('r1', 1)],
    );
    check(merged.map((r) => r.id)).deepEquals(['r3', 'r2', 'r1']);
  });
}
