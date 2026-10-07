import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import 'scheduled_task_format.dart';
import 'scheduled_tasks_page.dart';

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
  Object? _loadError;
  final _name = TextEditingController();
  final _prompt = TextEditingController();
  final _rrule = TextEditingController();
  bool _advancedOpen = false;
  bool _saving = false;
  String? _error;

  Automations get _notifier => ref.read(automationsProvider.notifier);

  @override
  void initState() {
    super.initState();
    _owner = _notifier.captureOwner();
    if (widget.taskId == null) {
      _adopt(
        AutomationDraft.create(
          schedule: const DailyAutomationSchedule(hour: 9, minute: 0),
        ),
      );
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

  // The values the account can pick now, or null while a list has not loaded,
  // in which case the server decides instead of a guess here.
  ({
    List<Model>? models,
    List<Channel>? channels,
    Map<String, AutomationChannelAccess> access,
    List<({String id, String name})>? folders,
  })
  _options() {
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

  Future<void> _save() async {
    final draft = _draft;
    if (draft == null || _saving) return;
    final l10n = AppLocalizations.of(context)!;
    final options = _options();
    final issues = draft.issues(
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
    if (issues.isNotEmpty) {
      setState(() => _error = automationIssueText(l10n, issues.first));
      return;
    }
    final owner = _owner;
    if (owner == null) {
      setState(() => _error = l10n.scheduledTasksAccountChanged);
      return;
    }
    final route = ModalRoute.of(context);
    setState(() {
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
        if (mounted && (route?.isCurrent ?? true)) {
          context.pushReplacementNamed(
            RouteNames.scheduledTaskDetail,
            pathParameters: {'id': created.id},
          );
        }
      } else {
        await _notifier.updateTask(
          draft.original!.id,
          draft.toForm(),
          owner: owner,
        );
        _requireOwner(owner);
        // Pop only this editor, not a page opened over it while the save ran.
        if (mounted && (route?.isCurrent ?? true)) context.pop();
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

  // A choice lands on the draft as it is when the choice is made, not as it was
  // when the picker opened: the form stays editable while a pick is pending.
  Future<void> _pickModel(List<Model> models) async {
    if (_draft == null) return;
    final picked = await _pick(
      AppLocalizations.of(context)!.scheduledTaskModelLabel,
      [for (final m in models) (id: m.id, label: m.name, subtitle: m.id)],
    );
    final draft = _draft;
    if (picked != null && draft != null) {
      _update(draft.copyWith(modelId: picked));
    }
  }

  Future<void> _pickFolder(List<({String id, String name})> folders) async {
    if (_draft == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(l10n.scheduledTaskFolderLabel, [
      (id: '', label: l10n.scheduledTaskFolderNone, subtitle: null),
      for (final f in folders) (id: f.id, label: f.name, subtitle: null),
    ]);
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
    if (_draft == null) return;
    final l10n = AppLocalizations.of(context)!;
    final picked = await _pick(l10n.scheduledTaskDestinationChannel, [
      for (final c in channels)
        (id: c.id, label: '#${c.name}', subtitle: null as String?),
    ]);
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
  Future<String?> _pick(
    String title,
    List<({String id, String label, String? subtitle})> options,
  ) async {
    final picked = await showAdaptiveSelectionSheet<String>(
      context: context,
      builder: (_) => _OptionSheet(title: title, options: options),
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
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: hour, minute: minute),
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
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: current.isBefore(today) ? current : today,
      lastDate: today.add(const Duration(days: 365 * 5)),
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
    return UtilityPageScaffold.settings(
      title: draft.isNew
          ? l10n.scheduledTaskNewTitle
          : l10n.scheduledTaskEditTitle,
      children: [
        ConduitInput(
          key: const Key('scheduled-task-name'),
          controller: _name,
          label: l10n.scheduledTaskNameLabel,
          enabled: !_saving,
          onChanged: (value) => _update(draft.copyWith(name: value)),
        ),
        const SizedBox(height: Spacing.md),
        ConduitInput(
          key: const Key('scheduled-task-prompt'),
          controller: _prompt,
          label: l10n.scheduledTaskPromptLabel,
          hint: l10n.scheduledTaskPromptHint,
          minLines: 4,
          maxLines: 10,
          enabled: !_saving,
          onChanged: (value) => _update(draft.copyWith(prompt: value)),
        ),
        const SizedBox(height: Spacing.md),
        InsetGroupedList(
          children: [
            UtilityRow(
              key: const Key('scheduled-task-model'),
              title: l10n.scheduledTaskModelLabel,
              subtitle: _modelLabel(l10n, draft, options.models),
              showChevron: true,
              onTap: _saving || options.models == null
                  ? null
                  : () => _pickModel(options.models!),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        ..._schedule(context, l10n, draft),
        const SizedBox(height: Spacing.lg),
        InsetGroupedList(
          children: [
            UtilityRow(
              title: l10n.scheduledTaskActiveLabel,
              trailing: AdaptiveSwitch(
                key: const Key('scheduled-task-active'),
                value: draft.isActive,
                semanticLabel: l10n.scheduledTaskActiveLabel,
                onChanged: _saving
                    ? null
                    : (value) => _update(draft.copyWith(isActive: value)),
              ),
              preserveTrailingSemantics: true,
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        ..._destination(context, l10n, draft, options),
        if (draft.original?.terminal != null) ...[
          const SizedBox(height: Spacing.md),
          Text(
            l10n.scheduledTaskTerminalKept,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ],
        if (_error case final message?) ...[
          const SizedBox(height: Spacing.md),
          Text(
            message,
            key: const Key('scheduled-task-error'),
            style: theme.bodySmall?.copyWith(color: theme.error),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        Row(
          children: [
            Expanded(
              child: ConduitButton(
                text: l10n.cancel,
                isSecondary: true,
                onPressed: _saving ? null : () => context.pop(),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: ConduitButton(
                key: const Key('scheduled-task-save'),
                text: l10n.save,
                isLoading: _saving,
                onPressed: _saving || !draft.isChanged ? null : _save,
              ),
            ),
          ],
        ),
      ],
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
  ) {
    final theme = context.conduitTheme;
    final schedule = draft.schedule;
    final selected = switch (schedule) {
      OnceAutomationSchedule() => 'once',
      DailyAutomationSchedule() => 'daily',
      WeeklyAutomationSchedule() => 'weekly',
      RawAutomationSchedule() => null,
    };
    final (hour, minute) = switch (schedule) {
      OnceAutomationSchedule(:final hour, :final minute) => (hour, minute),
      DailyAutomationSchedule(:final hour, :final minute) => (hour, minute),
      WeeklyAutomationSchedule(:final hour, :final minute) => (hour, minute),
      RawAutomationSchedule() => (null, null),
    };
    return [
      Text(
        l10n.scheduledTaskScheduleLabel,
        style: theme.label?.copyWith(color: theme.textSecondary),
      ),
      const SizedBox(height: Spacing.xs),
      // A wrapping row, not equal-width columns: a chip keeps the width its
      // label needs and moves to the next line on a narrow phone or at a large
      // text size, instead of overflowing.
      Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: [
          for (final kind in const ['once', 'daily', 'weekly'])
            ConduitChip(
              key: Key('scheduled-task-kind-$kind'),
              label: switch (kind) {
                'once' => l10n.scheduledTaskScheduleOnce,
                'daily' => l10n.scheduledTaskScheduleDaily,
                _ => l10n.scheduledTaskScheduleWeekly,
              },
              isSelected: selected == kind,
              onTap: _saving ? null : () => _chooseKind(kind),
            ),
        ],
      ),
      const SizedBox(height: Spacing.sm),
      if (schedule is RawAutomationSchedule) ...[
        Text(
          scheduleSummary(context, l10n, schedule),
          key: const Key('scheduled-task-raw-summary'),
          style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          l10n.scheduledTaskRruleKept,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
      ] else
        InsetGroupedList(
          children: [
            if (schedule is OnceAutomationSchedule)
              UtilityRow(
                key: const Key('scheduled-task-date'),
                title: l10n.scheduledTaskDateLabel,
                subtitle: MaterialLocalizations.of(context)
                    .formatMediumDate(schedule.wallClock),
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
          ],
        ),
      if (schedule is WeeklyAutomationSchedule) ...[
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final code in AutomationSchedule.weekdayCodes)
              ConduitChip(
                key: Key('scheduled-task-day-$code'),
                label: weekdayLabel(context, code),
                isSelected: schedule.days.contains(code),
                isCompact: true,
                onTap: _saving
                    ? null
                    : () => _setSchedule(
                        WeeklyAutomationSchedule(
                          hour: schedule.hour,
                          minute: schedule.minute,
                          days: schedule.days.contains(code)
                              ? ({...schedule.days}..remove(code))
                              : {...schedule.days, code},
                        ),
                      ),
              ),
          ],
        ),
      ],
      const SizedBox(height: Spacing.sm),
      Text(
        l10n.scheduledTaskTimezoneNote,
        key: const Key('scheduled-task-timezone-note'),
        style: theme.bodySmall?.copyWith(color: theme.textSecondary),
      ),
      InsetGroupedList(
        children: [
          UtilityRow(
            key: const Key('scheduled-task-advanced'),
            title: l10n.scheduledTaskAdvancedSchedule,
            trailing: Icon(
              _advancedOpen
                  ? CupertinoIcons.chevron_up
                  : CupertinoIcons.chevron_down,
              size: IconSize.small,
            ),
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
          ),
        ],
      ),
      if (_advancedOpen) ...[
        const SizedBox(height: Spacing.sm),
        ConduitInput(
          key: const Key('scheduled-task-rrule'),
          controller: _rrule,
          label: l10n.scheduledTaskRruleLabel,
          minLines: 2,
          maxLines: 4,
          enabled: !_saving,
          onChanged: (value) => _update(
            draft.copyWith(schedule: AutomationSchedule.parse(value)),
          ),
        ),
      ],
    ];
  }

  List<Widget> _destination(
    BuildContext context,
    AppLocalizations l10n,
    AutomationDraft draft,
    ({
      List<Model>? models,
      List<Channel>? channels,
      Map<String, AutomationChannelAccess> access,
      List<({String id, String name})>? folders,
    })
    options,
  ) {
    final theme = context.conduitTheme;
    final channels = options.channels;
    final folders = options.folders;
    final channelId = draft.target.channelId;
    final channelName = channels?.where((c) => c.id == channelId).firstOrNull;
    final folderId = draft.folderId;
    final folder = folders?.where((f) => f.id == folderId).firstOrNull;
    return [
      Text(
        l10n.scheduledTaskDestinationLabel,
        style: theme.label?.copyWith(color: theme.textSecondary),
      ),
      const SizedBox(height: Spacing.xs),
      Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        children: [
          ConduitChip(
            key: const Key('scheduled-task-target-chat'),
            label: l10n.scheduledTaskDestinationChat,
            isSelected: !draft.target.isChannel,
            onTap: _saving
                ? null
                : () => _update(
                    draft.copyWith(target: const AutomationTarget.chat()),
                  ),
          ),
          ConduitChip(
            key: const Key('scheduled-task-target-channel'),
            label: l10n.scheduledTaskDestinationChannel,
            isSelected: draft.target.isChannel,
            onTap: _saving || draft.target.isChannel
                ? null
                : () => _update(
                    draft.copyWith(
                      target: const AutomationTarget.channelPending(),
                    ),
                  ),
          ),
        ],
      ),
      const SizedBox(height: Spacing.sm),
      InsetGroupedList(
        children: [
          if (draft.target.isChannel)
            UtilityRow(
              key: const Key('scheduled-task-channel'),
              title: l10n.scheduledTaskDestinationChannel,
              subtitle: channelId == null
                  ? l10n.scheduledTaskChannelChoose
                  : channelName != null
                  ? '#${channelName.name}'
                  : channels == null
                  ? channelId
                  : l10n.scheduledTaskChannelUnavailable,
              showChevron: true,
              onTap: _saving || channels == null
                  ? null
                  : () => _pickChannel(channels, options.access),
            )
          else
            UtilityRow(
              key: const Key('scheduled-task-folder'),
              title: l10n.scheduledTaskFolderLabel,
              subtitle: folderId == null
                  ? l10n.scheduledTaskFolderNone
                  : folder != null
                  ? folder.name
                  : folders == null
                  ? folderId
                  : l10n.scheduledTaskFolderUnavailable,
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

/// A searchable single-choice sheet. Pops the chosen option's id.
class _OptionSheet extends StatefulWidget {
  const _OptionSheet({required this.title, required this.options});

  final String title;
  final List<({String id, String label, String? subtitle})> options;

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
      duration: const Duration(milliseconds: 180),
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
                  Text(
                    widget.title,
                    style: theme.headingSmall?.copyWith(
                      color: theme.sidebarForeground,
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  ConduitInput(
                    key: const Key('scheduled-task-option-search'),
                    hint: l10n.scheduledTasksSearchHint,
                    semanticLabel: l10n.scheduledTasksSearchHint,
                    onChanged: (value) => setState(() => _query = value),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final option in shown)
                          UtilityRow(
                            key: Key('scheduled-task-option-${option.id}'),
                            title: option.label,
                            subtitle: option.subtitle,
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
