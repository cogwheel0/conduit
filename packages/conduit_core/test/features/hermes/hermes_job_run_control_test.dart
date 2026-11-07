import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:test/test.dart';

Map<String, dynamic> _execution(String id, String status, {String? error}) =>
    {
      'id': id,
      'job_id': 'job-1',
      'status': status,
      'claimed_at': '2026-03-02T09:00:00+00:00',
      'error': error,
    };

HermesJob _job({
  Map<String, dynamic>? latest,
  Map<String, dynamic>? live,
}) => HermesJob.fromJson({
  'id': 'job-1',
  'name': 'Morning digest',
  'prompt': 'Summarize the overnight notes',
  'schedule': '0 7 * * *',
  'latest_execution': latest,
  'live_execution': live,
})!;

void main() {
  group('job record', () {
    test('reads the ledger attempts and delivery', () {
      final job = HermesJob.fromJson({
        'id': 'job-1',
        'prompt': 'Summarize the overnight notes',
        'schedule': '0 7 * * *',
        'deliver': 'local,bot-chat:research',
        'last_status': 'cancelled',
        'latest_execution': _execution(
          'exec-2',
          'cancelled',
          error: 'cancelled on request (Stop)',
        ),
        'live_execution': null,
      })!;

      check(job.deliveryTarget).equals('local,bot-chat:research');
      check(job.lastStatus).equals('cancelled');
      check(job.latestExecution).isNotNull()
        ..has((e) => e.id, 'id').equals('exec-2')
        ..has((e) => e.status, 'status').equals('cancelled')
        ..has((e) => e.claimedAt, 'claimedAt').isNotNull();
      check(job.liveExecution).isNull();
      check(job.runInFlight).isFalse();
      check(job.lastCancelReason).equals('cancelled on request (Stop)');
    });

    test('a record without the new fields has no run to stop', () {
      final job = _job();

      check(job.runInFlight).isFalse();
      check(job.lastCancelReason).isNull();
    });

    test('ignores malformed attempts', () {
      final job = _job(
        latest: {'id': '', 'status': 'running'},
        live: {'id': 'exec-1'},
      );

      check(job.latestExecution).isNull();
      check(job.liveExecution).isNull();
      check(job.runInFlight).isFalse();
    });
  });

  group('run in flight', () {
    test('claimed and running attempts can be stopped', () {
      check(_job(latest: _execution('a', 'claimed')).runInFlight).isTrue();
      check(_job(latest: _execution('a', 'running')).runInFlight).isTrue();
      check(_job(latest: _execution('a', 'completed')).runInFlight).isFalse();
      check(_job(latest: _execution('a', 'failed')).runInFlight).isFalse();
    });

    test('a live run hidden behind a refused Run now still counts', () {
      final job = _job(
        latest: _execution('b', 'failed', error: 'Fire claim not acquired'),
        live: _execution('a', 'running'),
      );

      check(job.runInFlight).isTrue();
    });

    test('a cancelled attempt without a reason reads as empty', () {
      check(_job(latest: _execution('a', 'cancelled')).lastCancelReason)
          .equals('');
      check(_job(latest: _execution('a', 'missed')).lastCancelReason).isNull();
    });
  });

  group('stop outcome', () {
    test('a removed job was stopped by its removal', () {
      check(hermesJobStopOutcome(null, 'a'))
          .equals(HermesJobStopOutcome.cancelled);
    });

    test('settles by the targeted attempt', () {
      check(
        hermesJobStopOutcome(_job(latest: _execution('a', 'running')), 'a'),
      ).equals(HermesJobStopOutcome.pending);
      check(
        hermesJobStopOutcome(_job(latest: _execution('a', 'cancelled')), 'a'),
      ).equals(HermesJobStopOutcome.cancelled);
      check(
        hermesJobStopOutcome(_job(latest: _execution('a', 'completed')), 'a'),
      ).equals(HermesJobStopOutcome.finished);
    });

    test('a newer run does not keep an earlier stop pending', () {
      final job = _job(latest: _execution('b', 'running'));

      check(hermesJobStopOutcome(job, 'a'))
          .equals(HermesJobStopOutcome.cancelled);
    });

    test('finds the target in the live attempt', () {
      final job = _job(
        latest: _execution('b', 'failed'),
        live: _execution('a', 'running'),
      );

      check(hermesJobStopOutcome(job, 'a'))
          .equals(HermesJobStopOutcome.pending);
    });

    test('without a target it watches whatever run is live', () {
      check(hermesJobStopOutcome(_job(latest: _execution('a', 'claimed')), ''))
          .equals(HermesJobStopOutcome.pending);
      check(
        hermesJobStopOutcome(_job(latest: _execution('a', 'cancelled')), ''),
      ).equals(HermesJobStopOutcome.cancelled);
      check(hermesJobStopOutcome(_job(), ''))
          .equals(HermesJobStopOutcome.finished);
    });
  });

  test('a cancel answer names the attempt it reached', () {
    final stopped = HermesJobStopResult.fromJson({
      'success': true,
      'cancelled': true,
      'execution_id': 'exec-9',
      'job_id': 'job-1',
    });
    final idle = HermesJobStopResult.fromJson({
      'success': true,
      'cancelled': false,
      'execution_id': null,
    });

    check(stopped.cancelled).isTrue();
    check(stopped.executionId).equals('exec-9');
    check(idle.cancelled).isFalse();
    check(idle.executionId).isNull();
    check(HermesJobStopResult.fromJson(null).cancelled).isFalse();
  });
}
