import '../../../core/utils/unicode_prefix.dart';
import '../services/hermes_identifier.dart';
import '../utils/hermes_time_parsing.dart';

const int kMaxHermesJobNameCharacters = 200;
const int kMaxHermesJobPromptCharacters = 5000;
const int kMaxHermesJobScheduleCharacters = 2048;
const int kMaxHermesJobStatusCharacters = 256;

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
  final DateTime? nextRun;
  final DateTime? lastRun;

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
      nextRun: parseHermesTimestamp(json['next_run_at'] ?? json['next_run']),
      lastRun: parseHermesTimestamp(json['last_run_at'] ?? json['last_run']),
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
