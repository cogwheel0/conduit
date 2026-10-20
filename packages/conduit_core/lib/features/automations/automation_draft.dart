import 'package:meta/meta.dart';

import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';

/// Why a draft cannot be saved yet.
enum AutomationDraftIssue {
  nameRequired,
  promptRequired,
  modelRequired,

  /// The model is not one the account can pick now. A saved id stays in the
  /// draft, but the task cannot be saved until a compatible model is chosen.
  modelUnavailable,
  channelRequired,
  channelUnavailable,
  folderUnavailable,

  /// A weekly schedule with no day, or a rule with no text.
  scheduleIncomplete,
}

/// A scheduled task being created or edited.
///
/// An edit starts from the server's task and keeps it: the form sent back
/// carries the task's whole `data` (a terminal and any key this client does not
/// model included) and its `meta`, because the server overwrites both on
/// update. A schedule the user did not change is sent exactly as stored.
@immutable
final class AutomationDraft {
  const AutomationDraft({
    required this.name,
    required this.prompt,
    required this.modelId,
    required this.schedule,
    required this.target,
    required this.isActive,
    this.folderId,
    this.original,
  });

  /// A new task. The schedule is the caller's default, such as a time a few
  /// minutes ahead.
  factory AutomationDraft.create({required AutomationSchedule schedule}) =>
      AutomationDraft(
        name: '',
        prompt: '',
        modelId: '',
        schedule: schedule,
        target: const AutomationTarget.chat(),
        isActive: true,
      );

  /// An edit of [task], with every field as the server has it.
  factory AutomationDraft.edit(Automation task) => AutomationDraft(
    name: task.name,
    prompt: task.prompt,
    modelId: task.modelId,
    schedule: AutomationSchedule.parse(task.rrule),
    target: task.target,
    isActive: task.isActive,
    folderId: task.folderId,
    original: task,
  );

  final String name;
  final String prompt;
  final String modelId;
  final AutomationSchedule schedule;
  final AutomationTarget target;
  final bool isActive;
  final String? folderId;

  /// The task being edited, or null for a new one.
  final Automation? original;

  bool get isNew => original == null;

  AutomationDraft copyWith({
    String? name,
    String? prompt,
    String? modelId,
    AutomationSchedule? schedule,
    AutomationTarget? target,
    bool? isActive,
    String? folderId,
    bool clearFolder = false,
  }) {
    // A channel result is not filed in a folder, as in Open WebUI's own form.
    final channelNow = target?.isChannel ?? false;
    return AutomationDraft(
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      modelId: modelId ?? this.modelId,
      schedule: schedule ?? this.schedule,
      target: target ?? this.target,
      isActive: isActive ?? this.isActive,
      folderId: clearFolder || channelNow ? null : (folderId ?? this.folderId),
      original: original,
    );
  }

  /// Whether the draft differs from the task it started from. A new task is
  /// always a change.
  bool get isChanged {
    final task = original;
    if (task == null) return true;
    return name.trim() != task.name.trim() ||
        prompt.trim() != task.prompt.trim() ||
        modelId.trim() != task.modelId.trim() ||
        schedule != AutomationSchedule.parse(task.rrule) ||
        target != task.target ||
        isActive != task.isActive ||
        folderId != task.folderId;
  }

  /// What stops this draft from being saved. Each set is what the account can
  /// pick right now; null means the list could not be read, so that part is
  /// left to the server instead of being refused on a guess.
  List<AutomationDraftIssue> issues({
    Set<String>? modelIds,
    Set<String>? folderIds,
    Set<String>? channelIds,
  }) {
    final schedule = this.schedule;
    final selectedChannel = target.channelId;
    final selectedFolder = folderId;
    return [
      if (name.trim().isEmpty) AutomationDraftIssue.nameRequired,
      if (prompt.trim().isEmpty) AutomationDraftIssue.promptRequired,
      if (modelId.trim().isEmpty)
        AutomationDraftIssue.modelRequired
      else if (modelIds != null && !modelIds.contains(modelId.trim()))
        AutomationDraftIssue.modelUnavailable,
      if (target.isChannel && selectedChannel == null)
        AutomationDraftIssue.channelRequired
      else if (target.isChannel &&
          channelIds != null &&
          !channelIds.contains(selectedChannel))
        AutomationDraftIssue.channelUnavailable,
      if (!target.isChannel &&
          selectedFolder != null &&
          folderIds != null &&
          !folderIds.contains(selectedFolder))
        AutomationDraftIssue.folderUnavailable,
      if ((schedule is WeeklyAutomationSchedule && schedule.days.isEmpty) ||
          (schedule is RawAutomationSchedule && schedule.rrule.trim().isEmpty))
        AutomationDraftIssue.scheduleIncomplete,
    ];
  }

  /// The form to send. It is built on the task's own `data` and `meta`, so
  /// nothing the server holds that this draft does not edit is lost.
  AutomationForm toForm() {
    final task = original;
    final data = <String, dynamic>{
      ...?task?.data,
      'prompt': prompt.trim(),
      'model_id': modelId.trim(),
      'rrule': _rrule(task),
    };
    if (task == null || target != task.target) {
      data['target'] = target.isChannel
          ? <String, dynamic>{'type': 'channel', 'channel_id': target.channelId}
          : <String, dynamic>{'type': 'chat'};
    }
    return AutomationForm(
      name: name.trim(),
      folderId: target.isChannel ? null : folderId,
      data: data,
      meta: task?.meta,
      isActive: isActive,
    );
  }

  /// The stored rule when the schedule was not changed, so a rule written in
  /// another order or spacing is not rewritten by an unrelated edit.
  String _rrule(Automation? task) {
    if (task != null && schedule == AutomationSchedule.parse(task.rrule)) {
      return task.rrule;
    }
    return schedule.toRrule();
  }
}
