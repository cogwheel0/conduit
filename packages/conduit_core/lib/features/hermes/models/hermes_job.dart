import 'package:conduit_core/utils/unicode_prefix.dart';

import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/features/hermes/utils/hermes_time_parsing.dart';

const int kMaxHermesJobNameCharacters = 200;
const int kMaxHermesJobPromptCharacters = 5000;
const int kMaxHermesJobScheduleCharacters = 2048;
const int kMaxHermesJobStatusCharacters = 256;
const int kMaxHermesJobDeliverCharacters = 2048;
const int kMaxHermesJobErrorCharacters = 4096;

/// Ledger statuses of an attempt that has not finished
/// (`cron/executions.py`): the run a Stop can still reach.
const Set<String> kHermesJobInFlightStatuses = {'claimed', 'running'};

/// One attempt from the Hermes cron execution ledger: a dashboard job's
/// `latest_execution` or `live_execution` (Hermes 0.22.6 and later).
class HermesJobExecution {
  const HermesJobExecution({
    required this.id,
    required this.status,
    this.claimedAt,
    this.error,
  });

  final String id;

  /// `claimed`, `running`, `completed`, `failed`, `cancelled`, `missed`, …
  final String status;
  final DateTime? claimedAt;

  /// The failure text, or a cancelled or missed attempt's reason.
  final String? error;

  bool get inFlight => kHermesJobInFlightStatuses.contains(status);

  static HermesJobExecution? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = validateHermesOpaqueIdentifier(json['id']);
    final status = validateHermesBoundedString(
      json['status'],
      maxCharacters: kMaxHermesJobStatusCharacters,
    )?.toLowerCase();
    if (id == null || status == null) return null;
    return HermesJobExecution(
      id: id,
      status: status,
      claimedAt: parseHermesTimestamp(json['claimed_at']),
      error: validateHermesBoundedString(
        json['error'],
        maxCharacters: kMaxHermesJobErrorCharacters,
      ),
    );
  }
}

/// What a job does with the runs it missed while Hermes was not running.
enum HermesJobCatchUp {
  /// Stores nothing: recurring jobs follow `cron.catch_up_missed`, one-shot
  /// jobs skip.
  hermesDefault,

  /// Runs once for the missed runs (`catch_up: true`).
  runOnce,

  /// Skips the missed runs (`catch_up: false`).
  skip;

  static HermesJobCatchUp fromValue(bool? value) => switch (value) {
    true => runOnce,
    false => skip,
    null => hermesDefault,
  };

  /// The `catch_up` value Hermes stores for this choice.
  bool? get value => switch (this) {
    runOnce => true,
    skip => false,
    hermesDefault => null,
  };
}

/// How a Stop aimed at one execution ended, read from a later job list.
enum HermesJobStopOutcome { cancelled, finished, pending }

/// Settles a Stop by the attempt it targeted ([executionId], empty when the
/// cancel did not name one), never by "some run is live": a newer run must
/// not keep an earlier Stop pending. A job that is gone was stopped by its
/// removal, and a targeted attempt hidden behind a newer row counts as
/// cancelled because the accepted cancel is the best evidence left.
HermesJobStopOutcome hermesJobStopOutcome(HermesJob? job, String executionId) {
  if (job == null) return HermesJobStopOutcome.cancelled;
  if (executionId.isNotEmpty) {
    HermesJobExecution? target;
    for (final execution in [job.liveExecution, job.latestExecution]) {
      if (execution?.id == executionId) {
        target = execution;
        break;
      }
    }
    if (target == null) return HermesJobStopOutcome.cancelled;
    if (target.inFlight) return HermesJobStopOutcome.pending;
    return target.status == 'cancelled'
        ? HermesJobStopOutcome.cancelled
        : HermesJobStopOutcome.finished;
  }
  if (job.runInFlight) return HermesJobStopOutcome.pending;
  return job.latestExecution?.status == 'cancelled'
      ? HermesJobStopOutcome.cancelled
      : HermesJobStopOutcome.finished;
}

/// The answer to `POST /api/cron/jobs/{id}/cancel`.
class HermesJobStopResult {
  const HermesJobStopResult({
    required this.cancelled,
    this.executionId,
    this.beforeStart = false,
  });

  /// False when no run of the job was in flight.
  final bool cancelled;

  /// The job's Run now was withdrawn before it reached Hermes: nothing ran,
  /// so the job is stopped already.
  final bool beforeStart;

  /// The attempt the cancel was sent to, when Hermes named it.
  final String? executionId;

  static HermesJobStopResult fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return HermesJobStopResult(
      cancelled: map['cancelled'] == true,
      executionId: validateHermesOpaqueIdentifier(map['execution_id']),
    );
  }
}

/// The Hermes server cannot stop a running job: it predates the cancel route
/// (Hermes 0.22.6), or the connection mode has none.
class HermesJobStopUnsupportedException implements Exception {
  const HermesJobStopUnsupportedException();

  @override
  String toString() => 'This Hermes server cannot stop running jobs.';
}

/// A Hermes scheduled job (`/api/jobs/*`): a prompt run on a cron, interval,
/// duration, or one-shot schedule.
class HermesJob {
  const HermesJob({
    required this.id,
    required this.prompt,
    required this.schedule,
    this.name,
    this.enabled = true,
    this.lastStatus,
    this.state,
    this.deliveryTarget,
    this.lastError,
    this.lastDeliveryError,
    this.nextRun,
    this.lastRun,
    this.catchUp,
    this.latestExecution,
    this.liveExecution,
  });

  final String id;

  /// Optional human-friendly job name.
  final String? name;

  /// The prompt the agent runs each time the job fires.
  final String prompt;

  /// Server-accepted schedule expression suitable for editing and resubmission.
  final String schedule;

  /// Best label for the job: name, else a prompt preview.
  String get displayName {
    final boundedName = _boundedDisplayValue(name, kMaxHermesJobNameCharacters);
    if (boundedName != null && boundedName.isNotEmpty) return boundedName;
    final boundedPrompt =
        _boundedDisplayValue(prompt, kMaxHermesJobPromptCharacters) ?? '';
    if (boundedPrompt.isEmpty) return '(no prompt)';
    final oneLine = boundedPrompt.replaceAll(RegExp(r'\s+'), ' ');
    if (oneLine.runes.length <= 80) return oneLine;
    return '${takeUnicodeScalarPrefix(oneLine, 80)}…';
  }

  /// False when the job is paused.
  final bool enabled;

  final String? lastStatus;
  final String? state;
  final String? deliveryTarget;
  final String? lastError;
  final String? lastDeliveryError;
  final DateTime? nextRun;
  final DateTime? lastRun;

  /// The job's missed-run policy: true runs once, false skips, null follows
  /// Hermes' default.
  final bool? catchUp;

  /// The job's newest execution attempt (dashboard records only).
  final HermesJobExecution? latestExecution;

  /// The job's newest attempt still running under a live owner. It finds a
  /// run that a newer refused Run-now row hides from [latestExecution].
  final HermesJobExecution? liveExecution;

  HermesJobCatchUp get catchUpChoice => HermesJobCatchUp.fromValue(catchUp);

  /// Whether a run of this job is in flight, which is when Stop applies.
  bool get runInFlight =>
      (latestExecution?.inFlight ?? false) || liveExecution != null;

  /// The newest attempt's reason when it was stopped (empty when Hermes gave
  /// none), or null when that attempt was not cancelled.
  String? get lastCancelReason {
    final execution = latestExecution;
    if (execution == null || execution.status != 'cancelled') return null;
    return execution.error?.trim() ?? '';
  }

  static HermesJob? fromJson(Map<String, dynamic> json) {
    final id = validateHermesOpaqueIdentifier(json['id'] ?? json['job_id']);
    if (id == null) return null;

    final rawPrompt = json['prompt'];
    final prompt = rawPrompt == null
        ? ''
        : validateHermesBoundedString(
            rawPrompt,
            maxCharacters: kMaxHermesJobPromptCharacters,
            trim: false,
            allowEmpty: true,
          );
    if (prompt == null) return null;

    final bool enabled;
    if (json['enabled'] is bool) {
      enabled = json['enabled'] as bool;
    } else if (json['paused'] is bool) {
      enabled = !(json['paused'] as bool);
    } else {
      enabled = true;
    }

    return HermesJob(
      id: id,
      name: validateHermesBoundedString(
        json['name'],
        maxCharacters: kMaxHermesJobNameCharacters,
      ),
      prompt: prompt,
      schedule: _parseSchedule(json),
      enabled: enabled,
      lastStatus: validateHermesBoundedString(
        json['last_status'] ?? json['status'],
        maxCharacters: kMaxHermesJobStatusCharacters,
      ),
      state: validateHermesBoundedString(
        json['state'],
        maxCharacters: kMaxHermesJobStatusCharacters,
      ),
      deliveryTarget: validateHermesBoundedString(
        json['deliver'],
        maxCharacters: kMaxHermesJobDeliverCharacters,
      ),
      lastError: validateHermesBoundedString(
        json['last_error'],
        maxCharacters: kMaxHermesJobErrorCharacters,
      ),
      lastDeliveryError: validateHermesBoundedString(
        json['last_delivery_error'],
        maxCharacters: kMaxHermesJobErrorCharacters,
      ),
      nextRun: parseHermesTimestamp(json['next_run_at'] ?? json['next_run']),
      lastRun: parseHermesTimestamp(json['last_run_at'] ?? json['last_run']),
      catchUp: json['catch_up'] is bool ? json['catch_up'] as bool : null,
      latestExecution: HermesJobExecution.fromJson(json['latest_execution']),
      liveExecution: HermesJobExecution.fromJson(json['live_execution']),
    );
  }

  /// Prefer a machine-round-trippable schedule over presentation-only fields.
  /// Hermes returns structured cron, interval, and one-shot schedules alongside
  /// labels such as `once at …`; those labels are not accepted by create/edit.
  static String _parseSchedule(Map<String, dynamic> json) {
    final schedule = json['schedule'];
    final scalarSchedule = validateHermesBoundedString(
      schedule,
      maxCharacters: kMaxHermesJobScheduleCharacters,
    );
    if (scalarSchedule != null) return scalarSchedule;
    if (schedule is Map) {
      final kind = validateHermesBoundedString(
        schedule['kind'],
        maxCharacters: 32,
      )?.toLowerCase();
      if (kind == 'cron') {
        final expression = _nonEmptyScheduleValue(
          schedule['expr'] ?? schedule['cron'] ?? schedule['value'],
        );
        if (expression != null) return expression;
      }
      if (kind == 'interval') {
        final minutes = _parseWholeMinutes(schedule['minutes']);
        if (minutes != null && minutes >= 0) return 'every ${minutes}m';
      }
      if (kind == 'once') {
        final runAt = _nonEmptyScheduleValue(
          schedule['run_at'] ?? schedule['value'],
        );
        if (runAt != null) return runAt;
      }
      for (final value in [
        schedule['expr'],
        schedule['run_at'],
        schedule['value'],
        schedule['cron'],
        schedule['display'],
      ]) {
        final text = _nonEmptyScheduleValue(value);
        if (text != null) return text;
      }
    }
    for (final value in [json['cron'], json['schedule_display']]) {
      final text = _nonEmptyScheduleValue(value);
      if (text != null) return text;
    }
    return '';
  }

  static String? _nonEmptyScheduleValue(Object? value) {
    return validateHermesBoundedString(
      value,
      maxCharacters: kMaxHermesJobScheduleCharacters,
    );
  }

  static int? _parseWholeMinutes(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    if (value is String && value.length <= 32) return int.tryParse(value);
    return null;
  }

  static String? _boundedDisplayValue(String? value, int maxCharacters) {
    if (value == null || value.isEmpty) return null;
    final bounded = value.length <= maxCharacters
        ? value
        : takeUnicodeScalarPrefix(value, maxCharacters);
    final normalized = bounded.trim();
    return normalized.isEmpty ? null : normalized;
  }
}
