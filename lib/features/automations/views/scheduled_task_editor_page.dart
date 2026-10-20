import 'dart:async';
import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/automation_destinations.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/discard_changes.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../../shared/widgets/adaptive_date_time_picker.dart';
import '../../../shared/widgets/editor_form_widgets.dart';
import '../../profile/widgets/adaptive_segmented_selector.dart';
import 'scheduled_task_format.dart';
import 'scheduled_tasks_page.dart';

/// An example rule shown in the empty recurrence rule field.
const _rruleExample = 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0';

typedef _Options = ({
  List<Model>? models,
  List<Channel>? channels,
  Map<String, AutomationChannelAccess> access,
  List<({String id, String name})>? folders,
});

typedef _Option = ({String id, String label, String? subtitle});

/// Creates a scheduled task, or edits the one named by [taskId].
///
/// The editor holds the account it was opened for and sends for that account
/// only. A refused save, including one for another account, leaves every
/// field as typed. Nothing is scheduled on this device: saving asks the server,
/// which decides when each run happens.
class ScheduledTaskEditorPage extends StatelessWidget {
  const ScheduledTaskEditorPage({super.key, this.taskId});

  final String? taskId;

  @override
  Widget build(BuildContext context) =>
      ScheduledTasksGate(child: _Editor(taskId: taskId));
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({required this.taskId});

  final String? taskId;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  late final AutomationsOwner? _owner;
  AutomationDraft? _draft;

  /// A new task's draft as the editor opened it, to tell whether anything was
  /// entered. An edit compares against the task itself.
  AutomationDraft? _start;
  Object? _loadError;
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  final _rrule = TextEditingController();
  bool _advancedOpen = false;
  bool _saving = false;

  /// Set by the first Save. From then on every issue shows on its field and
  /// updates as the user edits.
  bool _attempted = false;

  /// Set as a saved editor leaves, so leaving does not ask about discarding.
  bool _saved = false;

  /// What the server or the account said, as opposed to a field's own issue.
  String? _error;

  Automations get _notifier => ref.read(automationsProvider.notifier);

  @override
  void initState() {
    super.initState();
    _owner = _notifier.captureOwner();
    if (widget.taskId == null) {
      final draft = AutomationDraft.create(
        schedule: const DailyAutomationSchedule(hour: 9, minute: 0),
      );
      _start = draft;
      _adopt(draft);
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _rrule.dispose();
    super.dispose();
  }

  void _adopt(AutomationDraft draft) {
    _draft = draft;
    _name.text = draft.name;
    _prompt.text = draft.prompt;
    _rrule.text = draft.schedule.toRrule();
  }

  Future<void> _load() async {
    final owner = _owner;
    final id = widget.taskId;
    if (owner == null || id == null) {
      setState(() => _loadError = AutomationsOwnerChangedException());
      return;
    }
    setState(() => _loadError = null);
    try {
      final task = await _notifier.fetch(id, owner: owner);
      // The read refuses an answer for an account that is gone, but this also
      // covers the account changing between that check and this line.
      _requireOwner(owner);
      setState(() => _adopt(AutomationDraft.edit(task)));
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    }
  }

  /// Throws unless this editor is still showing and [owner] is still the
  /// signed-in account. Anything that finished for another account must not
  /// touch the form or leave the page.
  void _requireOwner(AutomationsOwner owner) {
    if (!mounted || !_notifier.isCurrentOwner(owner)) {
      throw AutomationsOwnerChangedException();
    }
  }

  /// Whether leaving now would lose something the user entered.
  bool get _dirty {
    final draft = _draft;
    if (draft == null || _saved) return false;
    final start = _start;
    if (start == null) return draft.isChanged;
    return draft.name != start.name ||
        draft.prompt != start.prompt ||
        draft.modelId != start.modelId ||
        draft.schedule != start.schedule ||
        draft.target != start.target ||
        draft.isActive != start.isActive ||
        draft.folderId != start.folderId;
  }

  void _update(AutomationDraft draft) => setState(() {
    _draft = draft;
    _error = null;
  });

  void _setSchedule(AutomationSchedule schedule) {
    final draft = _draft;
    if (draft == null) return;
    _rrule.text = schedule.toRrule();
    _update(draft.copyWith(schedule: schedule));
  }

  void _setTarget(bool isChannel) {
    final draft = _draft;
    if (draft == null || draft.target.isChannel == isChannel) return;
    _update(
      draft.copyWith(
        target: isChannel
            ? const AutomationTarget.channelPending()
            : const AutomationTarget.chat(),
      ),
    );
  }

  // The values the account can pick now, or null while a list has not loaded,
  // in which case the server decides instead of a guess here.
  _Options _options() {
    final models = ref
        .watch(modelsProvider)
        .asData
        ?.value
        .where(automationModelSelectable)
        .toList();
    final channelList = ref.watch(channelsListProvider).asData?.value;
    final user = ref.watch(currentUserProvider2);
    final permissions =
        ref.watch(userPermissionsProvider).asData?.value ??
        const <String, dynamic>{};
    final enabled = ref.watch(channelsFeatureEnabledProvider);
    final access = {
      for (final channel in channelList ?? const <Channel>[])
        channel.id: automationChannelAccess(
          channel,
          user: user,
          channelsEnabled: enabled,
          permissions: permissions,
        ),
    };
    final folders = ref.watch(foldersProvider).asData?.value;
    return (
      models: models,
      channels: channelList
          ?.where((c) => access[c.id] != AutomationChannelAccess.unavailable)
          .toList(),
      access: access,
      folders: folders == null
          ? null
          : [
              for (final f in automationFolderOptions(folders))
                (id: f.id, name: f.name),
            ],
    );
  }

  List<AutomationDraftIssue> _issues(AutomationDraft draft, _Options options) =>
      draft.issues(
        modelIds: options.models == null
            ? null
            : {for (final m in options.models!) m.id},
        folderIds: options.folders == null
            ? null
            : {for (final f in options.folders!) f.id},
        channelIds: options.channels == null
            ? null
            : {for (final c in options.channels!) c.id},
      );

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || _saving) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final l10n = AppLocalizations.of(context)!;
    final issues = _issues(draft, _options());
    if (issues.isNotEmpty) {
      setState(() {
        _attempted = true;
        _error = null;
        // A custom rule's issue shows on the rule, so open it.
        if (draft.schedule is RawAutomationSchedule &&
            issues.contains(AutomationDraftIssue.scheduleIncomplete)) {
          _advancedOpen = true;
        }
      });
      return;
    }
    final owner = _owner;
    if (owner == null) {
      setState(() => _error = l10n.scheduledTasksAccountChanged);
      return;
    }
    final route = ModalRoute.of(context);
    setState(() {
      _attempted = true;
      _saving = true;
      _error = null;
    });
    try {
      if (draft.isNew) {
        final created = await _notifier.create(draft.toForm(), owner: owner);
        // A save that was accepted for the previous account stays accepted.
        // It must not take this editor to that task's page, so the form stays
        // as typed and the account notice shows.
        _requireOwner(owner);
        _confirmSaved();
        if (!mounted) return;
        if (route?.isCurrent ?? true) {
          _saved = true;
          context.pushReplacementNamed(
            RouteNames.scheduledTaskDetail,
            pathParameters: {'id': created.id},
          );
        } else {
          // A page opened over the form while the save ran stays. The form
          // now edits the task it created, so another Save updates that task
          // instead of creating a second one.
          setState(() {
            _start = null;
            _adopt(AutomationDraft.edit(created));
          });
        }
      } else {
        final updated = await _notifier.updateTask(
          draft.original!.id,
          draft.toForm(),
          owner: owner,
        );
        _requireOwner(owner);
        _confirmSaved();
        if (!mounted) return;
        // Pop only this editor, not a page opened over it while the save ran.
        if (route?.isCurrent ?? true) {
          _saved = true;
          context.pop();
        } else {
          // The form stays and now matches what the server holds.
          setState(() => _adopt(AutomationDraft.edit(updated)));
        }
      }
    } catch (error) {
      // The form keeps everything that was typed, whatever the reason.
      if (mounted) {
        setState(
          () => _error = scheduledTaskErrorText(
            l10n,
            error,
            fallback: l10n.scheduledTaskSaveFailed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _confirmSaved() {
    // A pressed ConduitButton already gave its own feedback; the iOS toolbar
    // button gives none, so the save is confirmed there.
    if (PlatformInfo.isIOS) unawaited(ConduitHaptics.success());
  }

  Future<void> _cancel() async {
    if (_dirty && !await confirmDiscardChanges(context)) return;
    if (!mounted) return;
    setState(() => _saved = true);
    Navigator.of(context).pop();
  }

  // A choice lands on the draft as it is when the choice is made, not as it was
  // when the picker opened: the form stays editable while a pick is pending.
  Future<void> _pickModel(List<Model> models) async {
    final current = _draft;
    if (current == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(
      title: l10n.scheduledTaskModelLabel,
      searchHint: l10n.searchModels,
      selectedId: current.modelId.trim(),
      options: [
        for (final m in models) (id: m.id, label: m.name, subtitle: m.id),
      ],
    );
    final draft = _draft;
    if (picked != null && draft != null) {
      _update(draft.copyWith(modelId: picked));
    }
  }

  Future<void> _pickFolder(List<({String id, String name})> folders) async {
    final current = _draft;
    if (current == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(
      title: l10n.scheduledTaskFolderLabel,
      searchHint: l10n.scheduledTaskFolderSearchHint,
      selectedId: current.folderId ?? '',
      options: [
        (id: '', label: l10n.scheduledTaskFolderNone, subtitle: null),
        for (final f in folders) (id: f.id, label: f.name, subtitle: null),
      ],
    );
    final draft = _draft;
    if (picked == null || draft == null) return;
    _update(
      picked.isEmpty
          ? draft.copyWith(clearFolder: true)
          : draft.copyWith(folderId: picked),
    );
  }

  Future<void> _pickChannel(
    List<Channel> channels,
    Map<String, AutomationChannelAccess> access,
  ) async {
    final owner = _owner;
    final current = _draft;
    if (current == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(
      title: l10n.scheduledTaskDestinationChannel,
      searchHint: l10n.searchChannels,
      selectedId: current.target.channelId,
      options: [
        for (final c in channels) (id: c.id, label: '#${c.name}', subtitle: null),
      ],
    );
    if (picked == null) return;
    if (access[picked] == AutomationChannelAccess.needsWriteReadBack) {
      // The channel list does not say whether the account may post, so ask
      // the channel itself, for the account this editor was opened for.
      try {
        if (owner == null) throw AutomationsOwnerChangedException();
        final writable = await _notifier.channelWritable(picked, owner: owner);
        _requireOwner(owner);
        if (!writable) {
          setState(() => _error = l10n.scheduledTaskChannelNoWrite);
          return;
        }
      } catch (error) {
        if (mounted) {
          setState(
            () => _error = scheduledTaskErrorText(
              l10n,
              error,
              fallback: l10n.scheduledTaskSaveFailed,
            ),
          );
        }
        return;
      }
    }
    // The write check took a round trip, during which the form stayed live, so
    // the channel goes onto what is typed now. A user who switched the
    // destination back to chat meanwhile is not sent to the channel anyway.
    final draft = _draft;
    if (!mounted || draft == null || !draft.target.isChannel) return;
    _update(draft.copyWith(target: AutomationTarget.channel(picked)));
  }

  /// The option the user chose, or null when they dismissed the sheet or the
  /// account changed while it was open. The choices came from the account the
  /// sheet opened for, so none is carried into the form afterwards.
  Future<String?> _pick({
    required String title,
    required String searchHint,
    required String? selectedId,
    required List<_Option> options,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await showAdaptiveSelectionSheet<String>(
      context: context,
      builder: (_) => _OptionSheet(
        title: title,
        searchHint: searchHint,
        selectedId: selectedId,
        options: options,
      ),
    );
    if (!mounted || picked == null) return null;
    final owner = _owner;
    if (owner == null || !_notifier.isCurrentOwner(owner)) {
      setState(
        () =>
            _error = AppLocalizations.of(context)!.scheduledTasksAccountChanged,
      );
      return null;
    }
    return picked;
  }

  Future<void> _pickTime(int hour, int minute) async {
    final picked = await showAdaptiveTimePicker(
      context,
      initial: TimeOfDay(hour: hour, minute: minute),
    );
    final draft = _draft;
    if (picked == null || draft == null) return;
    _setSchedule(switch (draft.schedule) {
      final OnceAutomationSchedule once => OnceAutomationSchedule(
        year: once.year,
        month: once.month,
        day: once.day,
        hour: picked.hour,
        minute: picked.minute,
      ),
      final WeeklyAutomationSchedule weekly => WeeklyAutomationSchedule(
        hour: picked.hour,
        minute: picked.minute,
        days: weekly.days,
      ),
      _ => DailyAutomationSchedule(hour: picked.hour, minute: picked.minute),
    });
  }

  Future<void> _pickDate(OnceAutomationSchedule once) async {
    final today = DateUtils.dateOnly(DateTime.now());
    final current = DateUtils.dateOnly(once.wallClock);
    final picked = await showAdaptiveDatePicker(
      context,
      initial: current,
      first: current.isBefore(today) ? current : today,
      last: today.add(const Duration(days: 365 * 5)),
    );
    if (picked == null) return;
    _setSchedule(
      OnceAutomationSchedule(
        year: picked.year,
        month: picked.month,
        day: picked.day,
        hour: once.hour,
        minute: once.minute,
      ),
    );
  }

  /// Starts a control schedule of [kind], keeping the time of day when there
  /// is one. This is the explicit change that replaces a rule the controls
  /// could not edit.
  void _chooseKind(String kind) {
    final schedule = _draft?.schedule;
    final (hour, minute) = switch (schedule) {
      OnceAutomationSchedule(:final hour, :final minute) => (hour, minute),
      DailyAutomationSchedule(:final hour, :final minute) => (hour, minute),
      WeeklyAutomationSchedule(:final hour, :final minute) => (hour, minute),
      _ => (9, 0),
    };
    final now = DateTime.now();
    _setSchedule(switch (kind) {
      'once' => OnceAutomationSchedule.fromDateTime(
        now.add(const Duration(minutes: 5)),
      ),
      'weekly' => WeeklyAutomationSchedule(
        hour: hour,
        minute: minute,
        days: {AutomationSchedule.weekdayCodes[now.weekday - 1]},
      ),
      _ => DailyAutomationSchedule(hour: hour, minute: minute),
    });
  }

  void _toggleDay(WeeklyAutomationSchedule schedule, String code) {
    _setSchedule(
      WeeklyAutomationSchedule(
        hour: schedule.hour,
        minute: schedule.minute,
        days: schedule.days.contains(code)
            ? ({...schedule.days}..remove(code))
            : {...schedule.days, code},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final draft = _draft;
    if (draft == null) {
      return UtilityPageScaffold.settings(
        title: l10n.scheduledTaskEditTitle,
        children: [
          if (_loadError case final error?) ...[
            Text(
              scheduledTaskErrorText(
                l10n,
                error,
                fallback: l10n.scheduledTasksLoadFailed,
              ),
              key: const Key('scheduled-task-load-error'),
            ),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              key: const Key('scheduled-task-retry'),
              text: l10n.retry,
              onPressed: _load,
            ),
          ] else
            const Center(child: ConduitLoadingIndicator(isCompact: true)),
        ],
      );
    }

    final theme = context.conduitTheme;
    final options = _options();
    final issues = _attempted
        ? _issues(draft, options)
        : const <AutomationDraftIssue>[];
    String? issue(Set<AutomationDraftIssue> kinds) {
      for (final found in issues) {
        if (kinds.contains(found)) return automationIssueText(l10n, found);
      }
      return null;
    }

    final modelIssue = issue(const {
      AutomationDraftIssue.modelRequired,
      AutomationDraftIssue.modelUnavailable,
    });
    final canSave = !_saving && draft.isChanged;
    return DiscardChangesScope(
      dirty: _dirty,
      child: UtilityPageScaffold.settings(
        title: draft.isNew
            ? l10n.scheduledTaskNewTitle
            : l10n.scheduledTaskEditTitle,
        trailing: PlatformInfo.isIOS
            ? CupertinoButton(
                key: const Key('scheduled-task-save'),
                padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                minimumSize: const Size(0, TouchTarget.minimum),
                onPressed: canSave ? _save : null,
                child: _saving
                    ? const ConduitLoadingIndicator(
                        size: IconSize.small,
                        isCompact: true,
                      )
                    : Text(l10n.save),
              )
            : null,
        children: [
          if (_error case final message?) ...[
            UtilityStatusBanner(
              key: const Key('scheduled-task-error'),
              message: message,
              tone: UtilityStatusTone.error,
            ),
            const SizedBox(height: Spacing.md),
          ],
          InsetGroupedList(
            useNativeSurface: PlatformInfo.isIOS,
            children: [
              editorGroupField(
                AccessibleFormField(
                  key: const Key('scheduled-task-name'),
                  controller: _name,
                  label: l10n.scheduledTaskNameLabel,
                  enabled: !_saving,
                  isRequired: true,
                  iosSettingsRow: PlatformInfo.isIOS,
                  textInputAction: TextInputAction.next,
                  errorText: issue(const {AutomationDraftIssue.nameRequired}),
                  onChanged: (value) =>
                      _update(_draft!.copyWith(name: value)),
                ),
              ),
              UtilityRow(
                title: l10n.scheduledTaskActiveLabel,
                titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
                trailing: AdaptiveSwitch(
                  key: const Key('scheduled-task-active'),
                  value: draft.isActive,
                  semanticLabel: l10n.scheduledTaskActiveLabel,
                  onChanged: _saving
                      ? null
                      : (value) =>
                            _update(_draft!.copyWith(isActive: value)),
                ),
                preserveTrailingSemantics: true,
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          AccessibleFormField(
            key: const Key('scheduled-task-prompt'),
            controller: _prompt,
            label: l10n.scheduledTaskPromptLabel,
            hint: l10n.scheduledTaskPromptHint,
            minLines: 4,
            maxLines: 10,
            enabled: !_saving,
            isRequired: true,
            errorText: issue(const {AutomationDraftIssue.promptRequired}),
            onChanged: (value) => _update(_draft!.copyWith(prompt: value)),
          ),
          const SizedBox(height: Spacing.lg),
          InsetGroupedList(
            useNativeSurface: PlatformInfo.isIOS,
            children: [
              UtilityRow(
                key: const Key('scheduled-task-model'),
                title: l10n.scheduledTaskModelLabel,
                titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
                subtitle: modelIssue ?? _modelLabel(l10n, draft, options.models),
                foregroundColor: modelIssue == null ? null : theme.error,
                showChevron: true,
                onTap: _saving || options.models == null
                    ? null
                    : () => _pickModel(options.models!),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          ..._schedule(
            context,
            l10n,
            draft,
            issue(const {AutomationDraftIssue.scheduleIncomplete}),
          ),
          const SizedBox(height: Spacing.lg),
          ..._destination(context, l10n, draft, options, issue),
          if (draft.original?.terminal != null) ...[
            const SizedBox(height: Spacing.md),
            Text(
              l10n.scheduledTaskTerminalKept,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ],
          if (!PlatformInfo.isIOS) ...[
            const SizedBox(height: Spacing.lg),
            Row(
              children: [
                Expanded(
                  child: ConduitButton(
                    key: const Key('scheduled-task-cancel'),
                    text: l10n.cancel,
                    isSecondary: true,
                    onPressed: _saving ? null : _cancel,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: ConduitButton(
                    key: const Key('scheduled-task-save'),
                    text: l10n.save,
                    isLoading: _saving,
                    onPressed: canSave ? _save : null,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _modelLabel(
    AppLocalizations l10n,
    AutomationDraft draft,
    List<Model>? models,
  ) {
    final id = draft.modelId.trim();
    if (id.isEmpty) return l10n.scheduledTaskModelChoose;
    final match = models?.where((m) => m.id == id).firstOrNull;
    if (match != null) return match.name;
    // A saved id the account cannot pick now stays visible and is not saved
    // again until a compatible model is chosen.
    return models == null ? id : l10n.scheduledTaskModelUnavailable(id);
  }

  List<Widget> _schedule(
    BuildContext context,
    AppLocalizations l10n,
    AutomationDraft draft,
    String? scheduleIssue,
  ) {
    final schedule = draft.schedule;
    final selected = switch (schedule) {
      OnceAutomationSchedule() => 'once',
      DailyAutomationSchedule() => 'daily',
      WeeklyAutomationSchedule() => 'weekly',
      // No segment is selected for a rule the controls cannot edit.
      RawAutomationSchedule() => 'custom',
    };
    final (hour, minute) = switch (schedule) {
      OnceAutomationSchedule(:final hour, :final minute) => (hour, minute),
      DailyAutomationSchedule(:final hour, :final minute) => (hour, minute),
      WeeklyAutomationSchedule(:final hour, :final minute) => (hour, minute),
      RawAutomationSchedule() => (null, null),
    };
    final typed = AutomationSchedule.parse(_rrule.text);
    final runs = typed is RawAutomationSchedule
        ? l10n.scheduledTaskScheduleCustom
        : scheduleSummary(context, l10n, typed);
    return [
      InsetGroupedList(
        title: l10n.scheduledTaskScheduleLabel,
        footer: l10n.scheduledTaskTimezoneNote,
        useNativeSurface: PlatformInfo.isIOS,
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: KeyedSubtree(
              key: const Key('scheduled-task-kind'),
              // Held still while saving rather than disabled, which would
              // clear the selection on screen.
              child: IgnorePointer(
                ignoring: _saving,
                child: SizedBox(
                  width: double.infinity,
                  child: AdaptiveSegmentedSelector<String>(
                    value: selected,
                    showIcons: false,
                    onChanged: _chooseKind,
                    options: [
                      for (final (kind, label) in [
                        ('once', l10n.scheduledTaskScheduleOnce),
                        ('daily', l10n.scheduledTaskScheduleDaily),
                        ('weekly', l10n.scheduledTaskScheduleWeekly),
                      ])
                        (
                          value: kind,
                          label: label,
                          cupertinoIcon: CupertinoIcons.calendar,
                          materialIcon: Icons.event_outlined,
                          enabled: true,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (schedule is RawAutomationSchedule)
            UtilityRow(
              key: const Key('scheduled-task-raw-summary'),
              title: scheduleSummary(context, l10n, schedule),
              subtitle: l10n.scheduledTaskRruleKept,
              subtitleMaxLines: 4,
            ),
          if (schedule is OnceAutomationSchedule)
            UtilityRow(
              key: const Key('scheduled-task-date'),
              title: l10n.scheduledTaskDateLabel,
              subtitle: MaterialLocalizations.of(
                context,
              ).formatMediumDate(schedule.wallClock),
              showChevron: true,
              onTap: _saving ? null : () => _pickDate(schedule),
            ),
          if (hour != null && minute != null)
            UtilityRow(
              key: const Key('scheduled-task-time'),
              title: l10n.scheduledTaskTimeLabel,
              subtitle: formatWallClockTime(context, hour, minute),
              showChevron: true,
              onTap: _saving ? null : () => _pickTime(hour, minute),
            ),
          if (schedule is WeeklyAutomationSchedule)
            Padding(
              padding: const EdgeInsets.all(Spacing.md),
              child: _WeekdayPicker(
                days: schedule.days,
                enabled: !_saving,
                errorText: scheduleIssue,
                onToggle: (code) => _toggleDay(schedule, code),
              ),
            ),
        ],
      ),
      const SizedBox(height: Spacing.md),
      UtilityDisclosureSection(
        key: const Key('scheduled-task-advanced'),
        title: l10n.scheduledTaskAdvancedSchedule,
        expanded: _advancedOpen,
        useNativeSurface: PlatformInfo.isIOS,
        onChanged: (open) => setState(() => _advancedOpen = open),
        child: CodeEntryField(
          key: const Key('scheduled-task-rrule'),
          controller: _rrule,
          label: l10n.scheduledTaskRruleLabel,
          hint: _rruleExample,
          helperText: l10n.scheduledTaskRruleRuns(runs),
          errorText: schedule is RawAutomationSchedule ? scheduleIssue : null,
          minLines: 2,
          maxLines: 4,
          enabled: !_saving,
          onChanged: (value) => _update(
            _draft!.copyWith(schedule: AutomationSchedule.parse(value)),
          ),
        ),
      ),
    ];
  }

  List<Widget> _destination(
    BuildContext context,
    AppLocalizations l10n,
    AutomationDraft draft,
    _Options options,
    String? Function(Set<AutomationDraftIssue>) issue,
  ) {
    final theme = context.conduitTheme;
    final channels = options.channels;
    final folders = options.folders;
    final channelId = draft.target.channelId;
    final channelName = channels?.where((c) => c.id == channelId).firstOrNull;
    final folderId = draft.folderId;
    final folder = folders?.where((f) => f.id == folderId).firstOrNull;
    final channelIssue = issue(const {
      AutomationDraftIssue.channelRequired,
      AutomationDraftIssue.channelUnavailable,
    });
    final folderIssue = issue(const {AutomationDraftIssue.folderUnavailable});
    return [
      InsetGroupedList(
        title: l10n.scheduledTaskDestinationLabel,
        useNativeSurface: PlatformInfo.isIOS,
        children: [
          Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: KeyedSubtree(
              key: const Key('scheduled-task-target'),
              // Held still while saving rather than disabled, which would
              // clear the selection on screen.
              child: IgnorePointer(
                ignoring: _saving,
                child: SizedBox(
                  width: double.infinity,
                  child: AdaptiveSegmentedSelector<bool>(
                    value: draft.target.isChannel,
                    showIcons: false,
                    onChanged: _setTarget,
                    options: [
                      (
                        value: false,
                        label: l10n.scheduledTaskDestinationChat,
                        cupertinoIcon: CupertinoIcons.chat_bubble,
                        materialIcon: Icons.chat_bubble_outline,
                        enabled: true,
                      ),
                      (
                        value: true,
                        label: l10n.scheduledTaskDestinationChannel,
                        cupertinoIcon: CupertinoIcons.number,
                        materialIcon: Icons.tag,
                        enabled: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (draft.target.isChannel)
            UtilityRow(
              key: const Key('scheduled-task-channel'),
              title: l10n.scheduledTaskDestinationChannel,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              subtitle:
                  channelIssue ??
                  (channelId == null
                      ? l10n.scheduledTaskChannelChoose
                      : channelName != null
                      ? '#${channelName.name}'
                      : channels == null
                      ? channelId
                      : l10n.scheduledTaskChannelUnavailable),
              foregroundColor: channelIssue == null ? null : theme.error,
              showChevron: true,
              onTap: _saving || channels == null
                  ? null
                  : () => _pickChannel(channels, options.access),
            )
          else
            UtilityRow(
              key: const Key('scheduled-task-folder'),
              title: l10n.scheduledTaskFolderLabel,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              subtitle:
                  folderIssue ??
                  (folderId == null
                      ? l10n.scheduledTaskFolderNone
                      : folder != null
                      ? folder.name
                      : folders == null
                      ? folderId
                      : l10n.scheduledTaskFolderUnavailable),
              foregroundColor: folderIssue == null ? null : theme.error,
              showChevron: true,
              onTap: _saving || folders == null
                  ? null
                  : () => _pickFolder(folders),
            ),
        ],
      ),
    ];
  }
}

/// Seven equal toggles, Monday first, for the days a weekly task runs.
class _WeekdayPicker extends StatelessWidget {
  const _WeekdayPicker({
    required this.days,
    required this.enabled,
    required this.onToggle,
    this.errorText,
  });

  final Set<String> days;
  final bool enabled;
  final ValueChanged<String> onToggle;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final locale = Localizations.localeOf(context).toString();
    final codes = AutomationSchedule.weekdayCodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            l10n.scheduledTaskDaysLabel,
            style: theme.label?.copyWith(color: theme.textSecondary),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Row(
          children: [
            for (var index = 0; index < codes.length; index++) ...[
              if (index > 0) const SizedBox(width: Spacing.xs),
              Expanded(
                child: _DayToggle(
                  key: Key('scheduled-task-day-${codes[index]}'),
                  label: weekdayLabel(context, codes[index]),
                  // 1 January 2024 was a Monday.
                  fullName: DateFormat.EEEE(
                    locale,
                  ).format(DateTime(2024, 1, 1 + index)),
                  selected: days.contains(codes[index]),
                  enabled: enabled,
                  onTap: () => onToggle(codes[index]),
                ),
              ),
            ],
          ],
        ),
        if (errorText case final error?) ...[
          const SizedBox(height: Spacing.xs),
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: theme.bodySmall?.copyWith(color: theme.error),
            ),
          ),
        ],
      ],
    );
  }
}

class _DayToggle extends StatelessWidget {
  const _DayToggle({
    super.key,
    required this.label,
    required this.fullName,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String fullName;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    void toggle() {
      ConduitHaptics.selectionClick();
      onTap();
    }

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: fullName,
      onTap: enabled ? toggle : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? toggle : null,
        child: AnimatedContainer(
          duration: context.motionDuration(AnimationDuration.microInteraction),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: TouchTarget.minimum),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xxs),
          decoration: BoxDecoration(
            color: selected ? theme.buttonPrimary : theme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBorderRadius.md),
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: AppTypography.bodySmallStyle.copyWith(
                  color: selected ? theme.buttonPrimaryText : theme.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A searchable single-choice sheet. Pops the chosen option's id.
class _OptionSheet extends StatefulWidget {
  const _OptionSheet({
    required this.title,
    required this.searchHint,
    required this.selectedId,
    required this.options,
  });

  final String title;
  final String searchHint;
  final String? selectedId;
  final List<_Option> options;

  @override
  State<_OptionSheet> createState() => _OptionSheetState();
}

class _OptionSheetState extends State<_OptionSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final needle = _query.trim().toLowerCase();
    final shown = [
      for (final option in widget.options)
        if (needle.isEmpty ||
            option.label.toLowerCase().contains(needle) ||
            (option.subtitle?.toLowerCase().contains(needle) ?? false))
          option,
    ];
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // ThemedSheets.showCustom adds no view inset, so the sheet lifts itself
    // above the software keyboard, and gives up the same height so the search
    // field and the results scroll in what is left. The system strips the
    // home-indicator inset while the keyboard is up, so the safe area below
    // does not pad twice.
    final maxHeight = math.min(
      media.size.height * 0.8,
      media.size.height - keyboard - media.padding.top,
    );
    return AnimatedPadding(
      duration: context.motionDuration(AnimationDuration.fast),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      // The native iOS 26 sheet route supplies Flutter's own Material, which
      // material_ui's text field and rows do not see.
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: theme.sidebarBackground,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppBorderRadius.modal),
            ),
            boxShadow: ConduitShadows.modal(context),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Spacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      widget.title,
                      style: theme.headingSmall?.copyWith(
                        color: theme.sidebarForeground,
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  ConduitInput(
                    key: const Key('scheduled-task-option-search'),
                    hint: widget.searchHint,
                    semanticLabel: widget.searchHint,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: Spacing.sm),
                  if (shown.isEmpty)
                    Padding(
                      key: const Key('scheduled-task-option-empty'),
                      padding: const EdgeInsets.symmetric(
                        vertical: Spacing.lg,
                      ),
                      child: Center(
                        child: Text(
                          l10n.noResults,
                          style: theme.bodyMedium?.copyWith(
                            color: theme.textSecondary,
                          ),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final option in shown)
                            AdaptiveSelectionTile(
                              key: Key('scheduled-task-option-${option.id}'),
                              title: option.label,
                              subtitle: option.subtitle,
                              selected: option.id == widget.selectedId,
                              onTap: () => Navigator.of(context).pop(option.id),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
