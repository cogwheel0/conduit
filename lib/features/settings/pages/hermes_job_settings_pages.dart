import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_job_delivery.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_format.dart';
import 'package:conduit_core/features/hermes/utils/hermes_schedule_validation.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show
        hermesDeliverIncludesConduit,
        hermesDeliverWithConduit,
        kConduitHermesPluginName;
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../../shared/services/navigation_service.dart';
import '../../hermes/widgets/hermes_job_delivery_field.dart'
    show describeHermesJobDelivery, hermesDeliveryOptionLabel;
import '../../hermes/widgets/hermes_job_editor.dart' show hermesJobCatchUpLabel;
import '../../hermes/widgets/hermes_session_tile.dart'
    show openHermesSessionReading;
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'hermes_page_ids.dart';

/// Prefix of a scheduled agent's page; its URI-encoded id follows.
const hermesJobPagePrefix = 'hermes-job:';

/// Prefix of a scheduled agent's editor; the URI-encoded job id, or
/// [hermesNewJobKey] for a new one, follows.
const hermesJobEditorPagePrefix = 'hermes-job-edit:';

/// Prefix of an editor's Deliver To page; the editor's key follows.
const hermesJobDeliveryPagePrefix = 'hermes-job-deliver:';

/// The key of the editor of a new scheduled agent.
const hermesNewJobKey = 'new';

/// Prefix of the rows of the scheduled agents' pages.
const hermesJobRowPrefix = 'hermes-job.';

String hermesJobPageId(String jobId) =>
    '$hermesJobPagePrefix${Uri.encodeComponent(jobId)}';

/// The editor of job [jobId], or of a new one when it is null.
String hermesJobEditorPageId(String? jobId) =>
    '$hermesJobEditorPagePrefix'
    '${jobId == null ? hermesNewJobKey : Uri.encodeComponent(jobId)}';

/// A row of the scheduled agents' pages: `hermes-job.<field>:<key>`, with
/// [extra] after another colon.
String hermesJobRowId(String field, String key, [String? extra]) =>
    '$hermesJobRowPrefix$field:$key'
    '${extra == null ? '' : ':${Uri.encodeComponent(extra)}'}';

/// How often a shown list is read again while a run is in flight or being
/// stopped: a cancel lands at the run's next cancel check, about a second
/// after it is asked for.
const Duration _liveRunPollInterval = Duration(seconds: 2);

/// How often an idle list is read again, so a run the scheduler or another
/// client starts shows up with its Stop.
const Duration _idlePollInterval = Duration(seconds: 15);

/// What the scheduled agents' pages show.
@immutable
@visibleForTesting
final class HermesJobsState {
  const HermesJobsState({
    required this.jobs,
    this.failed = false,
    this.writable = true,
    this.desktop = false,
    this.stopUnsupported = false,
    this.stopping = const {},
    this.runPending = const {},
    this.busy = const {},
    this.creating = false,
    this.notice,
    this.deliveryOptions,
  });

  /// Null while the list is read.
  final List<HermesJob>? jobs;
  final bool failed;
  final bool writable;
  final bool desktop;
  final bool stopUnsupported;

  /// Jobs whose run is being stopped.
  final Set<String> stopping;

  /// Jobs whose Run Now is still waiting on its run.
  final Set<String> runPending;

  /// Jobs with a change of their own under way.
  final Set<String> busy;
  final bool creating;
  final String? notice;
  final HermesDeliveryOptions? deliveryOptions;

  bool canStop(HermesJob job) => desktop && writable && !stopUnsupported;

  bool runLive(HermesJob job) => job.runInFlight || runPending.contains(job.id);
}

String _jobKey(String jobId) => Uri.encodeComponent(jobId);

/// The scheduled agents of the Hermes connection in use: a row adding one,
/// then each agent, opening its page; its menu runs, pauses or deletes it.
@visibleForTesting
NativeSheetDetailConfig buildHermesJobsPage(
  AppLocalizations l10n,
  HermesJobsState state,
) {
  const pageId = hermesJobsPageId;
  NativeSheetItemConfig note(String id, String title, String symbol) =>
      NativeSheetItemConfig(
        id: '$pageId-$id',
        title: title,
        sfSymbol: symbol,
        kind: NativeSheetItemKind.info,
      );
  final jobs = state.jobs;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.hermesScheduledAgentsTitle,
    announcement: state.notice,
    sections: [
      if (state.notice != null)
        NativeSheetSectionConfig(
          items: [note('notice', state.notice!, 'info.circle')],
        ),
      NativeSheetSectionConfig(
        footer: state.writable ? null : l10n.hermesJobAdminDisabled,
        items: [
          NativeSheetItemConfig(
            id: hermesJobEditorPageId(null),
            title: l10n.hermesJobNew,
            sfSymbol: 'plus.circle',
            accent: true,
            disabled: !state.writable || state.creating,
            pending: state.creating ? true : null,
          ),
        ],
      ),
      if (state.failed)
        NativeSheetSectionConfig(
          items: [
            note(
              'failed',
              l10n.hermesJobLoadFailed,
              'exclamationmark.triangle',
            ),
          ],
        )
      else if (jobs == null)
        NativeSheetSectionConfig(
          items: [buildNativeLoadingItem(l10n, id: '$pageId-loading')],
        )
      else if (jobs.isEmpty)
        NativeSheetSectionConfig(
          items: [
            note(
              'empty',
              '${l10n.hermesNoSchedulesYet}\n${l10n.hermesJobEmptyMessage}',
              'clock',
            ),
          ],
        )
      else
        NativeSheetSectionConfig(
          items: [for (final job in jobs) _jobRow(l10n, state, job)],
        ),
    ],
  );
}

NativeSheetItemConfig _jobRow(
  AppLocalizations l10n,
  HermesJobsState state,
  HermesJob job,
) {
  final key = _jobKey(job.id);
  // Only the Desktop Gateway says how a run is going.
  final live = state.desktop && state.runLive(job);
  final stopping = state.stopping.contains(job.id);
  final busy = state.busy.contains(job.id);
  return NativeSheetItemConfig(
    id: hermesJobPageId(job.id),
    title: job.displayName,
    subtitle: [
      describeHermesCronSchedule(job.schedule),
      if (stopping)
        l10n.hermesJobStopping
      else if (live)
        l10n.hermesJobRunning
      else if (!job.enabled)
        l10n.hermesJobPaused,
    ].join(' · '),
    sfSymbol: job.enabled ? 'clock' : 'pause.circle',
    pending: busy || live ? true : null,
    rowActions: [
      if (state.writable && !busy && !job.runInFlight)
        NativeSheetRowAction(
          id: hermesJobRowId('run', key),
          label: l10n.hermesJobRunNow,
          sfSymbol: 'play',
        ),
      if (state.canStop(job) && live && !stopping)
        NativeSheetRowAction(
          id: hermesJobRowId('stop', key),
          label: l10n.hermesJobStop,
          sfSymbol: 'stop',
          destructive: true,
        ),
      if (state.writable && !busy)
        NativeSheetRowAction(
          id: hermesJobRowId('enabled', key, job.enabled ? 'off' : 'on'),
          label: job.enabled ? l10n.hermesJobPause : l10n.hermesJobResume,
          sfSymbol: job.enabled ? 'pause.circle' : 'play.circle',
        ),
      if (state.writable && !busy)
        NativeSheetRowAction(
          id: hermesJobRowId('delete', key),
          label: l10n.hermesJobDelete,
          sfSymbol: 'trash',
          destructive: true,
          confirmMessage: l10n.hermesJobDeleteMessage,
        ),
    ],
  );
}

String _formatTime(AppLocalizations l10n, DateTime value) =>
    DateFormat.yMMMd(l10n.localeName).add_jm().format(value.toLocal());

/// A scheduled agent's page: whether it runs, when, where its results go,
/// how its last run went, Run Now and Stop, its editor, its recent runs
/// (each opening its chat), and Delete.
@visibleForTesting
NativeSheetDetailConfig buildHermesJobPage(
  AppLocalizations l10n,
  HermesJobsState state,
  String jobId, {
  List<HermesSessionSummary>? runs,
  bool runsFailed = false,
}) {
  final pageId = hermesJobPageId(jobId);
  final key = _jobKey(jobId);
  final job = state.jobs?.where((job) => job.id == jobId).firstOrNull;
  NativeSheetItemConfig fact(
    String id,
    String title,
    String? value, [
    String symbol = 'info.circle',
  ]) => NativeSheetItemConfig(
    id: '$pageId-$id',
    title: title,
    subtitle: value,
    sfSymbol: symbol,
    kind: NativeSheetItemKind.info,
  );
  if (job == null) {
    return NativeSheetDetailConfig(
      id: pageId,
      title: l10n.hermesScheduledAgentsTitle,
      items: [
        if (state.jobs == null && !state.failed)
          buildNativeLoadingItem(l10n, id: '$pageId-loading')
        else
          fact(
            'gone',
            l10n.hermesJobLoadFailed,
            null,
            'exclamationmark.triangle',
          ),
      ],
    );
  }
  final live = state.runLive(job);
  final stopping = state.stopping.contains(job.id);
  final busy = state.busy.contains(job.id);
  final cancelReason = live ? null : job.lastCancelReason;
  final outcome = stopping
      ? l10n.hermesJobStopping
      : live
      ? l10n.hermesJobRunning
      : cancelReason != null
      ? (cancelReason.isEmpty
            ? l10n.hermesJobLastCancelledNoReason
            : l10n.hermesJobLastCancelled(cancelReason))
      : job.lastStatus?.isNotEmpty == true
      ? l10n.hermesLastStatus(job.lastStatus!)
      : null;
  return NativeSheetDetailConfig(
    id: pageId,
    title: job.displayName,
    announcement: state.notice,
    sections: [
      if (state.notice != null)
        NativeSheetSectionConfig(items: [fact('notice', state.notice!, null)]),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: hermesJobRowId('enabled', key),
            title: l10n.enabled,
            subtitle: job.enabled ? null : l10n.hermesJobPaused,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: job.enabled,
            disabled: !state.writable || busy,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          fact(
            'schedule',
            l10n.hermesJobScheduleLabel,
            hermesScheduleNeedsRawDisplay(job.schedule)
                ? '${describeHermesCronSchedule(job.schedule)}\n${job.schedule}'
                : describeHermesCronSchedule(job.schedule),
            'clock',
          ),
          if (state.desktop) ...[
            fact(
              'state',
              l10n.hermesJobStateLabel,
              job.state ??
                  (job.enabled
                      ? l10n.scheduledTaskStatusActive
                      : l10n.hermesJobPaused),
              'circle.dashed',
            ),
            fact(
              'delivery',
              l10n.hermesJobDeliveryLabel,
              describeHermesJobDelivery(
                l10n,
                job.deliveryTarget,
                options: state.deliveryOptions,
              ),
              'paperplane',
            ),
            if (job.lastRun != null)
              fact(
                'last',
                l10n.hermesJobLastLabel,
                _formatTime(l10n, job.lastRun!),
                'clock.arrow.circlepath',
              ),
            if (job.nextRun != null)
              fact(
                'next',
                l10n.hermesJobNextLabel,
                _formatTime(l10n, job.nextRun!),
                'calendar',
              ),
            if (outcome != null) fact('outcome', outcome, null),
            if (job.lastError?.isNotEmpty == true)
              fact('error', job.lastError!, null, 'exclamationmark.triangle'),
            if (job.lastDeliveryError?.isNotEmpty == true)
              fact(
                'delivery-error',
                l10n.hermesJobLastDeliveryError(job.lastDeliveryError!),
                null,
                'exclamationmark.triangle',
              ),
          ],
        ],
      ),
      if (state.writable)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: hermesJobRowId('run', key),
              title: l10n.hermesJobRunNow,
              sfSymbol: 'play',
              accent: true,
              showsDisclosure: false,
              pending: live ? true : null,
              disabled: busy || job.runInFlight,
            ),
            if (state.canStop(job) && (live || stopping))
              NativeSheetItemConfig(
                id: hermesJobRowId('stop', key),
                title: stopping ? l10n.hermesJobStopping : l10n.hermesJobStop,
                sfSymbol: 'stop',
                destructive: true,
                showsDisclosure: false,
                pending: stopping ? true : null,
                disabled: stopping,
              ),
            NativeSheetItemConfig(
              id: hermesJobEditorPageId(job.id),
              title: l10n.hermesJobEdit,
              sfSymbol: 'pencil',
              disabled: busy,
            ),
          ],
        ),
      if (state.desktop)
        NativeSheetSectionConfig(
          title: l10n.hermesJobRunHistory,
          items: [
            if (runsFailed)
              fact(
                'runs-failed',
                l10n.hermesJobRunsLoadFailed,
                null,
                'exclamationmark.triangle',
              )
            else if (runs == null)
              buildNativeLoadingItem(l10n, id: '$pageId-runs-loading')
            else if (runs.isEmpty)
              fact('runs-none', l10n.scheduledTaskHistoryEmpty, null, 'clock')
            else
              for (final run in runs)
                NativeSheetItemConfig(
                  id: hermesJobRowId('open-run', key, run.id),
                  title: run.title,
                  subtitle: run.updatedAt == null
                      ? null
                      : _formatTime(l10n, run.updatedAt!),
                  sfSymbol: 'bubble.left',
                  showsDisclosure: false,
                ),
          ],
        ),
      if (state.writable)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: hermesJobRowId('delete', key),
              title: l10n.hermesJobDelete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: busy,
              confirmMessage: l10n.hermesJobDeleteMessage,
            ),
          ],
        ),
    ],
  );
}

/// A scheduled agent's editor, as typed so far.
final class HermesJobDraft {
  HermesJobDraft({
    this.jobId,
    this.name = '',
    this.prompt = '',
    this.schedule = '',
    String? deliver,
    this.catchUp = HermesJobCatchUp.hermesDefault,
    this.deliveryEditable = true,
    this.connectionId,
    this.notifyConnectionId,
    this.notify,
    this.notifyHint,
  }) : deliversToConduit = hermesDeliverIncludesConduit(deliver),
       initialNotify = notify,
       initialCatchUp = catchUp,
       // Conduit's own target is "Notify me", not a row of the checklist:
       // a save keeps it as the job had it.
       initialDeliver = hermesDeliverWithConduit(
         parseHermesDeliveryTargets(deliver).join(','),
         notify: false,
       ),
       deliver = hermesDeliverWithConduit(
         parseHermesDeliveryTargets(deliver).join(','),
         notify: false,
       );

  factory HermesJobDraft.of(
    HermesJob job, {
    String? connectionId,
    String? notifyConnectionId,
    String? notifyHint,
  }) {
    // A job whose targets could not be read offers neither: a save would
    // write them back without the unread ones.
    final pushConnection = job.deliveryKnown ? notifyConnectionId : null;
    return HermesJobDraft(
      jobId: job.id,
      name: job.name ?? job.displayName,
      prompt: job.prompt,
      schedule: job.schedule,
      deliver: job.deliveryTarget,
      catchUp: job.catchUpChoice,
      deliveryEditable: job.deliveryKnown,
      connectionId: connectionId,
      notifyConnectionId: pushConnection,
      notify: pushConnection == null
          ? null
          : PushCoordinator.hermesJobNotifies(job.deliveryTarget),
      notifyHint: pushConnection == null ? null : notifyHint,
    );
  }

  final String? jobId;
  String name;
  String prompt;
  String schedule;
  String deliver;
  HermesJobCatchUp catchUp;
  final String? initialDeliver;
  final HermesJobCatchUp initialCatchUp;

  /// Whether the job's targets were read, so its Deliver To can be edited.
  final bool deliveryEditable;

  /// Whether the job delivers to Conduit already, which a save keeps.
  final bool deliversToConduit;

  /// The connection in use as the editor opened: the job is that one's.
  final String? connectionId;

  /// The connection push reaches, where "Notify me" is offered.
  final String? notifyConnectionId;

  /// "Notify me", or null where it is not offered; [notifyHint] says why
  /// it cannot be changed, when it cannot.
  bool? notify;
  final bool? initialNotify;
  final String? notifyHint;
  bool edited = false;
  bool shownEdited = false;
  bool showErrors = false;
  bool saving = false;
  String? notice;
}

/// A scheduled agent's editor: its name, prompt and schedule; on the
/// Desktop Gateway also what to do with missed runs and where results go.
@visibleForTesting
NativeSheetDetailConfig buildHermesJobEditorPage(
  AppLocalizations l10n,
  String key,
  HermesJobDraft draft, {
  required bool scheduling,
  HermesDeliveryOptions? deliveryOptions,
}) {
  final pageId = '$hermesJobEditorPagePrefix$key';
  final errors = validateHermesJobDraft(
    name: draft.name,
    prompt: draft.prompt,
    schedule: draft.schedule,
  );
  String? errorText(HermesJobFieldError? error, int maximum) =>
      switch (draft.showErrors ? error : null) {
        null => null,
        HermesJobFieldError.required => l10n.requiredFieldHelper,
        HermesJobFieldError.tooLong => l10n.hermesJobTooLong(maximum),
        HermesJobFieldError.invalidSchedule => l10n.hermesJobScheduleInvalid,
      };
  return NativeSheetDetailConfig(
    id: pageId,
    title: draft.jobId == null
        ? l10n.hermesJobNew
        : l10n.hermesJobEditorEditTitle,
    confirmActionId: hermesJobRowId('save', key),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: draft.saving,
    edited: draft.edited,
    announcement: draft.notice,
    sections: [
      if (draft.notice != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: '$pageId-notice',
              title: draft.notice!,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        footer: l10n.hermesJobScheduleHelp,
        items: [
          NativeSheetItemConfig(
            id: hermesJobRowId('name', key),
            title: l10n.name,
            subtitle: errorText(errors.name, kMaxHermesJobNameCharacters),
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: draft.name,
            placeholder: l10n.hermesJobNameHint,
          ),
          NativeSheetItemConfig(
            id: hermesJobRowId('prompt', key),
            title: l10n.hermesJobPromptLabel,
            subtitle: errorText(errors.prompt, kMaxHermesJobPromptCharacters),
            sfSymbol: 'text.bubble',
            kind: NativeSheetItemKind.multilineTextField,
            value: draft.prompt,
            placeholder: l10n.hermesJobPromptHint,
          ),
          NativeSheetItemConfig(
            id: hermesJobRowId('schedule', key),
            title: l10n.hermesJobScheduleLabel,
            subtitle: errorText(
              errors.schedule,
              kMaxHermesJobScheduleCharacters,
            ),
            sfSymbol: 'clock',
            kind: NativeSheetItemKind.textField,
            value: draft.schedule,
            placeholder: l10n.hermesJobScheduleHint,
          ),
        ],
      ),
      if (scheduling)
        NativeSheetSectionConfig(
          footer: l10n.hermesJobCatchUpHint,
          items: [
            NativeSheetItemConfig(
              id: hermesJobRowId('catch-up', key),
              title: l10n.hermesJobCatchUpLabel,
              sfSymbol: 'arrow.uturn.forward',
              kind: NativeSheetItemKind.segment,
              value: draft.catchUp.name,
              options: [
                for (final choice in HermesJobCatchUp.values)
                  NativeSheetOptionConfig(
                    id: choice.name,
                    label: hermesJobCatchUpLabel(l10n, choice),
                  ),
              ],
            ),
            if (draft.deliveryEditable)
              NativeSheetItemConfig(
                id: '$hermesJobDeliveryPagePrefix$key',
                title: l10n.hermesJobDeliverLabel,
                subtitle: describeHermesJobDelivery(
                  l10n,
                  draft.deliver,
                  options: deliveryOptions,
                ),
                sfSymbol: 'paperplane',
              ),
          ],
        ),
      if (draft.notifyHint != null || draft.notify != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: hermesJobRowId('notify', key),
              title: l10n.hermesJobNotifyTitle,
              // Shown but not changeable, with why.
              subtitle: draft.notifyHint ?? l10n.hermesJobNotifyDescription,
              sfSymbol: 'bell.badge',
              kind: NativeSheetItemKind.toggle,
              value: draft.notifyHint == null && (draft.notify ?? false),
              disabled: draft.notifyHint != null || draft.saving,
            ),
          ],
        ),
    ],
  );
}

/// Where a scheduled agent's results go: each target Hermes offers, as a
/// switch. Hermes takes several at once; the last cannot be turned off.
@visibleForTesting
NativeSheetDetailConfig buildHermesJobDeliveryPage(
  AppLocalizations l10n,
  String key,
  HermesJobDraft draft, {
  HermesDeliveryOptions? options,
  bool loading = false,
}) {
  final selected = parseHermesDeliveryTargets(draft.deliver);
  // Conduit's own target is "Notify me", on the editor.
  final all = HermesDeliveryOptions([
    for (final option in (options ?? HermesDeliveryOptions.localOnly).options)
      if (option.target != kConduitHermesPluginName) option,
  ]).withSelected(selected);
  // Room for `,conduit`, which saving or "Notify me" adds.
  final reserved = draft.deliversToConduit || draft.initialNotify != null
      ? kConduitHermesPluginName.length + 1
      : 0;
  List<HermesDeliveryOption> ofKind(Set<HermesDeliveryKind> kinds) =>
      all.where((option) => kinds.contains(option.kind)).toList();
  NativeSheetItemConfig row(HermesDeliveryOption option) {
    final checked = selected.contains(option.target);
    final locked = checked
        ? selected.length <= 1
        : !option.available ||
              toggleHermesDeliveryTarget(
                    draft.deliver,
                    option.target,
                    selected: true,
                  ).length >
                  kMaxHermesJobDeliverCharacters - reserved;
    return NativeSheetItemConfig(
      id: hermesJobRowId('deliver', key, option.target),
      title: hermesDeliveryOptionLabel(l10n, option),
      subtitle: option.available ? null : l10n.hermesJobDeliverNeedsHomeChannel,
      sfSymbol: switch (option.kind) {
        HermesDeliveryKind.local => 'tray',
        HermesDeliveryKind.platform => 'paperplane',
        HermesDeliveryKind.botChat => 'person.crop.circle',
        HermesDeliveryKind.room => 'person.3',
        HermesDeliveryKind.other => 'questionmark.circle',
      },
      kind: NativeSheetItemKind.toggle,
      value: checked,
      disabled: locked,
    );
  }

  final general = ofKind({HermesDeliveryKind.local, HermesDeliveryKind.other});
  final platforms = ofKind({HermesDeliveryKind.platform});
  final botChats = ofKind({HermesDeliveryKind.botChat});
  final rooms = ofKind({HermesDeliveryKind.room});
  return NativeSheetDetailConfig(
    id: '$hermesJobDeliveryPagePrefix$key',
    title: l10n.hermesJobDeliverLabel,
    sections: [
      NativeSheetSectionConfig(
        items: [
          for (final option in general) row(option),
          if (loading)
            buildNativeLoadingItem(
              l10n,
              id: '$hermesJobDeliveryPagePrefix$key-loading',
            ),
        ],
      ),
      if (platforms.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.hermesJobDeliverMessaging,
          items: [for (final option in platforms) row(option)],
        ),
      if (botChats.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.hermesJobDeliverBotChats,
          items: [for (final option in botChats) row(option)],
        ),
      if (rooms.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.hermesJobDeliverGroupChats,
          footer: l10n.hermesJobDeliverRoomHint,
          items: [for (final option in rooms) row(option)],
        ),
    ],
  );
}

/// Hermes' scheduled agents, in pages of Settings: the list, each agent's
/// page with its recent runs, and the editor with its Deliver To page.
/// While one of them is shown the list is read again now and then, so a
/// run started or stopped elsewhere shows.
class HermesJobSettingsPages extends SettingsPageModule {
  HermesJobSettingsPages(this._ref);

  final Ref _ref;
  bool _listening = false;
  bool _listShown = false;
  final Set<String> _shownJobs = {};
  final Map<String, HermesJobDraft> _drafts = {};
  final Map<String, List<HermesSessionSummary>?> _runs = {};
  final Set<String> _runsFailed = {};

  /// Counts the connections put in use. A request's outcome counts only
  /// while the one it was sent on is still in use: switching away and back
  /// is a new one, whose rows are not an earlier request's to change.
  int _connectionVisit = 0;

  /// Each job's last run as last read, to read its history again when a
  /// run came and went between two reads of the list.
  final Map<String, String> _lastRunSeen = {};
  final Map<String, String?> _stopping = {};
  final Set<String> _runPending = {};
  final Set<String> _busy = {};
  bool _stopUnsupported = false;
  bool _creating = false;
  String? _notice;
  HermesDeliveryOptions? _deliveryOptions;

  /// The connection delivery options are being read for, and were read
  /// for: another connection's are never offered.
  String? _deliveryLoadingFor;
  String? _deliveryFor;
  bool get _deliveryLoading => _deliveryLoadingFor != null;
  Set<String> _liveJobIds = const {};
  Timer? _pollTimer;
  Duration? _pollInterval;
  AppLocalizations? _l10n;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  bool get _desktop =>
      _ref.read(hermesConfigProvider).mode == HermesBackendMode.desktopGateway;

  @override
  bool ownsPage(String detailId) =>
      detailId == hermesJobsPageId ||
      detailId.startsWith(hermesJobPagePrefix) ||
      detailId.startsWith(hermesJobEditorPagePrefix) ||
      detailId.startsWith(hermesJobDeliveryPagePrefix);

  void _listen() {
    if (_listening) return;
    _listening = true;
    _ref.listen<AsyncValue<List<HermesJob>>>(hermesJobsProvider, (_, next) {
      final jobs = next.value;
      if (jobs != null) _onJobs(jobs);
      if (_listShown || _shownJobs.isNotEmpty) unawaited(_applyShown());
    });
    // Rows waiting on the last connection's requests are free on another
    // one, which may have jobs by the same ids, and a Stop left behind can
    // no longer be settled; its run history is not this one's. (A token
    // refresh keeps the connection, and its requests still say how they
    // went.)
    _ref.listen<String?>(hermesActiveConnectionIdProvider, (previous, next) {
      if (previous == next) return;
      _connectionVisit++;
      _busy.clear();
      _stopping.clear();
      _runPending.clear();
      _stopUnsupported = false;
      _runs.clear();
      _runsFailed.clear();
      _lastRunSeen.clear();
    });
  }

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    _listen();
    if (detailId == hermesJobsPageId) {
      _listShown = true;
      await _apply(l10n, hermesJobsPageId);
      unawaited(_readDeliveryOptions());
    } else if (detailId.startsWith(hermesJobPagePrefix)) {
      final jobId = Uri.decodeComponent(
        detailId.substring(hermesJobPagePrefix.length),
      );
      _shownJobs.add(jobId);
      await _apply(l10n, detailId);
      unawaited(_readRuns(l10n, jobId));
    } else if (detailId.startsWith(hermesJobEditorPagePrefix)) {
      final key = detailId.substring(hermesJobEditorPagePrefix.length);
      final draft = _draft(key);
      if (draft == null) return;
      await _applyEditor(l10n, key, draft);
      if (_desktop) unawaited(_readDeliveryOptions());
    } else if (detailId.startsWith(hermesJobDeliveryPagePrefix)) {
      final key = detailId.substring(hermesJobDeliveryPagePrefix.length);
      final draft = _drafts[key];
      if (draft == null) return;
      await _applyDelivery(l10n, key, draft);
    }
    _syncPolling();
  }

  @override
  void pageLeft(String detailId) {
    if (detailId == hermesJobsPageId) {
      _listShown = false;
      _notice = null;
    } else if (detailId.startsWith(hermesJobPagePrefix)) {
      _shownJobs.remove(
        Uri.decodeComponent(detailId.substring(hermesJobPagePrefix.length)),
      );
    } else if (detailId.startsWith(hermesJobEditorPagePrefix)) {
      // Left, the edit is abandoned.
      _drafts.remove(detailId.substring(hermesJobEditorPagePrefix.length));
    }
    _syncPolling();
  }

  @override
  void settingsClosed() {
    _listShown = false;
    _shownJobs.clear();
    _drafts.clear();
    _notice = null;
    _syncPolling();
  }

  HermesJobsState _state() {
    final jobs = _ref.read(hermesJobsProvider);
    final capabilities = _ref.read(hermesCapabilitiesProvider).value;
    return HermesJobsState(
      jobs: jobs.value,
      failed: jobs.hasError && jobs.value == null,
      writable: capabilities?.jobsAdmin ?? true,
      desktop: _desktop,
      stopUnsupported: _stopUnsupported,
      stopping: _stopping.keys.toSet(),
      runPending: Set.of(_runPending),
      busy: Set.of(_busy),
      creating: _creating,
      notice: _notice,
      deliveryOptions: _deliveryOptions,
    );
  }

  Future<void> _apply(AppLocalizations l10n, String pageId) async {
    // Read once as the pages open, then followed.
    if (_ref.read(hermesJobsProvider).value == null) {
      final listening = _ref.listen(hermesJobsProvider, (_, _) {});
      try {
        await _ref
            .read(hermesJobsProvider.future)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        // The page says the list could not be read.
      } finally {
        listening.close();
      }
    }
    final state = _state();
    // Pages already known keep what they show (an open editor included);
    // only new ones are drawn loading until they appear.
    final known = _ref.read(settingsPagesProvider);
    if (pageId == hermesJobsPageId) {
      await _surface.applyDetail(
        buildHermesJobsPage(l10n, state),
        detailSheets: _unknown(known, [
          for (final job in state.jobs ?? const <HermesJob>[]) ...[
            buildNativeLoadingDetail(
              l10n: l10n,
              id: hermesJobPageId(job.id),
              title: job.displayName,
            ),
            buildNativeLoadingDetail(
              l10n: l10n,
              id: hermesJobEditorPageId(job.id),
              title: l10n.hermesJobEditorEditTitle,
            ),
          ],
          buildNativeLoadingDetail(
            l10n: l10n,
            id: hermesJobEditorPageId(null),
            title: l10n.hermesJobNew,
          ),
        ]),
      );
      return;
    }
    final jobId = Uri.decodeComponent(
      pageId.substring(hermesJobPagePrefix.length),
    );
    await _surface.applyDetail(
      buildHermesJobPage(
        l10n,
        state,
        jobId,
        runs: _runs[jobId],
        runsFailed: _runsFailed.contains(jobId),
      ),
      detailSheets: _unknown(known, [
        buildNativeLoadingDetail(
          l10n: l10n,
          id: hermesJobEditorPageId(jobId),
          title: l10n.hermesJobEditorEditTitle,
        ),
      ]),
    );
  }

  static List<NativeSheetDetailConfig> _unknown(
    SettingsPagesState known,
    List<NativeSheetDetailConfig> pages,
  ) => [
    for (final page in pages)
      if (!known.contains(page.id)) page,
  ];

  /// Draws the list and each agent's page that is shown again.
  Future<void> _applyShown() async {
    final l10n = _l10n;
    if (l10n == null) return;
    if (_listShown) await _apply(l10n, hermesJobsPageId);
    for (final jobId in _shownJobs.toList()) {
      await _apply(l10n, hermesJobPageId(jobId));
    }
  }

  void _onJobs(List<HermesJob> jobs) {
    final live = {
      for (final job in jobs)
        if (job.runInFlight) job.id,
    };
    // A run that ended (or was stopped) now has its final title, such as the
    // reason it was cancelled, in the run history.
    // So has one that started and ended between two reads of the list.
    final ranSince = <String>{};
    for (final job in jobs) {
      final lastRun = '${job.latestExecution?.id}|${job.lastRun}';
      final seen = _lastRunSeen[job.id];
      if (seen != null && seen != lastRun) ranSince.add(job.id);
      _lastRunSeen[job.id] = lastRun;
    }
    for (final jobId in {..._liveJobIds.difference(live), ...ranSince}) {
      _ref.invalidate(hermesJobRunsProvider(jobId));
      final l10n = _l10n;
      if (l10n != null && _shownJobs.contains(jobId)) {
        unawaited(_readRuns(l10n, jobId));
      }
    }
    _liveJobIds = live;
    _settleStops(jobs);
    _syncPolling(jobs);
  }

  void _settleStops(List<HermesJob> jobs) {
    final l10n = _l10n;
    if (_stopping.isEmpty || l10n == null) return;
    final settled = <String, HermesJobStopOutcome>{};
    for (final MapEntry(key: jobId, value: executionId) in _stopping.entries) {
      if (executionId == null) continue;
      final job = jobs.where((candidate) => candidate.id == jobId).firstOrNull;
      final outcome = hermesJobStopOutcome(job, executionId);
      if (outcome != HermesJobStopOutcome.pending) settled[jobId] = outcome;
    }
    if (settled.isEmpty) return;
    settled.keys.forEach(_stopping.remove);
    _notice = settled.values.last == HermesJobStopOutcome.cancelled
        ? l10n.hermesJobStopped
        : l10n.hermesJobFinishedBeforeStop;
  }

  /// Reads the Desktop Gateway's list again while one of these pages is
  /// shown: quickly while there is a run to watch, slowly otherwise.
  void _syncPolling([List<HermesJob>? jobs]) {
    final shown = _listShown || _shownJobs.isNotEmpty;
    final current = jobs ?? _ref.read(hermesJobsProvider).value;
    if (!shown || !_desktop || current == null) {
      _stopPolling();
      return;
    }
    final watching =
        _stopping.isNotEmpty ||
        _runPending.isNotEmpty ||
        current.any((job) => job.runInFlight);
    final interval = watching ? _liveRunPollInterval : _idlePollInterval;
    if (_pollTimer != null && _pollInterval == interval) return;
    _pollTimer?.cancel();
    _pollInterval = interval;
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollInterval = null;
  }

  void _poll() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    unawaited(_ref.read(hermesJobsProvider.notifier).refreshQuietly());
  }

  Future<void> _readDeliveryOptions() async {
    final connection = _ref.read(hermesActiveConnectionIdProvider);
    // Another connection in use: the last one's rooms and bots go.
    if (connection != _deliveryFor) {
      _deliveryFor = connection;
      _deliveryOptions = null;
    }
    if (!_desktop || _deliveryLoadingFor == connection) return;
    _deliveryLoadingFor = connection;
    final listening = _ref.listen(hermesJobDeliveryOptionsProvider, (_, _) {});
    try {
      final options = await _ref
          .read(hermesJobDeliveryOptionsProvider.future)
          .timeout(const Duration(seconds: 15));
      // Read for a connection no longer in use: not offered for this one.
      if (_ref.read(hermesActiveConnectionIdProvider) == connection) {
        _deliveryOptions = options;
      }
    } catch (_) {
      // Only local delivery and the job's own targets are offered.
    } finally {
      listening.close();
      if (_deliveryLoadingFor == connection) _deliveryLoadingFor = null;
    }
    if (_ref.read(hermesActiveConnectionIdProvider) != connection) return;
    final l10n = _l10n;
    if (l10n == null) return;
    // A copy: a draft can go (saved, left) while one is drawn. Each draft's
    // Deliver To page is drawn too, as it may be the one on screen.
    for (final entry in _drafts.entries.toList()) {
      if (!identical(_drafts[entry.key], entry.value)) continue;
      await _applyEditor(l10n, entry.key, entry.value);
      if (!identical(_drafts[entry.key], entry.value)) continue;
      await _applyDelivery(l10n, entry.key, entry.value);
    }
  }

  Future<void> _readRuns(AppLocalizations l10n, String jobId) async {
    if (!_desktop) return;
    final provider = hermesJobRunsProvider(jobId);
    final listening = _ref.listen(provider, (_, _) {});
    final visit = _connectionVisit;
    try {
      final runs = await _ref
          .read(provider.future)
          .timeout(const Duration(seconds: 15));
      // Read on a connection since left: not this one's history.
      if (visit != _connectionVisit) return;
      _runs[jobId] = runs;
      _runsFailed.remove(jobId);
    } catch (_) {
      if (visit != _connectionVisit) return;
      _runsFailed.add(jobId);
    } finally {
      listening.close();
    }
    if (_shownJobs.contains(jobId)) {
      await _apply(l10n, hermesJobPageId(jobId));
    }
  }

  HermesJobDraft? _draft(String key) {
    final open = _drafts[key];
    if (open != null) return open;
    final connectionId = _ref.read(hermesActiveConnectionIdProvider);
    final notifyConnection = _pushConnectionId();
    final hint = _notifyUnavailableHint(notifyConnection);
    if (key == hermesNewJobKey) {
      // A new job notifies by default where push reaches this connection.
      return _drafts[key] = HermesJobDraft(
        connectionId: connectionId,
        notifyConnectionId: notifyConnection,
        notify: notifyConnection == null ? null : true,
        notifyHint: hint,
      );
    }
    final jobId = Uri.decodeComponent(key);
    final job = _ref
        .read(hermesJobsProvider)
        .value
        ?.where((job) => job.id == jobId)
        .firstOrNull;
    if (job == null) return null;
    return _drafts[key] = HermesJobDraft.of(
      job,
      connectionId: connectionId,
      notifyConnectionId: notifyConnection,
      notifyHint: hint,
    );
  }

  /// The connection in use when push works for it, so a job's "Notify me"
  /// can reach this device; null otherwise.
  String? _pushConnectionId() {
    final connectionId = _ref.read(hermesActiveConnectionIdProvider);
    final push = _ref.read(pushStateIfUsedProvider);
    if (connectionId == null || push == null || !push.enabled) return null;
    final target = push.targets[PushTarget.hermesScope(connectionId)];
    return target?.status == PushStatus.on && !target!.optedOut
        ? connectionId
        : null;
  }

  /// Why "Notify me" can't be changed, or null when it can: with the
  /// Scheduled tasks kind off on this device, a job's pushes would not be
  /// shown, and the plugin is not even told to send them.
  String? _notifyUnavailableHint(String? connectionId) {
    final l10n = _l10n;
    if (connectionId == null || l10n == null) return null;
    final scheduled = _ref
        .read(appSettingsProvider)
        .notificationScheduledEnabled;
    return scheduled ? null : l10n.hermesJobNotifyNeedsScheduled;
  }

  /// Turns job [jobId]'s "Notify me" on or off. Answers whether that
  /// worked; a failure is logged here and said by the caller, apart from
  /// the change to the job itself.
  Future<bool> _trySetJobNotify(
    String connectionId,
    String jobId, {
    required bool notify,
  }) async {
    try {
      await _ref
          .read(pushCoordinatorProvider.notifier)
          .setHermesJobNotify(
            connectionId: connectionId,
            jobId: jobId,
            notify: notify,
          );
      return true;
    } catch (error, stackTrace) {
      DebugLogger.error(
        'hermes-job-notify-failed',
        scope: 'settings/hermes',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    } finally {
      if (_ref.mounted) _ref.invalidate(hermesJobsProvider);
    }
  }

  Future<void> _applyEditor(
    AppLocalizations l10n,
    String key,
    HermesJobDraft draft, {
    bool withPages = true,
  }) async {
    if (!identical(_drafts[key], draft)) return;
    draft.shownEdited = draft.edited;
    final scheduling = _desktop;
    await _surface.applyDetail(
      buildHermesJobEditorPage(
        l10n,
        key,
        draft,
        scheduling: scheduling,
        deliveryOptions: _deliveryOptions,
      ),
      detailSheets: [
        if (withPages && scheduling)
          buildHermesJobDeliveryPage(
            l10n,
            key,
            draft,
            options: _deliveryOptions,
            loading: _deliveryLoading,
          ),
      ],
    );
  }

  Future<void> _applyDelivery(
    AppLocalizations l10n,
    String key,
    HermesJobDraft draft,
  ) => _surface.applyDetail(
    buildHermesJobDeliveryPage(
      l10n,
      key,
      draft,
      options: _deliveryOptions,
      loading: _deliveryLoading,
    ),
  );

  Future<void> _save(
    AppLocalizations l10n,
    String key,
    HermesJobDraft draft,
  ) async {
    if (draft.saving) return;
    final name = draft.name.trim();
    final prompt = draft.prompt.trim();
    final schedule = draft.schedule.trim();
    if (!hermesJobDraftIsValid(
      validateHermesJobDraft(name: name, prompt: prompt, schedule: schedule),
    )) {
      draft.showErrors = true;
      await _applyEditor(l10n, key, draft, withPages: false);
      return;
    }
    final editing = draft.jobId != null;
    final scheduling = _desktop;
    final deliverChanged =
        !editing ||
        !hermesDeliveryTargetsMatch(draft.deliver, draft.initialDeliver);
    final catchUpChanged = !editing || draft.catchUp != draft.initialCatchUp;
    final deliver = scheduling && draft.deliveryEditable && deliverChanged
        ? hermesDeliverWithConduit(
            draft.deliver,
            notify: draft.deliversToConduit,
          )
        : null;
    final notifyConnection = draft.notifyConnectionId;
    final notify = draft.notifyHint == null ? draft.notify : null;
    final changesNotify =
        notifyConnection != null &&
        notify != null &&
        (editing ? notify != draft.initialNotify : notify);
    // Another connection became active while the editor was open (say, by
    // opening a notification): the job was meant for the one before.
    if (_ref.read(hermesApiServiceProvider) == null ||
        _ref.read(hermesActiveConnectionIdProvider) != draft.connectionId) {
      draft.notice = editing
          ? l10n.hermesJobUpdateFailed
          : l10n.hermesJobCreateFailed;
      await _applyEditor(l10n, key, draft, withPages: false);
      return;
    }
    draft
      ..saving = true
      ..notice = null;
    if (!editing) _creating = true;
    final visit = _connectionVisit;
    await _applyEditor(l10n, key, draft, withPages: false);
    // Checked again with nothing awaited before the request: a switch
    // while the editor was drawn busy would send it to the other one.
    if (visit != _connectionVisit) {
      draft
        ..saving = false
        ..notice = editing
            ? l10n.hermesJobUpdateFailed
            : l10n.hermesJobCreateFailed;
      if (!editing) _creating = false;
      await _applyEditor(l10n, key, draft, withPages: false);
      return;
    }
    final jobs = _ref.read(hermesJobsProvider.notifier);
    try {
      String? jobId = draft.jobId;
      if (editing) {
        await jobs.edit(
          draft.jobId!,
          name: name,
          prompt: prompt,
          schedule: schedule,
          deliver: deliver,
          catchUp: scheduling && catchUpChanged ? draft.catchUp : null,
        );
      } else {
        final job = await jobs.create(
          name: name,
          prompt: prompt,
          schedule: schedule,
          deliver: deliver,
          catchUp: scheduling ? draft.catchUp : HermesJobCatchUp.hermesDefault,
        );
        jobId = job?.id;
      }
      _notice = changesNotify
          ? null
          : editing
          ? l10n.hermesJobUpdated
          : l10n.hermesJobCreated;
      // Saved; the editor closes unless it was left and opened again
      // meanwhile, when the new visit's work is not this one's to close.
      if (identical(_drafts[key], draft)) {
        _drafts.remove(key);
        await _surface.closeDetail('$hermesJobEditorPagePrefix$key');
      }
      // New can be tapped again as the list is drawn.
      if (!editing) _creating = false;
      if (changesNotify) {
        // Said apart from the save, which has happened: a failure here must
        // not read as one to try again, which would make the job twice. The
        // job's rows wait meanwhile, since this step rewrites its delivery.
        if (jobId != null) _busy.add(jobId);
        await _applyShown();
        final changed =
            jobId != null &&
            await _trySetJobNotify(notifyConnection, jobId, notify: notify);
        // Another connection in use since: its pages say nothing of this
        // one, and its rows are not this request's to free.
        if (visit != _connectionVisit) return;
        if (jobId != null) _busy.remove(jobId);
        _notice = switch ((editing, changed)) {
          (true, true) => l10n.hermesJobUpdated,
          (true, false) => l10n.hermesJobUpdatedNotifyFailed,
          (false, true) => l10n.hermesJobCreated,
          (false, false) => l10n.hermesJobCreatedNotifyFailed,
        };
      }
      await _applyShown();
    } catch (_) {
      draft
        ..saving = false
        ..notice = editing
            ? l10n.hermesJobUpdateFailed
            : l10n.hermesJobCreateFailed;
      await _applyEditor(l10n, key, draft, withPages: false);
    } finally {
      draft.saving = false;
      if (!editing) _creating = false;
    }
  }

  /// Runs [action] for job [jobId], saying how it went; the job's rows
  /// wait meanwhile. Returns whether it went through.
  Future<bool> _mutate(
    String jobId,
    Future<void> Function() action, {
    required String failureMessage,
    String? successMessage,
  }) async {
    if (_busy.contains(jobId)) return false;
    final api = _ref.read(hermesApiServiceProvider);
    final visit = _connectionVisit;
    if (api == null) {
      _notice = failureMessage;
      await _applyShown();
      return false;
    }
    _busy.add(jobId);
    _notice = null;
    await _applyShown();
    // Checked again with nothing awaited before the request: a switch while
    // the rows were drawn busy would send it to the other connection.
    if (visit != _connectionVisit) return false;
    var succeeded = false;
    try {
      await action();
      succeeded = true;
    } catch (_) {
      // Said below, for the connection that asked.
    }
    // Another connection in use since -- even the same one again: its pages
    // say nothing of this request, and its rows are not this one's to free.
    if (visit != _connectionVisit) return false;
    _busy.remove(jobId);
    if (!succeeded) {
      _notice = failureMessage;
    } else if (successMessage != null) {
      _notice = successMessage;
    }
    await _applyShown();
    return succeeded;
  }

  Future<void> _runNow(AppLocalizations l10n, String jobId) async {
    if (_busy.contains(jobId)) return;
    _runPending.add(jobId);
    _syncPolling();
    var stopRequested = false;
    void onStop() => stopRequested = true;
    _stopRequests[jobId] = onStop;
    final visit = _connectionVisit;
    try {
      final started = await _mutate(
        jobId,
        () => _ref.read(hermesJobsProvider.notifier).runNow(jobId),
        failureMessage: l10n.hermesJobRunFailed,
      );
      // A Stop asked for meanwhile announces itself, not a started run.
      if (started && !stopRequested) {
        _notice = l10n.hermesJobStarted;
        await _applyShown();
      }
    } finally {
      // This call's own: another connection's Run Now for a job by the same
      // id may be waiting now, and keeps its state.
      if (identical(_stopRequests[jobId], onStop)) _stopRequests.remove(jobId);
      if (visit == _connectionVisit) _runPending.remove(jobId);
      _syncPolling();
      await _applyShown();
    }
  }

  /// Runs waiting on Run Now, told when Stop is asked for.
  final Map<String, void Function()> _stopRequests = {};

  Future<void> _stop(AppLocalizations l10n, String jobId) async {
    if (_stopping.containsKey(jobId)) return;
    _stopRequests[jobId]?.call();
    final notifier = _ref.read(hermesJobsProvider.notifier);
    final visit = _connectionVisit;
    // A reply from a connection since left says nothing about this one; a
    // client replaced on the same connection (a token refresh) still does.
    bool switched() => visit != _connectionVisit;
    _stopping[jobId] = null;
    _notice = null;
    _syncPolling();
    await _applyShown();
    try {
      final result = await notifier.stopRun(jobId);
      if (switched()) return;
      if (result.beforeStart) {
        // Its Run Now was withdrawn unsent: nothing ran to wait for.
        _stopping.remove(jobId);
        _notice = l10n.hermesJobStopped;
        return;
      }
      if (!result.cancelled) {
        _stopping.remove(jobId);
        _notice = l10n.hermesJobNothingToStop;
        return;
      }
      if (_stopping.containsKey(jobId)) {
        _stopping[jobId] = result.executionId ?? '';
      }
      await notifier.refreshQuietly();
    } on HermesJobStopUnsupportedException {
      if (switched()) return;
      _stopping.remove(jobId);
      _stopUnsupported = true;
      _notice = l10n.hermesJobStopUnsupported;
    } catch (_) {
      if (switched()) return;
      _stopping.remove(jobId);
      _notice = l10n.hermesJobStopFailed;
    } finally {
      _syncPolling();
      await _applyShown();
    }
  }

  Future<void> _openRun(String jobId, String runId) async {
    final run = _runs[jobId]
        ?.where((candidate) => candidate.id == runId)
        .firstOrNull;
    if (run == null) return;
    // The chat opens over the app, so Settings closes first.
    final bridge = NativeSheetBridge.instance;
    if (bridge.settingsSheetOpen) await bridge.dismiss();
    final context = NavigationService.context;
    if (context == null || !context.mounted) return;
    await openHermesSessionReading(
      context,
      _ref.read,
      run,
      invalidate: _ref.invalidate,
    );
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (!id.startsWith(hermesJobRowPrefix)) return false;
    _l10n = l10n;
    final parts = id.substring(hermesJobRowPrefix.length).split(':');
    if (parts.length < 2) return true;
    final field = parts[0];
    final key = parts[1];
    final extra = parts.length > 2 ? Uri.decodeComponent(parts[2]) : null;
    final jobId = Uri.decodeComponent(key);
    switch (field) {
      case 'run':
        // Followed by its own state, not by the row queue: a Desktop run is
        // waited on until it ends, and Stop must reach it meanwhile.
        unawaited(_runNow(l10n, jobId));
      case 'stop':
        await _stop(l10n, jobId);
      case 'enabled':
        // The page's switch sends where it is; a row's menu says which way.
        final bool enabled;
        if (extra != null) {
          enabled = extra == 'on';
        } else if (value is bool) {
          enabled = value;
        } else {
          return true;
        }
        await _mutate(
          jobId,
          () =>
              _ref.read(hermesJobsProvider.notifier).setEnabled(jobId, enabled),
          failureMessage: enabled
              ? l10n.hermesJobResumeFailed
              : l10n.hermesJobPauseFailed,
          successMessage: enabled
              ? l10n.hermesJobResumed
              : l10n.hermesJobPausedSuccess,
        );
      case 'delete':
        final deleted = await _mutate(
          jobId,
          () => _ref.read(hermesJobsProvider.notifier).delete(jobId),
          failureMessage: l10n.hermesJobDeleteFailed,
          successMessage: l10n.hermesJobDeleted,
        );
        if (deleted) await _surface.closeDetail(hermesJobPageId(jobId));
      case 'open-run' when extra != null:
        await _openRun(jobId, extra);
      case 'name' || 'prompt' || 'schedule' when value is String:
        final draft = _drafts[key];
        if (draft == null) return true;
        switch (field) {
          case 'name':
            if (draft.name == value) return true;
            draft.name = value;
          case 'prompt':
            if (draft.prompt == value) return true;
            draft.prompt = value;
          default:
            if (draft.schedule == value) return true;
            draft.schedule = value;
        }
        draft.edited = true;
        // Errors already shown follow the text as it is fixed.
        if (draft.showErrors) {
          await _applyEditor(l10n, key, draft, withPages: false);
        }
      case 'notify' when value is bool:
        final draft = _drafts[key];
        if (draft == null || draft.notifyHint != null) return true;
        draft
          ..notify = value
          ..edited = true;
        await _applyEditor(l10n, key, draft, withPages: false);
      case 'catch-up' when value is String:
        final draft = _drafts[key];
        final choice = HermesJobCatchUp.values.asNameMap()[value];
        if (draft == null || choice == null) return true;
        draft
          ..catchUp = choice
          ..edited = true;
      case 'deliver' when extra != null && value is bool:
        final draft = _drafts[key];
        if (draft == null) return true;
        draft
          ..deliver = toggleHermesDeliveryTarget(
            draft.deliver,
            extra,
            selected: value,
          )
          ..edited = true;
        await _applyDelivery(l10n, key, draft);
        // The editor, under the Deliver To page, now asks before leaving.
        await _applyEditor(l10n, key, draft, withPages: false);
      case 'save':
        final draft = _drafts[key];
        if (draft != null) await _save(l10n, key, draft);
    }
    return true;
  }
}
