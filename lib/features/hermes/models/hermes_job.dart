import '../../../core/utils/unicode_prefix.dart';

const int kMaxHermesJobNameCharacters = 200;
const int kMaxHermesJobPromptCharacters = 5000;

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
    this.nextRun,
    this.lastRun,
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
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    if (prompt.trim().isEmpty) return '(no prompt)';
    final oneLine = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (oneLine.runes.length <= 80) return oneLine;
    return '${takeUnicodeScalarPrefix(oneLine, 80)}…';
  }

  /// False when the job is paused.
  final bool enabled;

  final String? lastStatus;
  final DateTime? nextRun;
  final DateTime? lastRun;

  static HermesJob? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? json['job_id'])?.toString();
    if (id == null || id.isEmpty) return null;

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
      name: json['name']?.toString(),
      prompt: (json['prompt'] ?? '').toString(),
      schedule: _parseSchedule(json),
      enabled: enabled,
      lastStatus: (json['last_status'] ?? json['status'])?.toString(),
      nextRun: _parseTime(json['next_run_at'] ?? json['next_run']),
      lastRun: _parseTime(json['last_run_at'] ?? json['last_run']),
    );
  }

  /// Prefer a machine-round-trippable schedule over presentation-only fields.
  /// Hermes returns structured cron, interval, and one-shot schedules alongside
  /// labels such as `once at …`; those labels are not accepted by create/edit.
  static String _parseSchedule(Map<String, dynamic> json) {
    final schedule = json['schedule'];
    if (schedule is String && schedule.trim().isNotEmpty) return schedule;
    if (schedule is Map) {
      final kind = schedule['kind']?.toString().trim().toLowerCase();
      if (kind == 'cron') {
        final expression = _nonEmptyScheduleValue(
          schedule['expr'] ?? schedule['cron'] ?? schedule['value'],
        );
        if (expression != null) return expression;
      }
      if (kind == 'interval') {
        final minutes = int.tryParse(schedule['minutes']?.toString() ?? '');
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
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    if (value is int) {
      final ms = value < 100000000000 ? value * 1000 : value;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return DateTime.tryParse(value.toString());
  }
}
