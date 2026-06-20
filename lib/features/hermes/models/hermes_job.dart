/// A Hermes scheduled job (`/api/jobs/*`): a prompt run on a cron schedule.
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

  /// Cron expression for the schedule.
  final String schedule;

  /// Best label for the job: name, else a prompt preview.
  String get displayName {
    if (name != null && name!.trim().isNotEmpty) return name!.trim();
    if (prompt.trim().isEmpty) return '(no prompt)';
    final oneLine = prompt.trim().replaceAll(RegExp(r'\s+'), ' ');
    return oneLine.length <= 80 ? oneLine : '${oneLine.substring(0, 80)}…';
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

  /// The schedule can be a bare cron string or an object
  /// `{kind, expr, display}`, with a sibling `schedule_display`.
  static String _parseSchedule(Map<String, dynamic> json) {
    final display = json['schedule_display'];
    if (display is String && display.isNotEmpty) return display;
    final schedule = json['schedule'];
    if (schedule is String) return schedule;
    if (schedule is Map) {
      final v = schedule['display'] ?? schedule['expr'] ?? schedule['cron'];
      if (v != null) return v.toString();
    }
    return (json['cron'] ?? '').toString();
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
