import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/automation_destinations.dart';
import 'package:conduit_core/features/automations/automation_draft.dart';
import 'package:conduit_core/features/automations/automation_run_tracking.dart';
import 'package:conduit_core/features/automations/automation_schedule.dart';
import 'package:conduit_core/features/automations/models/automation.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_terminal_providers.dart';
import 'package:conduit_core/features/channels/providers/channel_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_agent_model.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../automations/scheduled_task_format.dart';
import '../../navigation/providers/conversation_selection_provider.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

/// The list of scheduled tasks.
const scheduledTasksPageId = NativeSheetRoutes.scheduledTasks;

/// Prefix of a task's page; its URI-encoded id follows.
const scheduledTaskPagePrefix = 'scheduled-task:';

/// Prefix of a task's editor; the URI-encoded task id, or
/// [scheduledTaskNewKey] for a new task, follows.
const scheduledTaskEditorPagePrefix = 'scheduled-task-edit:';

/// Prefix of an editor's Days page; the editor's key follows.
const scheduledTaskDaysPagePrefix = 'scheduled-task-days:';

/// Prefix of an editor's Advanced Schedule page; the editor's key follows.
const scheduledTaskRulePagePrefix = 'scheduled-task-rule:';

/// The key of the editor of a new task.
const scheduledTaskNewKey = 'new';

/// The key the list's own rows carry.
const scheduledTasksListKey = 'list';

/// Prefix of the rows of the scheduled tasks' pages.
const scheduledTaskRowPrefix = 'scheduled-task.';

/// How often history is read while waiting for a run the user asked for.
@visibleForTesting
const scheduledTaskRunPollInterval = automationRunPollInterval;

/// How many history reads a Run Now waits before it stops watching, about two
/// minutes at [scheduledTaskRunPollInterval].
@visibleForTesting
const scheduledTaskRunPollLimit = automationRunPollLimit;

/// An example rule shown in the empty recurrence rule field.
const _rruleExample = 'RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;BYHOUR=9;BYMINUTE=0';

String scheduledTaskPageId(String taskId) =>
    '$scheduledTaskPagePrefix${Uri.encodeComponent(taskId)}';

/// The editor of task [taskId], or of a new one when it is null.
String scheduledTaskEditorPageId(String? taskId) =>
    '$scheduledTaskEditorPagePrefix${_taskKey(taskId)}';

String _taskKey(String? taskId) =>
    taskId == null ? scheduledTaskNewKey : Uri.encodeComponent(taskId);

/// A row of the scheduled tasks' pages: `scheduled-task.<field>:<key>`, with
/// [extra] after another colon.
String scheduledTaskRowId(String field, String key, [String? extra]) =>
    '$scheduledTaskRowPrefix$field:$key'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// Where a Run Now the user asked for on a task's page stands.
enum ScheduledTaskRunPhase {
  idle,

  /// The run request is on its way to the server.
  requesting,

  /// The server accepted the request; history is read until the run shows.
  waiting,
  finished,
  failed,

  /// The run did not show in history in time. It may still finish.
  timedOut,
}

NativeSheetItemConfig _note(
  String id,
  String title, [
  String symbol = 'info.circle',
  String? subtitle,
]) => NativeSheetItemConfig(
  id: id,
  title: title,
  subtitle: subtitle,
  sfSymbol: symbol,
  kind: NativeSheetItemKind.info,
);

NativeSheetItemConfig _warning(String id, String title) =>
    _note(id, title, 'exclamationmark.triangle');

extension on NativeSheetDetailConfig {
  /// This page's rows under another page's id.
  NativeSheetDetailConfig withId(String id) =>
      NativeSheetDetailConfig(id: id, title: title, items: items);
}

// -- The list ---------------------------------------------------------------

/// What the list of scheduled tasks shows.
@immutable
@visibleForTesting
final class ScheduledTasksListState {
  const ScheduledTasksListState({
    required this.advanced,
    required this.available,
    this.data,
    this.loading = false,
    this.status = AutomationStatusFilter.all,
    this.query = '',
    this.awaitingFilter = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.busy = const {},
    this.notice,
  });

  final bool advanced;
  final bool available;

  /// The tasks read, or null while none could be.
  final AutomationsData? data;

  /// Whether a first read is still on its way.
  final bool loading;

  /// The filter and search shown: the ones the user last chose.
  final AutomationStatusFilter status;
  final String query;

  /// Whether the rows on hand answer an older search or filter than the one
  /// just chosen, so they are not shown as its answer.
  final bool awaitingFilter;
  final bool refreshing;
  final bool loadingMore;

  /// Tasks whose change from a row's menu is on its way.
  final Set<String> busy;
  final String? notice;
}

/// The account's Open WebUI scheduled tasks: a search, a status filter, the
/// tasks with their schedule and next run, and a row adding one. The server
/// runs them on its own schedule, so nothing here depends on this phone.
@visibleForTesting
NativeSheetDetailConfig buildScheduledTasksPage(
  AppLocalizations l10n,
  TaskClock clock,
  ScheduledTasksListState state,
) {
  const pageId = scheduledTasksPageId;
  const key = scheduledTasksListKey;
  if (!state.advanced || !state.available) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.scheduledTasksTitle,
      items: [
        _note(
          '$pageId-unavailable',
          state.advanced
              ? l10n.scheduledTasksUnavailable
              : l10n.advancedRequiredMessage(l10n.scheduledTasksTitle),
          state.advanced
              ? 'clock.badge.exclamationmark'
              : 'slider.horizontal.3',
        ),
      ],
    );
  }
  final data = state.data;
  final filtered =
      data != null &&
      (data.query.isNotEmpty || data.status != AutomationStatusFilter.all);
  final emptyAccount = data != null && data.items.isEmpty && !filtered;
  final addRow = NativeSheetItemConfig(
    id: scheduledTaskEditorPageId(null),
    title: emptyAccount ? l10n.scheduledTasksEmpty : l10n.scheduledTasksAdd,
    subtitle: emptyAccount ? l10n.scheduledTasksEmptyHint : null,
    sfSymbol: 'plus.circle',
    accent: true,
  );
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.scheduledTasksTitle,
    subtitle: l10n.scheduledTasksDescription,
    announcement: state.notice,
    search: NativeSheetSearchConfig(
      id: scheduledTaskRowId('search', key),
      placeholder: l10n.scheduledTasksSearchHint,
      value: state.query,
    ),
    sections: [
      if (state.notice != null)
        NativeSheetSectionConfig(
          items: [_note('$pageId-notice', state.notice!)],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('filter', key),
            title: l10n.scheduledTasksFilterLabel,
            sfSymbol: 'line.3.horizontal.decrease.circle',
            kind: NativeSheetItemKind.segment,
            value: state.status.name,
            options: [
              for (final filter in AutomationStatusFilter.values)
                NativeSheetOptionConfig(
                  id: filter.name,
                  label: switch (filter) {
                    AutomationStatusFilter.all => l10n.scheduledTasksFilterAll,
                    AutomationStatusFilter.active =>
                      l10n.scheduledTasksFilterActive,
                    AutomationStatusFilter.paused =>
                      l10n.scheduledTasksFilterPaused,
                  },
                ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          if ((data == null && state.loading) || state.awaitingFilter)
            buildNativeLoadingItem(l10n, id: '$pageId-loading')
          else if (data == null)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('retry', key),
              title: l10n.scheduledTasksLoadFailed,
              subtitle: l10n.retry,
              sfSymbol: 'exclamationmark.triangle',
              showsDisclosure: false,
            )
          else if (emptyAccount)
            addRow
          else if (data.items.isEmpty) ...[
            _note('$pageId-no-match', l10n.scheduledTasksEmptyFiltered),
            NativeSheetItemConfig(
              id: scheduledTaskRowId('show-all', key),
              title: l10n.scheduledTasksShowAll,
              sfSymbol: 'list.bullet',
              accent: true,
              showsDisclosure: false,
            ),
          ] else
            for (final task in data.items)
              _taskRow(l10n, clock, task, busy: state.busy.contains(task.id)),
          if (data != null && data.hasMore && !state.awaitingFilter)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('more', key),
              title: l10n.scheduledTasksLoadMore,
              sfSymbol: 'arrow.down.circle',
              accent: true,
              showsDisclosure: false,
              pending: state.loadingMore ? true : null,
              disabled: state.loadingMore,
            ),
          if ((data?.stale ?? false) && !state.awaitingFilter)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('retry', key),
              title: l10n.scheduledTasksStale,
              subtitle: l10n.retry,
              sfSymbol: 'arrow.clockwise',
              showsDisclosure: false,
              pending: state.refreshing ? true : null,
              disabled: state.refreshing,
            ),
        ],
      ),
      if (!emptyAccount) NativeSheetSectionConfig(items: [addRow]),
    ],
  );
}

NativeSheetItemConfig _taskRow(
  AppLocalizations l10n,
  TaskClock clock,
  Automation task, {
  required bool busy,
}) {
  final key = _taskKey(task.id);
  final next = formatServerTime(clock, task.nextRunNs);
  final schedule = AutomationSchedule.parse(task.rrule);
  final lastRunFailed = task.lastRun?.succeeded == false;
  return NativeSheetItemConfig(
    id: scheduledTaskPageId(task.id),
    title: task.name,
    subtitle: [
      [
        // A rule the controls cannot describe is named, not printed: the raw
        // text is too long for a list and means little at a glance.
        if (schedule is RawAutomationSchedule)
          l10n.scheduledTaskScheduleCustom
        else
          scheduleSummary(clock, l10n, schedule),
        if (task.isActive)
          next == null
              ? l10n.scheduledTaskNoNextRun
              : l10n.scheduledTaskNextRun(next),
      ].join(' · '),
      if (!task.isActive) l10n.scheduledTaskStatusPaused,
      if (lastRunFailed) l10n.scheduledTaskLastRunFailed,
    ].join('\n'),
    sfSymbol: lastRunFailed
        ? 'exclamationmark.circle'
        : task.isActive
        ? 'clock'
        : 'pause.circle',
    pending: busy ? true : null,
    rowActions: [
      if (!busy)
        NativeSheetRowAction(
          id: scheduledTaskRowId('active', key, task.isActive ? 'off' : 'on'),
          label: task.isActive ? l10n.hermesJobPause : l10n.hermesJobResume,
          sfSymbol: task.isActive ? 'pause.circle' : 'play.circle',
        ),
      if (!busy)
        NativeSheetRowAction(
          id: scheduledTaskRowId('delete', key),
          label: l10n.scheduledTaskDelete,
          sfSymbol: 'trash',
          destructive: true,
          confirmMessage: l10n.scheduledTaskDeleteConfirm(task.name),
        ),
    ],
  );
}

// -- A task's page ------------------------------------------------------------

/// What a task's page holds while it is open, for the account it opened for.
final class _TaskView {
  _TaskView(this.taskId, this.owner);

  final String taskId;

  /// The account the page was opened for. Every request and navigation is
  /// for it only.
  final AutomationsOwner? owner;
  Automation? task;
  Object? loadError;
  List<AutomationRun> runs = const [];

  /// Counts the history reads Run Now merged into [runs], so a page read that
  /// started earlier adds to them instead of replacing them.
  int runsMerges = 0;
  bool runsLoading = false;
  bool runsFailed = false;
  bool hasMoreRuns = false;

  /// The state the switch was moved to, until the server answers.
  bool? pendingActive;
  bool deleting = false;
  ScheduledTaskRunPhase runPhase = ScheduledTaskRunPhase.idle;

  /// Why a request from this page was refused.
  String? error;

  /// The run Run Now found in history, newer than anything the page knew
  /// when it was asked for, until the task is read again.
  AutomationRun? requestedRun;
  Timer? runPoll;
  int runPolls = 0;
  bool runPollInFlight = false;

  bool get runBusy =>
      runPhase == ScheduledTaskRunPhase.requesting ||
      runPhase == ScheduledTaskRunPhase.waiting;

  void stopPolling() {
    runPoll?.cancel();
    runPoll = null;
  }
}

/// Names the page shows in place of ids, when they could be read.
typedef _TaskNames = ({
  List<Channel>? channels,
  List<({String id, String name})>? folders,
  List<Model>? models,
});

/// The newest run the page knows of, and when it ran: the task's own last
/// run, unless Run Now or history has shown a newer one since the task was
/// read, so the Last Run row agrees with history and the run notice.
({AutomationRun? run, int? at}) _latestRun(_TaskView view, Automation task) {
  var run = task.lastRun;
  var at = run?.createdAtNs ?? task.lastRunAtNs;
  final requested = view.requestedRun;
  if (requested != null && requested.id != run?.id) {
    final requestedAt = requested.createdAtNs;
    if (requestedAt == null || at == null || requestedAt >= at) {
      run = requested;
      at = requestedAt;
    }
  }
  for (final candidate in view.runs) {
    final candidateAt = candidate.createdAtNs;
    if (candidateAt == null) continue;
    // An untimed run cannot be ordered, so a timed one replaces it only when
    // there was none.
    if (at == null ? run == null : candidateAt > at) {
      run = candidate;
      at = candidateAt;
    }
  }
  return (run: run, at: at);
}

String _runStatus(AppLocalizations l10n, AutomationRun run) => run.succeeded
    ? l10n.scheduledTaskRunSucceeded
    : l10n.scheduledTaskRunFailedStatus;

/// One task: its definition as the server holds it, controls that call the
/// server, and its run history, which Run Now reads until its run shows.
NativeSheetDetailConfig _buildTaskPage(
  AppLocalizations l10n,
  TaskClock clock,
  _TaskView view,
  _TaskNames names,
) {
  final pageId = scheduledTaskPageId(view.taskId);
  final key = _taskKey(view.taskId);
  final task = view.task;
  // A read that failed -- the task deleted meanwhile, say -- says so, rather
  // than leave the copy read before as if it were current.
  if (task == null || view.loadError != null) {
    final error = view.loadError;
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.scheduledTasksTitle,
      items: [
        if (error == null)
          buildNativeLoadingItem(l10n, id: '$pageId-loading')
        else ...[
          _warning(
            '$pageId-load-error',
            scheduledTaskErrorText(
              l10n,
              error,
              fallback: l10n.scheduledTasksLoadFailed,
            ),
          ),
          NativeSheetItemConfig(
            id: scheduledTaskRowId('reload', key),
            title: l10n.retry,
            sfSymbol: 'arrow.clockwise',
            accent: true,
            showsDisclosure: false,
          ),
        ],
      ],
    );
  }
  final next = task.isActive ? task.nextRunsNs : null;
  final (run: lastRun, at: lastRunAtNs) = _latestRun(view, task);
  final lastRunAt = formatServerTime(clock, lastRunAtNs);
  final destination = task.target.isChannel
      ? [
          l10n.scheduledTaskDestinationChannel,
          ?names.channels
              ?.where((c) => c.id == task.target.channelId)
              .map((c) => '#${c.name}')
              .firstOrNull,
        ].join(' · ')
      : [
          l10n.scheduledTaskDestinationChat,
          ?names.folders
              ?.where((f) => f.id == task.folderId)
              .map((f) => f.name)
              .firstOrNull,
        ].join(' · ');
  final modelName =
      names.models?.where((m) => m.id == task.modelId).firstOrNull?.name ??
      terminalAgentDisplayName(task.modelId) ??
      task.modelId;
  final lastRunTitle = lastRunAt != null
      ? l10n.scheduledTaskLastRun(lastRunAt)
      : lastRun != null
      ? _runStatus(l10n, lastRun)
      : l10n.scheduledTaskNeverRun;
  final runNotice = switch (view.runPhase) {
    ScheduledTaskRunPhase.idle || ScheduledTaskRunPhase.requesting => null,
    ScheduledTaskRunPhase.waiting => (l10n.scheduledTaskRunning, 'hourglass'),
    ScheduledTaskRunPhase.finished => (
      l10n.scheduledTaskRunFinished,
      'checkmark.circle',
    ),
    ScheduledTaskRunPhase.failed => (
      l10n.scheduledTaskRunFailedNotice,
      'exclamationmark.triangle',
    ),
    ScheduledTaskRunPhase.timedOut => (l10n.scheduledTaskRunRequested, 'clock'),
  };
  final pending = view.pendingActive;
  final busy = view.deleting;
  return NativeSheetDetailConfig(
    id: pageId,
    title: task.name,
    announcement: view.error ?? runNotice?.$1,
    sections: [
      if (view.error != null)
        NativeSheetSectionConfig(
          items: [_warning('$pageId-error', view.error!)],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('active', key),
            title: l10n.scheduledTaskActiveLabel,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: pending ?? task.isActive,
            // A Run Now on its way returns the task too; one change at a time
            // keeps an older reply from undoing a newer one.
            disabled:
                pending != null ||
                busy ||
                view.runPhase == ScheduledTaskRunPhase.requesting,
          ),
          _note(
            '$pageId-schedule',
            l10n.scheduledTaskScheduleLabel,
            'calendar',
            scheduleSummary(clock, l10n, AutomationSchedule.parse(task.rrule)),
          ),
          _note(
            '$pageId-model',
            l10n.scheduledTaskModelLabel,
            'cpu',
            modelName,
          ),
          _note(
            '$pageId-destination',
            l10n.scheduledTaskDestinationLabel,
            task.target.isChannel ? 'number' : 'bubble.left',
            destination,
          ),
          _note(
            '$pageId-last-run',
            lastRunTitle,
            lastRun == null
                ? 'clock'
                : lastRun.succeeded
                ? 'checkmark.circle'
                : 'exclamationmark.circle',
            lastRun == null || lastRunAt == null
                ? null
                : _runStatus(l10n, lastRun),
          ),
          NativeSheetItemConfig(
            id: scheduledTaskEditorPageId(task.id),
            title: l10n.edit,
            sfSymbol: 'pencil',
            disabled: busy,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.scheduledTaskNextRunsLabel,
        items: [
          if (next == null || next.isEmpty)
            _note(
              '$pageId-no-next-runs',
              task.isActive
                  ? l10n.scheduledTaskNoNextRun
                  : l10n.scheduledTaskStatusPaused,
              'calendar',
            )
          else
            for (final time in next)
              _note(
                '$pageId-next-run-$time',
                formatServerTime(clock, time) ?? '',
                'calendar',
              ),
        ],
      ),
      // The row heads its own text: a row without a title is no row on
      // iOS, which would drop the whole group.
      NativeSheetSectionConfig(
        footer: task.terminal != null ? l10n.scheduledTaskTerminalKept : null,
        items: [
          NativeSheetItemConfig(
            id: '$pageId-prompt',
            title: l10n.scheduledTaskPromptLabel,
            sfSymbol: 'text.bubble',
            kind: NativeSheetItemKind.readOnlyText,
            value: task.prompt,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('run', key),
            title: l10n.scheduledTaskRunNow,
            sfSymbol: 'play',
            accent: true,
            showsDisclosure: false,
            pending: view.runBusy ? true : null,
            disabled: view.runBusy || busy || pending != null,
          ),
          if (runNotice != null)
            _note('$pageId-run-notice', runNotice.$1, runNotice.$2),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.scheduledTaskHistoryTitle,
        items: [
          if (view.runs.isEmpty && view.runsLoading)
            buildNativeLoadingItem(l10n, id: '$pageId-runs-loading')
          else if (view.runs.isEmpty && view.runsFailed)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('runs-retry', key),
              title: l10n.scheduledTaskHistoryLoadFailed,
              subtitle: l10n.retry,
              sfSymbol: 'exclamationmark.triangle',
              showsDisclosure: false,
            )
          else if (view.runs.isEmpty)
            _note('$pageId-runs-empty', l10n.scheduledTaskHistoryEmpty, 'clock')
          else
            for (final run in view.runs) _runRow(l10n, clock, key, run),
          if (view.hasMoreRuns && view.runs.isNotEmpty)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('runs-more', key),
              title: l10n.scheduledTasksLoadMore,
              sfSymbol: 'arrow.down.circle',
              accent: true,
              showsDisclosure: false,
              pending: view.runsLoading ? true : null,
              disabled: view.runsLoading,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('delete', key),
            title: l10n.scheduledTaskDelete,
            sfSymbol: 'trash',
            destructive: true,
            showsDisclosure: false,
            pending: busy ? true : null,
            disabled: busy,
            confirmMessage: l10n.scheduledTaskDeleteConfirm(task.name),
          ),
        ],
      ),
    ],
  );
}

NativeSheetItemConfig _runRow(
  AppLocalizations l10n,
  TaskClock clock,
  String key,
  AutomationRun run,
) {
  final time = formatServerTime(clock, run.createdAtNs) ?? '';
  final hasChannel = run.resultChannelId != null;
  final canOpen = hasChannel || run.resultChatId != null;
  return NativeSheetItemConfig(
    id: scheduledTaskRowId('open-run', key, run.id),
    title: time.isEmpty ? _runStatus(l10n, run) : time,
    subtitle: [
      if (time.isNotEmpty) _runStatus(l10n, run),
      ?run.error,
      if (canOpen)
        hasChannel ? l10n.scheduledTaskViewChannel : l10n.scheduledTaskViewChat,
    ].join('\n'),
    sfSymbol: run.succeeded ? 'checkmark.circle' : 'exclamationmark.circle',
    kind: canOpen ? NativeSheetItemKind.navigation : NativeSheetItemKind.info,
    showsDisclosure: canOpen ? false : null,
  );
}

// -- The editor ---------------------------------------------------------------

/// A task's editor, as typed so far, for the account it opened for.
final class _TaskEditor {
  _TaskEditor(this.key, this.owner);

  final String key;
  final AutomationsOwner? owner;
  AutomationDraft? draft;

  /// A new task's draft as the editor opened it, to tell whether anything was
  /// entered. An edit compares against the task itself.
  AutomationDraft? start;
  Object? loadError;

  /// The recurrence rule as typed on the Advanced Schedule page.
  String rule = '';

  /// The working folder the terminal is asked for agents with.
  String? agentCwd;
  bool saving = false;

  /// Set by the first Save. From then on every issue shows on its row.
  bool attempted = false;

  /// What the server or the account said, as opposed to a field's own issue.
  String? error;
  bool shownEdited = false;

  /// Whether its Days and Advanced Schedule pages were last drawn closed:
  /// open again, they show the schedule once more.
  bool pagesClosed = false;

  /// Keeps the editor's terminal's coding agents read while it is open.
  ProviderSubscription<AsyncValue<List<Model>?>>? agents;
  AutomationAgentQuery? agentsQuery;

  void adopt(AutomationDraft next) {
    draft = next;
    rule = next.schedule.toRrule();
    agentCwd = next.terminalCwd;
  }

  /// Whether leaving now would lose something the user entered.
  bool get edited {
    final draft = this.draft;
    if (draft == null) return false;
    final start = this.start;
    if (start == null) return draft.isChanged;
    return draft.name != start.name ||
        draft.prompt != start.prompt ||
        draft.modelId != start.modelId ||
        draft.schedule != start.schedule ||
        draft.target != start.target ||
        draft.isActive != start.isActive ||
        draft.folderId != start.folderId ||
        draft.terminalId != start.terminalId ||
        (draft.terminalCwd ?? '').trim() != (start.terminalCwd ?? '').trim();
  }

  void dispose() {
    agents?.close();
    agents = null;
  }
}

/// The values the account can pick now, or null while a list has not loaded,
/// in which case the server decides instead of a guess here.
typedef _EditorOptions = ({
  List<Model>? models,
  List<TerminalServerInfo>? terminals,
  bool agentsLoading,
  bool agentsUnknown,
  List<Channel>? channels,
  Map<String, AutomationChannelAccess> access,
  List<({String id, String name})>? folders,
});

List<AutomationDraftIssue> _issues(
  AutomationDraft draft,
  _EditorOptions options,
) => draft.issues(
  modelIds: options.models == null || options.agentsUnknown
      ? null
      : {for (final m in options.models!) m.id},
  folderIds: options.folders == null
      ? null
      : {for (final f in options.folders!) f.id},
  channelIds: options.channels == null
      ? null
      : {for (final c in options.channels!) c.id},
);

String _modelLabel(
  AppLocalizations l10n,
  AutomationDraft draft,
  List<Model>? models,
) {
  final id = draft.modelId.trim();
  if (id.isEmpty) return l10n.scheduledTaskModelChoose;
  final match = models?.where((m) => m.id == id).firstOrNull;
  if (match != null) return match.name;
  // An agent's id is an address; name it as the picker does.
  final agentName = terminalAgentDisplayName(id);
  if (agentName != null) {
    return models == null
        ? agentName
        : l10n.scheduledTaskModelUnavailable(agentName);
  }
  // A saved id the account cannot pick now stays visible and is not saved
  // again until a compatible model is chosen.
  return models == null ? id : l10n.scheduledTaskModelUnavailable(id);
}

String _terminalLabel(
  AppLocalizations l10n,
  AutomationDraft draft,
  List<TerminalServerInfo>? terminals,
) {
  final id = draft.terminalId;
  if (id == null) return l10n.scheduledTaskFolderNone;
  final match = terminals?.where((t) => t.selectionId == id).firstOrNull;
  if (match != null) return match.displayName;
  return terminals == null ? id : l10n.scheduledTaskModelUnavailable(id);
}

/// The days a one-time run can be moved to: from today (or its current day,
/// if that has passed) to five years ahead.
({DateTime first, DateTime last}) _dateRange(OnceAutomationSchedule once) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final wall = once.wallClock;
  final current = DateTime(wall.year, wall.month, wall.day);
  return (
    first: current.isBefore(today) ? current : today,
    last: today.add(const Duration(days: 365 * 5)),
  );
}

/// A task's editor: name and on/off, the prompt, the terminal and model, the
/// schedule (its kind, day or days and time, with the raw rule on a page of
/// its own), and where the result goes.
NativeSheetDetailConfig _buildEditorPage(
  AppLocalizations l10n,
  TaskClock clock,
  _TaskEditor editor,
  _EditorOptions options,
) {
  final pageId = '$scheduledTaskEditorPagePrefix${editor.key}';
  final key = editor.key;
  final draft = editor.draft;
  final title = key == scheduledTaskNewKey
      ? l10n.scheduledTaskNewTitle
      : l10n.scheduledTaskEditTitle;
  if (draft == null) {
    final error = editor.loadError;
    return NativeSheetDetailConfig(
      id: pageId,
      title: title,
      items: [
        if (error == null)
          buildNativeLoadingItem(l10n, id: '$pageId-loading')
        else ...[
          _warning(
            '$pageId-load-error',
            scheduledTaskErrorText(
              l10n,
              error,
              fallback: l10n.scheduledTasksLoadFailed,
            ),
          ),
          NativeSheetItemConfig(
            id: scheduledTaskRowId('reload', key),
            title: l10n.retry,
            sfSymbol: 'arrow.clockwise',
            accent: true,
            showsDisclosure: false,
          ),
        ],
      ],
    );
  }
  final issues = editor.attempted
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
  final terminalIssue = issue(const {AutomationDraftIssue.terminalRequired});
  final scheduleIssue = issue(const {AutomationDraftIssue.scheduleIncomplete});
  final channelIssue = issue(const {
    AutomationDraftIssue.channelRequired,
    AutomationDraftIssue.channelUnavailable,
    AutomationDraftIssue.agentNeedsChat,
  });
  final folderIssue = issue(const {AutomationDraftIssue.folderUnavailable});
  // Offered when the server has a terminal for tasks, or the task has one.
  final showTerminal =
      (options.terminals?.isNotEmpty ?? false) || draft.terminalId != null;
  final schedule = draft.schedule;
  final (hour, minute) = switch (schedule) {
    OnceAutomationSchedule(:final hour, :final minute) => (hour, minute),
    DailyAutomationSchedule(:final hour, :final minute) => (hour, minute),
    WeeklyAutomationSchedule(:final hour, :final minute) => (hour, minute),
    RawAutomationSchedule() => (null, null),
  };
  final channels = options.channels;
  final channelId = draft.target.channelId;
  final channel = channels?.where((c) => c.id == channelId).firstOrNull;
  final folders = options.folders;
  final folderId = draft.folderId;
  final folder = folders?.where((f) => f.id == folderId).firstOrNull;
  final typed = AutomationSchedule.parse(editor.rule);
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: scheduledTaskRowId('save', key),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: editor.saving,
    edited: editor.edited,
    announcement: editor.error,
    sections: [
      if (editor.error != null)
        NativeSheetSectionConfig(
          items: [_warning('$pageId-error', editor.error!)],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('name', key),
            title: l10n.scheduledTaskNameLabel,
            subtitle: issue(const {AutomationDraftIssue.nameRequired}),
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: draft.name,
            placeholder: l10n.scheduledTaskNameLabel,
          ),
          NativeSheetItemConfig(
            id: scheduledTaskRowId('active', key),
            title: l10n.scheduledTaskActiveLabel,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: draft.isActive,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('prompt', key),
            title: l10n.scheduledTaskPromptLabel,
            subtitle: issue(const {AutomationDraftIssue.promptRequired}),
            sfSymbol: 'text.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: draft.prompt,
            placeholder: l10n.scheduledTaskPromptHint,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          if (showTerminal)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('terminal', key),
              title: l10n.terminal,
              subtitle:
                  terminalIssue ??
                  _terminalLabel(l10n, draft, options.terminals),
              sfSymbol: 'terminal',
              kind: NativeSheetItemKind.searchablePicker,
              value: draft.terminalId ?? '',
              disabled: options.terminals == null,
              options: [
                NativeSheetOptionConfig(
                  id: '',
                  label: l10n.scheduledTaskFolderNone,
                ),
                for (final terminal
                    in options.terminals ?? const <TerminalServerInfo>[])
                  NativeSheetOptionConfig(
                    id: terminal.selectionId,
                    label: terminal.displayName,
                  ),
              ],
            ),
          if (showTerminal && draft.terminalId != null)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('cwd', key),
              title: l10n.scheduledTaskWorkingFolderLabel,
              sfSymbol: 'folder',
              kind: NativeSheetItemKind.textField,
              value: draft.terminalCwd ?? '',
              placeholder: l10n.scheduledTaskWorkingFolderHint,
            ),
          NativeSheetItemConfig(
            id: scheduledTaskRowId('model', key),
            title: l10n.scheduledTaskModelLabel,
            subtitle:
                modelIssue ??
                (options.agentsLoading
                    ? l10n.scheduledTaskAgentsLoading
                    : _modelLabel(
                        l10n,
                        draft,
                        options.agentsUnknown ? null : options.models,
                      )),
            sfSymbol: 'cpu',
            kind: NativeSheetItemKind.searchablePicker,
            value: draft.modelId.trim(),
            disabled: options.models == null,
            options: [
              for (final model in options.models ?? const <Model>[])
                NativeSheetOptionConfig(
                  id: model.id,
                  label: model.name,
                  subtitle: terminalAgentPickerSubtitle(model) ?? model.id,
                ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.scheduledTaskScheduleLabel,
        footer: l10n.scheduledTaskTimezoneNote,
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('kind', key),
            title: l10n.calendarFieldRepeat,
            sfSymbol: 'repeat',
            kind: NativeSheetItemKind.segment,
            value: switch (schedule) {
              OnceAutomationSchedule() => 'once',
              DailyAutomationSchedule() => 'daily',
              WeeklyAutomationSchedule() => 'weekly',
              RawAutomationSchedule() => 'custom',
            },
            options: [
              NativeSheetOptionConfig(
                id: 'once',
                label: l10n.scheduledTaskScheduleOnce,
              ),
              NativeSheetOptionConfig(
                id: 'daily',
                label: l10n.scheduledTaskScheduleDaily,
              ),
              NativeSheetOptionConfig(
                id: 'weekly',
                label: l10n.scheduledTaskScheduleWeekly,
              ),
              // No kind is chosen for a rule the controls cannot edit.
              if (schedule is RawAutomationSchedule)
                NativeSheetOptionConfig(
                  id: 'custom',
                  label: l10n.scheduledTaskScheduleCustom,
                  enabled: false,
                ),
            ],
          ),
          if (schedule is RawAutomationSchedule)
            _note(
              '$pageId-raw',
              scheduleSummary(clock, l10n, schedule),
              'calendar.badge.exclamationmark',
              scheduleIssue ?? l10n.scheduledTaskRruleKept,
            ),
          if (schedule is OnceAutomationSchedule)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('date', key),
              title: l10n.scheduledTaskDateLabel,
              sfSymbol: 'calendar',
              kind: NativeSheetItemKind.date,
              value: nativeSheetDateValue(schedule.wallClock),
              min: _dateRange(schedule).first.millisecondsSinceEpoch.toDouble(),
              max: _dateRange(schedule).last.millisecondsSinceEpoch.toDouble(),
            ),
          if (hour != null && minute != null)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('time', key),
              title: l10n.scheduledTaskTimeLabel,
              sfSymbol: 'clock',
              kind: NativeSheetItemKind.time,
              value: nativeSheetDateValue(DateTime(2000, 1, 1, hour, minute)),
            ),
          if (schedule is WeeklyAutomationSchedule)
            NativeSheetItemConfig(
              id: '$scheduledTaskDaysPagePrefix$key',
              title: l10n.scheduledTaskDaysLabel,
              subtitle:
                  scheduleIssue ??
                  [
                    for (final code in AutomationSchedule.weekdayCodes)
                      if (schedule.days.contains(code))
                        weekdayLabel(clock, code),
                  ].join(', '),
              sfSymbol: 'calendar.day.timeline.left',
            ),
          NativeSheetItemConfig(
            id: '$scheduledTaskRulePagePrefix$key',
            title: l10n.scheduledTaskAdvancedSchedule,
            subtitle: l10n.scheduledTaskRruleRuns(
              typed is RawAutomationSchedule
                  ? l10n.scheduledTaskScheduleCustom
                  : scheduleSummary(clock, l10n, typed),
            ),
            sfSymbol: 'slider.horizontal.3',
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: scheduledTaskRowId('target', key),
            title: l10n.scheduledTaskDestinationLabel,
            sfSymbol: draft.target.isChannel ? 'number' : 'bubble.left',
            kind: NativeSheetItemKind.segment,
            value: draft.target.isChannel ? 'channel' : 'chat',
            options: [
              NativeSheetOptionConfig(
                id: 'chat',
                label: l10n.scheduledTaskDestinationChat,
              ),
              NativeSheetOptionConfig(
                id: 'channel',
                label: l10n.scheduledTaskDestinationChannel,
              ),
            ],
          ),
          if (draft.target.isChannel)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('channel', key),
              title: l10n.scheduledTaskDestinationChannel,
              subtitle:
                  channelIssue ??
                  (channelId == null
                      ? l10n.scheduledTaskChannelChoose
                      : channel != null
                      ? '#${channel.name}'
                      : channels == null
                      ? channelId
                      : l10n.scheduledTaskChannelUnavailable),
              sfSymbol: 'number',
              kind: NativeSheetItemKind.searchablePicker,
              value: channelId ?? '',
              disabled: channels == null,
              options: [
                for (final c in channels ?? const <Channel>[])
                  NativeSheetOptionConfig(id: c.id, label: '#${c.name}'),
              ],
            )
          else
            NativeSheetItemConfig(
              id: scheduledTaskRowId('folder', key),
              title: l10n.scheduledTaskFolderLabel,
              subtitle:
                  folderIssue ??
                  (folderId == null
                      ? l10n.scheduledTaskFolderNone
                      : folder != null
                      ? folder.name
                      : folders == null
                      ? folderId
                      : l10n.scheduledTaskFolderUnavailable),
              sfSymbol: 'folder',
              kind: NativeSheetItemKind.searchablePicker,
              value: folderId ?? '',
              disabled: folders == null,
              options: [
                NativeSheetOptionConfig(
                  id: '',
                  label: l10n.scheduledTaskFolderNone,
                ),
                for (final f in folders ?? const <({String id, String name})>[])
                  NativeSheetOptionConfig(id: f.id, label: f.name),
              ],
            ),
        ],
      ),
    ],
  );
}

/// The days a weekly task runs on, each a row with a check.
NativeSheetDetailConfig _buildDaysPage(
  AppLocalizations l10n,
  TaskClock clock,
  _TaskEditor editor,
) {
  final pageId = '$scheduledTaskDaysPagePrefix${editor.key}';
  final schedule = editor.draft?.schedule;
  final days = schedule is WeeklyAutomationSchedule
      ? schedule.days
      : const <String>{};
  final empty = days.isEmpty;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.scheduledTaskDaysLabel,
    sections: [
      NativeSheetSectionConfig(
        footer: empty ? l10n.scheduledTaskScheduleIncomplete : null,
        items: [
          for (final code in AutomationSchedule.weekdayCodes)
            NativeSheetItemConfig(
              id: scheduledTaskRowId('day', editor.key, code),
              title: weekdayName(clock, code),
              sfSymbol: 'calendar',
              checked: days.contains(code),
              showsDisclosure: false,
            ),
        ],
      ),
    ],
  );
}

/// The task's recurrence rule as text, for a schedule the controls cannot
/// say.
NativeSheetDetailConfig _buildRulePage(
  AppLocalizations l10n,
  TaskClock clock,
  _TaskEditor editor,
) {
  final pageId = '$scheduledTaskRulePagePrefix${editor.key}';
  final typed = AutomationSchedule.parse(editor.rule);
  final schedule = editor.draft?.schedule;
  final incomplete =
      editor.attempted &&
      schedule is RawAutomationSchedule &&
      schedule.rrule.trim().isEmpty;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.scheduledTaskAdvancedSchedule,
    sections: [
      NativeSheetSectionConfig(
        footer: l10n.scheduledTaskRruleRuns(
          typed is RawAutomationSchedule
              ? l10n.scheduledTaskScheduleCustom
              : scheduleSummary(clock, l10n, typed),
        ),
        items: [
          if (incomplete)
            _warning('$pageId-issue', l10n.scheduledTaskScheduleIncomplete),
          NativeSheetItemConfig(
            id: scheduledTaskRowId('rule', editor.key),
            title: l10n.scheduledTaskRruleLabel,
            sfSymbol: 'chevron.left.forwardslash.chevron.right',
            kind: NativeSheetItemKind.multilineTextField,
            value: editor.rule,
            placeholder: _rruleExample,
          ),
        ],
      ),
    ],
  );
}

// -- The module ---------------------------------------------------------------

/// The account's Open WebUI scheduled tasks, in pages of Settings: the list,
/// each task's page with its runs, and the editor with its Days and Advanced
/// Schedule pages. Every request is for the account a page opened for, and
/// nothing that answers for another account, or for a page since left,
/// changes what is shown.
class ScheduledTaskSettingsPages extends SettingsPageModule {
  ScheduledTaskSettingsPages(this._ref) {
    // Gone with Settings's modules, it hears the app no more. Registered
    // once: Settings opened again makes a new listener, not a new disposer.
    _ref.onDispose(() {
      _lifecycle?.dispose();
      _lifecycle = null;
    });
  }

  final Ref _ref;
  AppLocalizations? _l10n;

  bool _listShown = false;
  AutomationStatusFilter? _pendingStatus;
  String? _pendingQuery;
  int _refreshGeneration = 0;
  bool _refreshing = false;
  bool _loadingMore = false;
  final Set<String> _listBusy = {};
  String? _listNotice;

  final Map<String, _TaskView> _tasks = {};
  final Map<String, _TaskEditor> _editors = {};
  final List<ProviderSubscription<Object?>> _following = [];
  final List<ProviderSubscription<Object?>> _followingData = [];
  bool _redrawQueued = false;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);
  Automations get _notifier => _ref.read(automationsProvider.notifier);

  @override
  bool ownsPage(String detailId) =>
      detailId == scheduledTasksPageId ||
      detailId.startsWith(scheduledTaskPagePrefix) ||
      detailId.startsWith(scheduledTaskEditorPagePrefix) ||
      detailId.startsWith(scheduledTaskDaysPagePrefix) ||
      detailId.startsWith(scheduledTaskRulePagePrefix);

  TaskClock _clock(AppLocalizations l10n) => taskClockFor(l10n);

  bool get _gateOpen =>
      _ref.read(appSettingsProvider).advancedFeaturesEnabled &&
      _ref.read(automationsAvailableProvider);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    _follow();
    if (detailId == scheduledTasksPageId) {
      // Reopening shows the server's list as it is now. A first open has no
      // list yet; reading it below is what loads it.
      final reopened = _ref.read(automationsProvider.exists);
      _listShown = true;
      _pendingStatus = null;
      _pendingQuery = null;
      await _applyList(l10n);
      if (reopened && _gateOpen && !_ref.read(automationsProvider).isLoading) {
        unawaited(_refresh());
      }
    } else if (detailId.startsWith(scheduledTaskPagePrefix)) {
      final taskId = Uri.decodeComponent(
        detailId.substring(scheduledTaskPagePrefix.length),
      );
      // Another account's page, asked for again: this account's task is
      // read afresh in its place.
      if (_stale(_tasks[taskId]?.owner)) _tasks.remove(taskId);
      final view = _tasks[taskId] ??= _TaskView(
        taskId,
        _notifier.captureOwner(),
      );
      await _applyTask(l10n, view);
      // Back from the editor, the page shows what the server holds now.
      if (_gateOpen) unawaited(_loadTask(view));
    } else if (detailId.startsWith(scheduledTaskEditorPagePrefix)) {
      final key = detailId.substring(scheduledTaskEditorPagePrefix.length);
      // Another account's form, asked for again: dropped unseen, and this
      // account's task read afresh.
      if (_stale(_editors[key]?.owner)) _editors.remove(key)?.dispose();
      final editor = _editors[key];
      if (editor != null) {
        // Back from its Days or Advanced Schedule page.
        await _applyEditor(l10n, editor);
        return;
      }
      final opened = _editors[key] = _TaskEditor(key, _notifier.captureOwner());
      if (key == scheduledTaskNewKey) {
        final draft = AutomationDraft.create(
          schedule: const DailyAutomationSchedule(hour: 9, minute: 0),
        );
        opened
          ..start = draft
          ..adopt(draft);
        await _applyEditor(l10n, opened);
      } else {
        await _applyEditor(l10n, opened);
        if (_gateOpen) unawaited(_loadEditor(opened));
      }
    } else if (detailId.startsWith(scheduledTaskDaysPagePrefix)) {
      final editor =
          _editors[detailId.substring(scheduledTaskDaysPagePrefix.length)];
      // Shown again (a back swipe let go of, say) while the pages are
      // closed to the account: none of the schedule comes back.
      if (!_gateOpen) {
        await _surface.applyDetail(_gatePage(l10n, detailId));
      } else if (_stale(editor?.owner)) {
        await _surface.applyDetail(_accountChangedPage(l10n, detailId));
      } else if (editor != null) {
        await _surface.applyDetail(_buildDaysPage(l10n, _clock(l10n), editor));
      }
    } else if (detailId.startsWith(scheduledTaskRulePagePrefix)) {
      final editor =
          _editors[detailId.substring(scheduledTaskRulePagePrefix.length)];
      if (!_gateOpen) {
        await _surface.applyDetail(_gatePage(l10n, detailId));
      } else if (_stale(editor?.owner)) {
        await _surface.applyDetail(_accountChangedPage(l10n, detailId));
      } else if (editor != null) {
        await _surface.applyDetail(_buildRulePage(l10n, _clock(l10n), editor));
      }
    }
  }

  @override
  void pageLeft(String detailId) {
    if (detailId == scheduledTasksPageId) {
      _listShown = false;
      _listNotice = null;
    } else if (detailId.startsWith(scheduledTaskPagePrefix)) {
      final taskId = Uri.decodeComponent(
        detailId.substring(scheduledTaskPagePrefix.length),
      );
      // Its Run Now stops being watched; what it started stays started.
      _tasks.remove(taskId)?.stopPolling();
    } else if (detailId.startsWith(scheduledTaskEditorPagePrefix)) {
      // Left, the edit is abandoned.
      _editors
          .remove(detailId.substring(scheduledTaskEditorPagePrefix.length))
          ?.dispose();
    }
    _stopFollowingWhenIdle();
  }

  @override
  void settingsClosed() {
    _listShown = false;
    _listNotice = null;
    for (final view in _tasks.values) {
      view.stopPolling();
    }
    _tasks.clear();
    for (final editor in _editors.values) {
      editor.dispose();
    }
    _editors.clear();
    _stopFollowingWhenIdle();
  }

  // -- Following the app while the pages are open --------------------------

  /// Follows what decides whether the pages are open to the account at all.
  void _follow() {
    if (_following.isNotEmpty) return;
    void redraw(Object? _, Object? _) => _queueRedraw();
    // Back from the device's settings, say, with the 12 or 24 hour clock
    // changed: the times shown follow.
    _lifecycle ??= AppLifecycleListener(
      onResume: () {
        if (_ref.mounted) _queueRedraw();
      },
    );
    _following.addAll([
      _ref.listen(automationsAvailableProvider, redraw),
      _ref.listen(
        appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
        redraw,
      ),
      _ref.listen(userPermissionsProvider, redraw),
      _ref.listen(channelsFeatureEnabledProvider, redraw),
      _ref.listen(currentUserProvider2, redraw),
    ]);
  }

  /// Follows the account's tasks and what they name, once the pages are
  /// open to it. Behind Advanced or for an account without tasks, nothing
  /// is read.
  void _followData() {
    if (_followingData.isNotEmpty) return;
    void redraw(Object? _, Object? _) => _queueRedraw();
    _followingData.addAll([
      _ref.listen(automationsProvider, redraw),
      _ref.listen(modelsProvider, redraw),
      _ref.listen(channelsListProvider, redraw),
      _ref.listen(foldersProvider, redraw),
      _ref.listen(automationTerminalsProvider, redraw),
    ]);
  }

  void _stopFollowingWhenIdle() {
    if (_listShown || _tasks.isNotEmpty || _editors.isNotEmpty) return;
    for (final subscription in [..._following, ..._followingData]) {
      subscription.close();
    }
    _following.clear();
    _followingData.clear();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  AppLifecycleListener? _lifecycle;

  /// Page [pageId] while the pages are closed to the account: why.
  NativeSheetDetailConfig _gatePage(AppLocalizations l10n, String pageId) =>
      buildScheduledTasksPage(
        l10n,
        _clock(l10n),
        ScheduledTasksListState(
          advanced: _ref.read(appSettingsProvider).advancedFeaturesEnabled,
          available: _ref.read(automationsAvailableProvider),
        ),
      ).withId(pageId);

  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() {
      _redrawQueued = false;
      unawaited(_applyShown());
    });
  }

  Future<void> _applyShown() async {
    final l10n = _l10n;
    if (l10n == null) return;
    if (_listShown) await _applyList(l10n);
    for (final view in _tasks.values.toList()) {
      await _applyTask(l10n, view);
    }
    for (final editor in _editors.values.toList()) {
      await _applyEditor(l10n, editor, withPages: false);
    }
  }

  // -- The list ------------------------------------------------------------

  Future<void> _applyList(AppLocalizations l10n) async {
    if (!_gateOpen) {
      await _surface.applyDetail(_gatePage(l10n, scheduledTasksPageId));
      return;
    }
    _followData();
    final async = _ref.read(automationsProvider);
    final data = async.asData?.value;
    final pendingStatus = _pendingStatus;
    final pendingQuery = _pendingQuery;
    final state = ScheduledTasksListState(
      advanced: _ref.read(appSettingsProvider).advancedFeaturesEnabled,
      available: _ref.read(automationsAvailableProvider),
      data: data,
      loading: async.isLoading,
      status: pendingStatus ?? data?.status ?? AutomationStatusFilter.all,
      query: pendingQuery ?? data?.query ?? '',
      awaitingFilter:
          _refreshing &&
          data != null &&
          ((pendingStatus != null && pendingStatus != data.status) ||
              (pendingQuery != null && pendingQuery != data.query)),
      refreshing: _refreshing,
      loadingMore: _loadingMore,
      busy: Set.of(_listBusy),
      notice: _listNotice,
    );
    await _surface.applyDetail(
      buildScheduledTasksPage(l10n, _clock(l10n), state),
      detailSheets: _unknownPages([
        for (final task in data?.items ?? const <Automation>[])
          buildNativeLoadingDetail(
            l10n: l10n,
            id: scheduledTaskPageId(task.id),
            title: task.name,
          ),
        buildNativeLoadingDetail(
          l10n: l10n,
          id: scheduledTaskEditorPageId(null),
          title: l10n.scheduledTaskNewTitle,
        ),
      ]),
    );
  }

  /// The account is captured on the action, before anything is awaited.
  Future<void> _refresh({String? query, AutomationStatusFilter? status}) async {
    final owner = _notifier.captureOwner();
    if (owner == null) return;
    final generation = ++_refreshGeneration;
    _refreshing = true;
    if (status != null) _pendingStatus = status;
    if (query != null) _pendingQuery = query.trim();
    final l10n = _l10n;
    if (l10n != null && _listShown) await _applyList(l10n);
    try {
      await _notifier.refresh(owner: owner, query: query, status: status);
    } catch (_) {
      // The list says it could not be read.
    } finally {
      // Only the newest request settles what is shown; an older one that
      // finishes later must not clear a filter the user picked since.
      if (generation == _refreshGeneration) {
        _refreshing = false;
        _pendingStatus = null;
        _pendingQuery = null;
      }
    }
    if (l10n != null && _listShown) await _applyList(l10n);
  }

  Future<void> _loadMore() async {
    final owner = _notifier.captureOwner();
    if (owner == null || _loadingMore) return;
    _loadingMore = true;
    final l10n = _l10n;
    if (l10n != null && _listShown) await _applyList(l10n);
    try {
      await _notifier.loadMore(owner: owner);
    } finally {
      _loadingMore = false;
    }
    if (l10n != null && _listShown) await _applyList(l10n);
  }

  /// A change made from a task's row on the list, for the account the list
  /// was drawn for.
  Future<void> _listChange(
    AppLocalizations l10n,
    String taskId,
    Future<void> Function(AutomationsOwner owner) change, {
    required String failure,
  }) async {
    final owner = _notifier.captureOwner();
    if (owner == null || _listBusy.contains(taskId)) return;
    _listBusy.add(taskId);
    _listNotice = null;
    if (_listShown) await _applyList(l10n);
    try {
      await change(owner);
    } catch (error) {
      // Answered after another account signed in: the list shown now is that
      // account's, and says nothing of this change.
      if (_notifier.isCurrentOwner(owner)) {
        _listNotice = scheduledTaskErrorText(l10n, error, fallback: failure);
      }
    } finally {
      _listBusy.remove(taskId);
    }
    if (_listShown) await _applyList(l10n);
  }

  // -- A task's page -------------------------------------------------------

  _TaskNames _names() => (
    channels: _ref.read(channelsListProvider).asData?.value,
    folders: _folderOptions(),
    models: _ref.read(modelsProvider).asData?.value,
  );

  List<({String id, String name})>? _folderOptions() {
    final folders = _ref.read(foldersProvider).asData?.value;
    if (folders == null) return null;
    return [
      for (final f in automationFolderOptions(folders))
        (id: f.id, name: f.name),
    ];
  }

  /// Whether [owner] -- a page's or a form's -- is no longer the account
  /// signed in: what it read or holds is not shown to the one there now.
  bool _stale(AutomationsOwner? owner) =>
      owner != null && !_notifier.isCurrentOwner(owner);

  /// Page [pageId] of another account's task or form: only why it shows
  /// nothing, none of that account's data.
  NativeSheetDetailConfig _accountChangedPage(
    AppLocalizations l10n,
    String pageId,
  ) => NativeSheetDetailConfig(
    id: pageId,
    title: l10n.scheduledTasksTitle,
    announcement: l10n.scheduledTasksAccountChanged,
    items: [_warning('$pageId-error', l10n.scheduledTasksAccountChanged)],
  );

  bool _current(_TaskView view) =>
      identical(_tasks[view.taskId], view) &&
      view.owner != null &&
      _notifier.isCurrentOwner(view.owner!);

  Future<void> _applyTask(AppLocalizations l10n, _TaskView view) async {
    if (!identical(_tasks[view.taskId], view)) return;
    if (!_gateOpen) {
      await _surface.applyDetail(
        _gatePage(l10n, scheduledTaskPageId(view.taskId)),
      );
      return;
    }
    if (_stale(view.owner)) {
      await _surface.applyDetail(
        _accountChangedPage(l10n, scheduledTaskPageId(view.taskId)),
      );
      return;
    }
    _followData();
    final task = view.task;
    await _surface.applyDetail(
      _buildTaskPage(l10n, _clock(l10n), view, _names()),
      detailSheets: _unknownPages([
        if (task != null)
          buildNativeLoadingDetail(
            l10n: l10n,
            id: scheduledTaskEditorPageId(task.id),
            title: l10n.scheduledTaskEditTitle,
          ),
      ]),
    );
  }

  /// Of [pages], those not known yet. A page already known -- an editor
  /// open over this one, say -- keeps what it shows, rather than being
  /// drawn loading again by a redraw of the page that leads to it.
  List<NativeSheetDetailConfig> _unknownPages(
    List<NativeSheetDetailConfig> pages,
  ) {
    final known = _ref.read(settingsPagesProvider);
    return [
      for (final page in pages)
        if (!known.contains(page.id)) page,
    ];
  }

  Future<void> _loadTask(_TaskView view) async {
    final owner = view.owner;
    if (owner == null) {
      view.loadError = AutomationsOwnerChangedException();
      await _redrawTask(view);
      return;
    }
    try {
      final task = await _notifier.fetch(view.taskId, owner: owner);
      if (!_current(view)) return;
      view
        ..task = task
        ..requestedRun = null
        ..loadError = null;
    } catch (error) {
      if (!identical(_tasks[view.taskId], view)) return;
      // Failed after another account signed in: the page says so, as it
      // does once it can no longer act, not why the read failed.
      view.loadError = _notifier.isCurrentOwner(owner)
          ? error
          : AutomationsOwnerChangedException();
      await _redrawTask(view);
      return;
    }
    await _redrawTask(view);
    await _loadRuns(view, reset: true);
  }

  Future<void> _redrawTask(_TaskView view) async {
    final l10n = _l10n;
    if (l10n != null) await _applyTask(l10n, view);
  }

  Future<void> _loadRuns(_TaskView view, {required bool reset}) async {
    final owner = view.owner;
    if (owner == null || view.runsLoading) return;
    view
      ..runsLoading = true
      ..runsFailed = false;
    await _redrawTask(view);
    final merges = view.runsMerges;
    try {
      final page = await _notifier.runs(
        view.taskId,
        skip: reset ? 0 : view.runs.length,
        owner: owner,
      );
      if (!_current(view)) return;
      // A Run Now read that landed while this one was on its way holds newer
      // runs than this page, so they are kept ahead of it.
      final keep = !reset || merges != view.runsMerges;
      final known = keep ? {for (final run in view.runs) run.id} : <String>{};
      view
        ..runs = [
          if (keep) ...view.runs,
          for (final run in page)
            if (known.add(run.id)) run,
        ]
        // A page shorter than the page size is the last one.
        ..hasMoreRuns = page.length >= automationRunsPageSize;
    } catch (_) {
      // Refused for an account since gone: the page says the account
      // changed, not that its history failed.
      if (_current(view)) view.runsFailed = true;
    } finally {
      view.runsLoading = false;
    }
    await _redrawTask(view);
  }

  /// Moves the switch at once and asks the server. A refusal puts the switch
  /// back and says why.
  Future<void> _setActive(
    AppLocalizations l10n,
    _TaskView view,
    bool active,
  ) async {
    final owner = view.owner;
    if (owner == null ||
        view.pendingActive != null ||
        view.runPhase == ScheduledTaskRunPhase.requesting) {
      return;
    }
    view
      ..pendingActive = active
      ..error = null;
    await _redrawTask(view);
    try {
      final task = await _notifier.setActive(view.taskId, active, owner: owner);
      // A change made for the previous account stays made; it is not shown
      // as this account's task.
      if (!_current(view)) return;
      view.task = task;
    } catch (error) {
      if (!identical(_tasks[view.taskId], view)) return;
      view.error = scheduledTaskErrorText(
        l10n,
        error,
        fallback: l10n.scheduledTaskChangeFailed,
      );
    } finally {
      view.pendingActive = null;
    }
    await _redrawTask(view);
  }

  /// Asks the server to run the task once, then reads history until a run
  /// newer than the request shows, for up to [scheduledTaskRunPollLimit]
  /// reads. The request's reply only means the server accepted it.
  Future<void> _run(AppLocalizations l10n, _TaskView view) async {
    final owner = view.owner;
    if (owner == null || view.runBusy || view.pendingActive != null) return;
    view
      ..stopPolling()
      ..runPhase = ScheduledTaskRunPhase.requesting
      ..error = null;
    await _redrawTask(view);
    try {
      // What history held right before the request. A run is the requested
      // one only if it is not one of these and is not older than the newest
      // of them. History is read again first: a scheduled run that finished
      // after the page loaded would otherwise pass for the requested one.
      var latest = const <AutomationRun>[];
      try {
        latest = await _notifier.runs(view.taskId, owner: owner);
      } on AutomationsOwnerChangedException {
        rethrow;
      } catch (_) {
        // The request still goes; what the page knew is the baseline.
      }
      if (!_current(view)) throw AutomationsOwnerChangedException();
      final baseline = AutomationRunBaseline.of(
        runs: [...latest, ...view.runs, ?view.requestedRun],
        task: view.task,
      );
      final accepted = await _notifier.run(view.taskId, owner: owner);
      if (!_current(view)) throw AutomationsOwnerChangedException();
      view
        ..task = accepted
        ..runPhase = ScheduledTaskRunPhase.waiting
        ..runPolls = 0
        ..runPoll = Timer.periodic(
          scheduledTaskRunPollInterval,
          (_) => _pollRun(l10n, view, baseline),
        );
    } catch (error) {
      if (!identical(_tasks[view.taskId], view)) return;
      view
        ..runPhase = ScheduledTaskRunPhase.idle
        ..error = scheduledTaskErrorText(
          l10n,
          error,
          fallback: l10n.scheduledTaskRunRequestFailed,
        );
    }
    await _redrawTask(view);
  }

  /// One history read while a run is awaited. It stops for good once the
  /// page is gone or belongs to an account that is no longer signed in.
  Future<void> _pollRun(
    AppLocalizations l10n,
    _TaskView view,
    AutomationRunBaseline baseline,
  ) async {
    if (!identical(_tasks[view.taskId], view)) {
      view.stopPolling();
      return;
    }
    final owner = view.owner;
    if (owner == null || !_notifier.isCurrentOwner(owner)) {
      view
        ..stopPolling()
        ..runPhase = ScheduledTaskRunPhase.idle
        ..error = l10n.scheduledTasksAccountChanged;
      await _redrawTask(view);
      return;
    }
    if (view.runPollInFlight) return;
    view
      ..runPollInFlight = true
      ..runPolls += 1;
    try {
      final page = await _notifier.runs(view.taskId, owner: owner);
      if (!_current(view)) throw AutomationsOwnerChangedException();
      if (view.runPhase != ScheduledTaskRunPhase.waiting) return;
      // A run without a time can only be told apart from older ones when
      // nothing ran before.
      final requested = baseline.requestedRun(page);
      view.runsMerges++;
      view.runs = mergeAutomationRuns(page, view.runs);
      if (view.runsFailed || view.runs.length == page.length) {
        view.hasMoreRuns = page.length >= automationRunsPageSize;
      }
      view.runsFailed = false;
      if (requested != null) {
        view
          ..requestedRun = requested
          ..runPhase = requested.succeeded
              ? ScheduledTaskRunPhase.finished
              : ScheduledTaskRunPhase.failed
          ..stopPolling();
      }
    } on AutomationsOwnerChangedException {
      view
        ..stopPolling()
        ..runPhase = ScheduledTaskRunPhase.idle
        ..error = l10n.scheduledTasksAccountChanged;
    } catch (_) {
      // A failed read is tried again on the next tick.
    } finally {
      view.runPollInFlight = false;
      if (view.runPhase == ScheduledTaskRunPhase.waiting &&
          view.runPolls >= scheduledTaskRunPollLimit) {
        view
          ..stopPolling()
          ..runPhase = ScheduledTaskRunPhase.timedOut;
      }
    }
    await _redrawTask(view);
  }

  Future<void> _delete(AppLocalizations l10n, _TaskView view) async {
    final owner = view.owner;
    if (view.task == null || view.deleting) return;
    view
      ..deleting = true
      ..error = null;
    await _redrawTask(view);
    try {
      if (owner == null) throw AutomationsOwnerChangedException();
      await _notifier.remove(view.taskId, owner: owner);
      if (!_current(view)) return;
      view.stopPolling();
      await _surface.closeDetail(scheduledTaskPageId(view.taskId));
      return;
    } catch (error) {
      if (!identical(_tasks[view.taskId], view)) return;
      view.error = scheduledTaskErrorText(
        l10n,
        error,
        fallback: l10n.errorMessage,
      );
    } finally {
      view.deleting = false;
    }
    await _redrawTask(view);
  }

  /// Opens what a run produced, for the account the page was opened for. A
  /// page that outlived an account switch refuses rather than taking the
  /// next account to a chat that is not theirs.
  Future<void> _openResult(
    AppLocalizations l10n,
    _TaskView view,
    String runId,
  ) async {
    final run = view.runs
        .where((candidate) => candidate.id == runId)
        .firstOrNull;
    if (run == null) return;
    final owner = view.owner;
    if (owner == null || !_notifier.isCurrentOwner(owner)) {
      view.error = l10n.scheduledTasksAccountChanged;
      await _redrawTask(view);
      return;
    }
    final channelId = run.resultChannelId;
    final chatId = run.resultChatId;
    if (channelId == null && chatId == null) return;
    // The result opens over the app, so Settings closes first.
    final bridge = NativeSheetBridge.instance;
    if (bridge.settingsSheetOpen) await bridge.dismiss();
    if (!_notifier.isCurrentOwner(owner)) return;
    if (channelId != null) {
      NavigationService.router.goNamed(
        RouteNames.channel,
        pathParameters: {'id': channelId},
      );
      return;
    }
    final originRoute = NavigationService.currentRoute;
    final originRevision = NavigationService.currentRouteRevision;
    final when =
        dateTimeFromEpochNanoseconds(run.createdAtNs) ?? DateTime.now();
    final result = await _ref
        .read(conversationSelectionProvider.notifier)
        .select(
          Conversation(
            id: chatId!,
            title: view.task?.name ?? '',
            createdAt: when,
            updatedAt: when,
          ),
        );
    if (!_notifier.isCurrentOwner(owner) ||
        NavigationService.currentRoute != originRoute ||
        NavigationService.currentRouteRevision != originRevision) {
      return;
    }
    switch (result.disposition) {
      case ConversationSelectionDisposition.committed:
        NavigationService.router.go(Routes.chat);
      case ConversationSelectionDisposition.canceled:
        break;
      case ConversationSelectionDisposition.failed:
        final context = NavigationService.context;
        if (context != null && context.mounted) {
          UiUtils.showMessage(
            context,
            l10n.scheduledTaskOpenResultFailed,
            isError: true,
          );
        }
    }
  }

  // -- The editor ----------------------------------------------------------

  bool _editorCurrent(_TaskEditor editor) =>
      identical(_editors[editor.key], editor) &&
      editor.owner != null &&
      _notifier.isCurrentOwner(editor.owner!);

  Future<void> _loadEditor(_TaskEditor editor) async {
    final owner = editor.owner;
    final l10n = _l10n;
    if (owner == null) {
      editor.loadError = AutomationsOwnerChangedException();
      if (l10n != null) await _applyEditor(l10n, editor);
      return;
    }
    editor.loadError = null;
    try {
      final task = await _notifier.fetch(
        Uri.decodeComponent(editor.key),
        owner: owner,
      );
      // The read refuses an answer for an account that is gone, but this
      // also covers the account changing between that check and this line.
      if (!_editorCurrent(editor)) return;
      editor.adopt(AutomationDraft.edit(task));
    } catch (error) {
      if (!identical(_editors[editor.key], editor)) return;
      editor.loadError = error;
    }
    if (l10n != null) await _applyEditor(l10n, editor);
  }

  /// The values the editor's account can pick now.
  _EditorOptions _options(_TaskEditor editor) {
    final draft = editor.draft;
    final terminalsAsync = _ref.read(automationTerminalsProvider);
    final terminals = terminalsAsync.asData?.value;
    final terminalId = draft?.terminalId;
    final terminal = terminals
        ?.where((server) => server.selectionId == terminalId)
        .firstOrNull;
    // A coding agent posts only to a chat, so its terminal is asked for them
    // only then.
    final channel = draft?.target.isChannel ?? false;
    final query = terminal == null || channel
        ? null
        : (
            terminalId: terminal.selectionId,
            terminalName: terminal.displayName,
            cwd: editor.agentCwd,
            automationId: draft?.original?.id,
          );
    if (query != editor.agentsQuery) {
      editor.agents?.close();
      editor
        ..agentsQuery = query
        ..agents = query == null
            ? null
            : _ref.listen(
                automationAgentModelsProvider(query),
                (_, _) => _queueRedraw(),
              );
    }
    final agentsAsync = editor.agents?.read();
    final List<Model>? agents;
    if (terminalId == null) {
      agents = const <Model>[];
    } else if (channel || terminals == null) {
      agents = null;
    } else if (terminal == null) {
      // The server lists its terminals and this one is not among them.
      agents = const <Model>[];
    } else {
      // Null while loading, and when the terminal could not be asked.
      agents = agentsAsync?.asData?.value;
    }
    final runsAgent = draft?.runsAgent ?? false;
    final serverModels = _ref
        .read(modelsProvider)
        .asData
        ?.value
        .where(automationModelSelectable)
        .toList();
    final models = serverModels == null ? null : [...serverModels, ...?agents];
    final channelList = _ref.read(channelsListProvider).asData?.value;
    final user = _ref.read(currentUserProvider2);
    final permissions =
        _ref.read(userPermissionsProvider).asData?.value ??
        const <String, dynamic>{};
    final enabled = _ref.read(channelsFeatureEnabledProvider);
    final access = {
      for (final c in channelList ?? const <Channel>[])
        c.id: automationChannelAccess(
          c,
          user: user,
          channelsEnabled: enabled,
          permissions: permissions,
        ),
    };
    return (
      models: models,
      terminals: terminals,
      agentsLoading:
          runsAgent &&
          (terminalsAsync.isLoading || (agentsAsync?.isLoading ?? false)),
      agentsUnknown: runsAgent && agents == null,
      channels: channelList
          ?.where((c) => access[c.id] != AutomationChannelAccess.unavailable)
          .toList(),
      access: access,
      folders: _folderOptions(),
    );
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    _TaskEditor editor, {
    bool withPages = true,
  }) async {
    if (!identical(_editors[editor.key], editor)) return;
    // Closed to the account, or another account's form: its Days and
    // Advanced Schedule pages too, when open over it, keep none of the
    // schedule on screen.
    final closed = !_gateOpen;
    if (closed || _stale(editor.owner)) {
      for (final prefix in [
        scheduledTaskEditorPagePrefix,
        scheduledTaskDaysPagePrefix,
        scheduledTaskRulePagePrefix,
      ]) {
        final pageId = '$prefix${editor.key}';
        await _surface.applyDetail(
          closed ? _gatePage(l10n, pageId) : _accountChangedPage(l10n, pageId),
        );
      }
      editor.pagesClosed = true;
      return;
    }
    _followData();
    editor.shownEdited = editor.edited;
    final clock = _clock(l10n);
    await _surface.applyDetail(
      _buildEditorPage(l10n, clock, editor, _options(editor)),
      detailSheets: [
        if (withPages && editor.draft != null) ...[
          _buildDaysPage(l10n, clock, editor),
          _buildRulePage(l10n, clock, editor),
        ],
      ],
    );
    // Open again (Scheduled Tasks available once more): a Days or Advanced
    // Schedule page still open over the form shows the schedule again.
    // Asked again before each page: closed or switched meanwhile, the redraw
    // that did so has the last word.
    bool stillOpen() =>
        identical(_editors[editor.key], editor) &&
        _gateOpen &&
        !_stale(editor.owner);
    if (editor.pagesClosed && editor.draft != null && stillOpen()) {
      editor.pagesClosed = false;
      // Sent as pages of their own: one already open learns of it only so.
      await _surface.applyDetail(_buildDaysPage(l10n, clock, editor));
      if (!stillOpen()) return;
      await _surface.applyDetail(_buildRulePage(l10n, clock, editor));
    }
  }

  /// The editor's draft changed to [next]: the server's last word goes, and
  /// the pages that show it are drawn again.
  Future<void> _update(
    AppLocalizations l10n,
    _TaskEditor editor,
    AutomationDraft next, {
    bool redraw = true,
  }) async {
    editor
      ..draft = next
      ..error = null;
    if (redraw || editor.attempted || editor.edited != editor.shownEdited) {
      await _applyEditor(l10n, editor, withPages: false);
    }
  }

  void _setSchedule(_TaskEditor editor, AutomationSchedule schedule) {
    editor.rule = schedule.toRrule();
    editor.draft = editor.draft!.copyWith(schedule: schedule);
  }

  /// Starts a control schedule of [kind], keeping the time of day when there
  /// is one. This is the explicit change that replaces a rule the controls
  /// could not edit.
  AutomationSchedule _kindSchedule(
    AutomationSchedule? schedule,
    String kind,
  ) => automationScheduleOfKind(
    switch (kind) {
      'once' => AutomationScheduleKind.once,
      'weekly' => AutomationScheduleKind.weekly,
      _ => AutomationScheduleKind.daily,
    },
    // No schedule yet starts at 9:00, as a rule the controls cannot edit.
    current: schedule ?? DailyAutomationSchedule(hour: 9, minute: 0),
    now: DateTime.now(),
  );

  /// Moves the schedule to [hour]:[minute], keeping its kind and day(s).
  AutomationSchedule _timeSchedule(
    AutomationSchedule schedule,
    int hour,
    int minute,
  ) => automationScheduleAtTime(schedule, hour, minute);

  /// A choice from a picker: kept only while the account the editor opened
  /// for is still the one signed in. The choices came from that account.
  Future<bool> _stillOwned(AppLocalizations l10n, _TaskEditor editor) async {
    if (_editorCurrent(editor)) return true;
    if (identical(_editors[editor.key], editor)) {
      editor.error = l10n.scheduledTasksAccountChanged;
      await _applyEditor(l10n, editor, withPages: false);
    }
    return false;
  }

  /// Moves the task to terminal [id], or to none. A coding agent belongs to
  /// its terminal, so one chosen from another terminal is cleared.
  AutomationDraft _withTerminal(_TaskEditor editor, String? id) {
    final draft = editor.draft!;
    final agentTerminal = parseTerminalAgentModelId(draft.modelId.trim())
        ?.terminalId;
    final moved = id != draft.terminalId;
    if (id == null || moved) {
      // The folder belonged to the terminal: another, or one chosen later,
      // starts from its own default.
      editor.agentCwd = null;
    }
    final next = id == null
        ? draft.copyWith(clearTerminal: true)
        : moved
        ? draft.copyWith(clearTerminal: true).copyWith(terminalId: id)
        : draft.copyWith(terminalId: id);
    return agentTerminal != null && agentTerminal != id
        ? next.copyWith(modelId: '')
        : next;
  }

  Future<void> _pickChannel(
    AppLocalizations l10n,
    _TaskEditor editor,
    String picked,
  ) async {
    final owner = editor.owner;
    if (!await _stillOwned(l10n, editor)) return;
    final access = _options(editor).access;
    if (access[picked] == AutomationChannelAccess.needsWriteReadBack) {
      // The channel list does not say whether the account may post, so ask
      // the channel itself, for the account the editor was opened for.
      try {
        if (owner == null) throw AutomationsOwnerChangedException();
        final writable = await _notifier.channelWritable(picked, owner: owner);
        if (!_editorCurrent(editor)) throw AutomationsOwnerChangedException();
        if (!writable) {
          editor.error = l10n.scheduledTaskChannelNoWrite;
          await _applyEditor(l10n, editor, withPages: false);
          return;
        }
      } catch (error) {
        if (!identical(_editors[editor.key], editor)) return;
        editor.error = scheduledTaskErrorText(
          l10n,
          error,
          fallback: l10n.scheduledTaskSaveFailed,
        );
        await _applyEditor(l10n, editor, withPages: false);
        return;
      }
    }
    // The write check took a round trip, during which the form stayed live,
    // so the channel goes onto what is typed now. One who switched back to a
    // chat meanwhile is not sent to the channel anyway.
    final draft = editor.draft;
    if (draft == null || !draft.target.isChannel) return;
    await _update(
      l10n,
      editor,
      draft.copyWith(target: AutomationTarget.channel(picked)),
    );
  }

  Future<void> _save(AppLocalizations l10n, _TaskEditor editor) async {
    final draft = editor.draft;
    if (draft == null || editor.saving) return;
    final issues = _issues(draft, _options(editor));
    if (issues.isNotEmpty) {
      editor
        ..attempted = true
        ..error = null;
      await _applyEditor(l10n, editor);
      return;
    }
    // A saved task left as it was: Save only goes back, writing nothing.
    if (!draft.isNew && !editor.edited) {
      _editors.remove(editor.key)?.dispose();
      await _surface.closeDetail('$scheduledTaskEditorPagePrefix${editor.key}');
      return;
    }
    final owner = editor.owner;
    if (owner == null) {
      editor.error = l10n.scheduledTasksAccountChanged;
      await _applyEditor(l10n, editor, withPages: false);
      return;
    }
    editor
      ..attempted = true
      ..saving = true
      ..error = null;
    await _applyEditor(l10n, editor, withPages: false);
    try {
      if (draft.isNew) {
        await _notifier.create(draft.toForm(), owner: owner);
      } else {
        await _notifier.updateTask(
          draft.original!.id,
          draft.toForm(),
          owner: owner,
        );
      }
      // A save accepted for the previous account stays accepted, but the
      // form stays as typed and says the account changed.
      if (!_editorCurrent(editor)) throw AutomationsOwnerChangedException();
      _editors.remove(editor.key)?.dispose();
      await _surface.closeDetail('$scheduledTaskEditorPagePrefix${editor.key}');
      // The task's page, under the editor, shows what the server holds now.
      if (!draft.isNew) {
        final view = _tasks[draft.original!.id];
        if (view != null) unawaited(_loadTask(view));
      }
      return;
    } catch (error) {
      // The form keeps everything that was typed, whatever the reason.
      if (!identical(_editors[editor.key], editor)) return;
      editor.error = scheduledTaskErrorText(
        l10n,
        error,
        fallback: l10n.scheduledTaskSaveFailed,
      );
    } finally {
      editor.saving = false;
    }
    await _applyEditor(l10n, editor, withPages: false);
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (!id.startsWith(scheduledTaskRowPrefix)) return false;
    _l10n = l10n;
    final parts = id.substring(scheduledTaskRowPrefix.length).split(':');
    if (parts.length < 2) return true;
    final field = parts[0];
    final key = parts[1];
    final extra = parts.length > 2 ? Uri.decodeComponent(parts[2]) : null;
    if (key == scheduledTasksListKey) {
      switch (field) {
        case 'search' when value is String:
          // Each query goes as it is typed, without waiting for the last
          // one's answer; only the answer to the newest is shown.
          final asked =
              _pendingQuery ?? _ref.read(automationsProvider).value?.query;
          if (value.trim() != asked) unawaited(_refresh(query: value));
        case 'filter' when value is String:
          final status = AutomationStatusFilter.values.asNameMap()[value];
          if (status != null) await _refresh(status: status);
        case 'show-all':
          await _refresh(query: '', status: AutomationStatusFilter.all);
        case 'retry':
          await _refresh();
        case 'more':
          await _loadMore();
      }
      return true;
    }
    final taskId = Uri.decodeComponent(key);
    final view = _tasks[taskId];
    final editor = _editors[key];
    // A row of a task's page, or of the list's row for that task.
    switch (field) {
      case 'active' when editor == null && view != null && value is bool:
        await _setActive(l10n, view, value);
        return true;
      case 'active' when editor == null && extra != null:
        await _listChange(
          l10n,
          taskId,
          (owner) => _notifier.setActive(taskId, extra == 'on', owner: owner),
          failure: l10n.scheduledTaskChangeFailed,
        );
        return true;
      case 'delete' when view != null:
        await _delete(l10n, view);
        return true;
      case 'delete':
        await _listChange(
          l10n,
          taskId,
          (owner) => _notifier.remove(taskId, owner: owner),
          failure: l10n.errorMessage,
        );
        return true;
      case 'run' when view != null:
        await _run(l10n, view);
        return true;
      case 'reload' when view != null && editor == null:
        await _loadTask(view);
        return true;
      case 'runs-retry' when view != null:
        await _loadRuns(view, reset: true);
        return true;
      case 'runs-more' when view != null:
        await _loadRuns(view, reset: false);
        return true;
      case 'open-run' when view != null && extra != null:
        await _openResult(l10n, view, extra);
        return true;
    }
    if (editor == null) return true;
    if (field == 'reload') {
      await _loadEditor(editor);
      return true;
    }
    final draft = editor.draft;
    if (draft == null || editor.saving) return true;
    switch (field) {
      case 'name' when value is String:
        if (value == draft.name) return true;
        await _update(l10n, editor, draft.copyWith(name: value), redraw: false);
      case 'prompt' when value is String:
        if (value == draft.prompt) return true;
        await _update(
          l10n,
          editor,
          draft.copyWith(prompt: value),
          redraw: false,
        );
      case 'active' when value is bool:
        await _update(
          l10n,
          editor,
          draft.copyWith(isActive: value),
          redraw: false,
        );
      case 'terminal' when value is String:
        if (!await _stillOwned(l10n, editor)) return true;
        final next = value.isEmpty ? null : value;
        if (next == draft.terminalId) return true;
        await _update(l10n, editor, _withTerminal(editor, next));
      case 'cwd' when value is String:
        editor.agentCwd = value.trim();
        await _update(l10n, editor, draft.copyWith(terminalCwd: value));
      case 'model' when value is String:
        if (!await _stillOwned(l10n, editor)) return true;
        await _update(l10n, editor, draft.copyWith(modelId: value));
      case 'folder' when value is String:
        if (!await _stillOwned(l10n, editor)) return true;
        await _update(
          l10n,
          editor,
          value.isEmpty
              ? draft.copyWith(clearFolder: true)
              : draft.copyWith(folderId: value),
        );
      case 'channel' when value is String && value.isNotEmpty:
        await _pickChannel(l10n, editor, value);
      case 'target' when value is String:
        final channel = value == 'channel';
        if (draft.target.isChannel == channel) return true;
        await _update(
          l10n,
          editor,
          draft.copyWith(
            target: channel
                ? const AutomationTarget.channelPending()
                : const AutomationTarget.chat(),
          ),
        );
      case 'kind' when value is String && value != 'custom':
        _setSchedule(editor, _kindSchedule(draft.schedule, value));
        await _update(l10n, editor, editor.draft!);
        await _applyEditor(l10n, editor);
      case 'date' when value is String:
        final day = DateTime.tryParse(value);
        final schedule = draft.schedule;
        if (day == null || schedule is! OnceAutomationSchedule) return true;
        _setSchedule(
          editor,
          OnceAutomationSchedule(
            year: day.year,
            month: day.month,
            day: day.day,
            hour: schedule.hour,
            minute: schedule.minute,
          ),
        );
        await _update(l10n, editor, editor.draft!);
      case 'time' when value is String:
        final time = DateTime.tryParse(value);
        if (time == null) return true;
        _setSchedule(
          editor,
          _timeSchedule(draft.schedule, time.hour, time.minute),
        );
        await _update(l10n, editor, editor.draft!);
      case 'day' when extra != null:
        final schedule = draft.schedule;
        if (schedule is! WeeklyAutomationSchedule) return true;
        _setSchedule(
          editor,
          WeeklyAutomationSchedule(
            hour: schedule.hour,
            minute: schedule.minute,
            days: schedule.days.contains(extra)
                ? ({...schedule.days}..remove(extra))
                : {...schedule.days, extra},
          ),
        );
        editor.error = null;
        await _surface.applyDetail(_buildDaysPage(l10n, _clock(l10n), editor));
        // The editor, under the Days page, shows the days and now asks
        // before leaving.
        await _applyEditor(l10n, editor, withPages: false);
      case 'rule' when value is String:
        editor
          ..rule = value
          ..draft = draft.copyWith(schedule: AutomationSchedule.parse(value))
          ..error = null;
        await _surface.applyDetail(_buildRulePage(l10n, _clock(l10n), editor));
        await _applyEditor(l10n, editor, withPages: false);
      case 'save':
        await _save(l10n, editor);
    }
    return true;
  }
}
