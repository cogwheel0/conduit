import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_router/jaspr_router.dart';

import '../l10n/strings.g.dart';
import '../rpc/chat_providers.dart';
import '../rpc/hermes_providers.dart';
import '../widgets/form_field.dart';
import 'workspace/workspace_common.dart'
    show actionButton, badge, confirmBox, dayOf, statusLine, workspaceGo;

/// Hermes Agent (M7): its conversations, which open in the chat, and its
/// scheduled agents.
class HermesPage extends StatelessComponent {
  const HermesPage({super.key});

  @override
  Component build(BuildContext context) {
    final settings = context.watch(hermesSettingsProvider).value;
    return div(classes: 'flex h-screen min-h-0 bg-background text-foreground', [
      main_(classes: 'mx-auto w-full max-w-3xl space-y-6 overflow-y-auto p-6', [
        div(classes: 'flex items-center gap-2', [
          Link(
            to: '/',
            classes: 'rounded px-2 py-1 text-sm hover:bg-accent',
            attributes: <String, String>{'aria-label': t.app.back},
            child: Component.text('←'),
          ),
          h1(classes: 'flex-1 text-lg font-semibold', [
            Component.text(t.app.hermesAgentSettingsTitle),
          ]),
          a(
            href: '/settings/hermes',
            classes: 'text-xs text-muted-foreground hover:underline',
            [Component.text(t.desktop.desktopSettingsTitle)],
          ),
        ]),
        if (settings == null)
          statusLine(t.app.loadingShort)
        else if (!settings.usable)
          statusLine(t.app.hermesEnableSubtitle)
        else ...[
          const _Sessions(),
          const _Jobs(),
        ],
      ]),
    ]);
  }
}

class _Sessions extends StatefulComponent {
  const _Sessions();

  @override
  State<_Sessions> createState() => _SessionsState();
}

class _SessionsState extends State<_Sessions> {
  String? _renaming;
  String _title = '';
  String? _deleting;
  String? _status;

  Future<void> _run(
    Future<void> Function(HermesActions actions) action,
    String failed,
  ) async {
    try {
      await action(context.read(hermesActionsProvider));
      if (mounted) setState(() => _status = null);
    } on RpcError {
      if (mounted) setState(() => _status = failed);
    }
  }

  /// Opens [chatId] in the chat, the way a sidebar row does.
  void _open(BuildContext context, String chatId) {
    context.read(chatActionsProvider).select(chatId);
    workspaceGo(context, '/');
  }

  /// A new conversation with the Hermes model chosen.
  Future<void> _startNew(BuildContext context) async {
    final chats = context.read(chatActionsProvider);
    final models = context.read(modelListProvider).value?.models ?? const [];
    final agent = models
        .where((m) => m.id.startsWith('hermes:agent:'))
        .firstOrNull;
    chats.select(null);
    if (agent != null) await chats.selectModel(agent.id);
    if (mounted) workspaceGo(context, '/');
  }

  @override
  Component build(BuildContext context) {
    final sessions = context.watch(hermesSessionsProvider);
    final list = sessions.value?.sessions ?? const <HermesSessionDto>[];
    return section(
      classes: 'space-y-3',
      attributes: <String, String>{
        'aria-label': t.app.hermesConversationsTitle,
      },
      [
        div(classes: 'flex items-center gap-2', [
          h2(classes: 'flex-1 text-sm font-semibold', [
            Component.text(t.app.hermesConversationsTitle),
          ]),
          actionButton(
            t.app.newChat,
            primary: true,
            id: 'hermes-new-chat',
            onClick: () => unawaited(_startNew(context)),
          ),
        ]),
        if (_status case final status?) statusLine(status, error: true),
        if (sessions.isLoading && sessions.value == null)
          statusLine(t.app.loadingShort)
        else if (sessions.hasError && sessions.value == null)
          statusLine(t.app.hermesConversationsLoadError, error: true)
        else if (list.isEmpty)
          statusLine(t.app.hermesNoConversationsMessage),
        ul(classes: 'divide-y divide-border rounded border border-border', [
          for (final session in list)
            li(
              classes: 'space-y-2 px-3 py-2',
              attributes: <String, String>{'data-session': session.id},
              [
                div(classes: 'flex items-center gap-2', [
                  button(
                    [
                      Component.text(
                        session.title.isEmpty
                            ? t.app.hermesSessionUntitled
                            : session.title,
                      ),
                    ],
                    classes:
                        'min-w-0 flex-1 truncate text-left text-sm font-medium '
                        'hover:underline',
                    type: ButtonType.button,
                    onClick: () => _open(context, session.chatId),
                  ),
                  if (session.updatedAtMs case final ms?)
                    span(classes: 'text-xs text-muted-foreground', [
                      Component.text(dayOf(ms)),
                    ]),
                  actionButton(
                    t.app.rename,
                    onClick: () => setState(() {
                      _renaming = session.id;
                      _title = session.title;
                    }),
                  ),
                  actionButton(
                    t.app.hermesSessionFork,
                    onClick: () => unawaited(
                      _run(
                        (actions) async => _open(
                          context,
                          (await actions.fork(session.id)).chatId,
                        ),
                        t.app.hermesSessionForkFailed,
                      ),
                    ),
                  ),
                  actionButton(
                    t.app.delete,
                    destructive: true,
                    onClick: () => setState(() => _deleting = session.id),
                  ),
                ]),
                if (session.preview case final preview?)
                  p(classes: 'truncate text-xs text-muted-foreground', [
                    Component.text(preview),
                  ]),
                if (_renaming == session.id)
                  div(classes: 'flex items-end gap-2', [
                    div(classes: 'flex-1', [
                      textField(
                        id: 'hermes-session-title',
                        labelText: t.app.hermesSessionRenameTitle,
                        placeholder: t.app.hermesSessionNameHint,
                        value: _title,
                        autofocus: true,
                        onInput: (value) => setState(() => _title = value),
                      ),
                    ]),
                    actionButton(
                      t.app.save,
                      primary: true,
                      disabled: _title.trim().isEmpty,
                      onClick: () {
                        final title = _title.trim();
                        setState(() => _renaming = null);
                        unawaited(
                          _run(
                            (actions) => actions.rename(session.id, title),
                            t.app.hermesSessionRenameFailed,
                          ),
                        );
                      },
                    ),
                    actionButton(
                      t.app.cancel,
                      onClick: () => setState(() => _renaming = null),
                    ),
                  ]),
                if (_deleting == session.id)
                  confirmBox(
                    title: t.app.hermesSessionDeleteTitle,
                    message: t.app.hermesSessionDeleteMessage,
                    confirmText: t.app.delete,
                    onConfirm: () {
                      setState(() => _deleting = null);
                      unawaited(
                        _run(
                          (actions) => actions.delete(session.id),
                          t.app.hermesSessionDeleteFailed,
                        ),
                      );
                    },
                    onCancel: () => setState(() => _deleting = null),
                  ),
              ],
            ),
        ]),
      ],
    );
  }
}

class _Jobs extends StatefulComponent {
  const _Jobs();

  @override
  State<_Jobs> createState() => _JobsState();
}

class _JobsState extends State<_Jobs> {
  /// The job being edited; `''` for a new one.
  String? _editing;
  String _name = '';
  String _prompt = '';
  String _schedule = '';
  String? _deleting;
  String? _status;
  bool _statusIsError = false;

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _run(
    Future<void> Function(HermesActions actions) action, {
    required String done,
    required String failed,
  }) async {
    try {
      await action(context.read(hermesActionsProvider));
      context.invalidate(hermesJobsProvider);
      _say(done);
    } on RpcError {
      _say(failed, error: true);
    }
  }

  void _edit(HermesJobDto? job) => setState(() {
    _editing = job?.id ?? '';
    _name = job?.name ?? '';
    _prompt = job?.prompt ?? '';
    _schedule = job?.schedule ?? '';
  });

  @override
  Component build(BuildContext context) {
    final jobs = context.watch(hermesJobsProvider);
    final capabilities = context
        .watch(hermesStatusProvider)
        .value
        ?.capabilities;
    final admin = capabilities?.jobsAdmin ?? true;
    final list = jobs.value?.jobs ?? const <HermesJobDto>[];
    return section(
      classes: 'space-y-3',
      attributes: <String, String>{
        'aria-label': t.app.hermesScheduledAgentsTitle,
      },
      [
        div(classes: 'flex items-center gap-2', [
          h2(classes: 'flex-1 text-sm font-semibold', [
            Component.text(t.app.hermesScheduledAgentsTitle),
          ]),
          if (admin)
            actionButton(
              t.app.hermesJobNew,
              id: 'hermes-new-job',
              onClick: () => _edit(null),
            ),
        ]),
        if (!admin) statusLine(t.app.hermesJobAdminDisabled),
        if (_status case final status?)
          statusLine(status, error: _statusIsError),
        if (_editing == '') _editor(context, null),
        if (jobs.isLoading && jobs.value == null)
          statusLine(t.app.hermesSchedulesLoading)
        else if (jobs.hasError && jobs.value == null)
          statusLine(t.app.hermesJobLoadFailed, error: true)
        else if (list.isEmpty)
          statusLine(t.app.hermesJobEmptyMessage),
        ul(classes: 'divide-y divide-border rounded border border-border', [
          for (final job in list)
            li(
              classes: 'space-y-1 px-3 py-2',
              attributes: <String, String>{'data-job': job.id},
              [
                div(classes: 'flex items-center gap-2', [
                  span(classes: 'min-w-0 flex-1 truncate text-sm font-medium', [
                    Component.text(job.name ?? job.prompt),
                  ]),
                  if (!job.enabled) badge(t.app.hermesJobPaused),
                  if (admin) ...[
                    checkboxField(
                      id: 'hermes-job-enabled-${job.id}',
                      text: t.desktop.desktopWorkspaceActive,
                      checked: job.enabled,
                      onChanged: ({required value}) => unawaited(
                        _run(
                          (actions) =>
                              actions.setJobEnabled(job.id, enabled: value),
                          done: value
                              ? t.app.hermesJobResumed
                              : t.app.hermesJobPausedSuccess,
                          failed: value
                              ? t.app.hermesJobResumeFailed
                              : t.app.hermesJobPauseFailed,
                        ),
                      ),
                    ),
                    actionButton(
                      t.app.hermesJobRunNow,
                      onClick: () => unawaited(
                        _run(
                          (actions) => actions.runJob(job.id),
                          done: t.app.hermesJobStarted,
                          failed: t.app.hermesJobRunFailed,
                        ),
                      ),
                    ),
                    actionButton(t.app.edit, onClick: () => _edit(job)),
                    actionButton(
                      t.app.delete,
                      destructive: true,
                      onClick: () => setState(() => _deleting = job.id),
                    ),
                  ],
                ]),
                p(classes: 'text-xs text-muted-foreground', [
                  Component.text(
                    [
                      job.scheduleText ?? job.schedule,
                      if (job.nextRunAtMs case final ms?)
                        '${t.app.hermesJobNextLabel}: ${dayOf(ms)}',
                      if (job.lastStatus case final status?)
                        t.app.hermesLastStatus(status: status),
                    ].join(' · '),
                  ),
                ]),
                if (_editing == job.id) _editor(context, job),
                if (_deleting == job.id)
                  confirmBox(
                    title: t.app.hermesJobDeleteTitle,
                    message: t.app.hermesJobDeleteMessage,
                    confirmText: t.app.delete,
                    onConfirm: () {
                      setState(() => _deleting = null);
                      unawaited(
                        _run(
                          (actions) => actions.deleteJob(job.id),
                          done: t.app.hermesJobDeleted,
                          failed: t.app.hermesJobDeleteFailed,
                        ),
                      );
                    },
                    onCancel: () => setState(() => _deleting = null),
                  ),
              ],
            ),
        ]),
      ],
    );
  }

  Component _editor(BuildContext context, HermesJobDto? job) =>
      div(classes: 'space-y-3 rounded border border-border p-3', [
        h3(classes: 'text-sm font-semibold', [
          Component.text(
            job == null ? t.app.hermesJobNew : t.app.hermesJobEditorEditTitle,
          ),
        ]),
        textField(
          id: 'hermes-job-name',
          labelText: t.app.name,
          placeholder: t.app.hermesJobNameHint,
          value: _name,
          onInput: (value) => setState(() => _name = value),
        ),
        textAreaField(
          id: 'hermes-job-prompt',
          labelText: t.app.hermesJobPromptLabel,
          placeholder: t.app.hermesJobPromptHint,
          value: _prompt,
          rows: 3,
          onInput: (value) => setState(() => _prompt = value),
        ),
        textField(
          id: 'hermes-job-schedule',
          labelText: t.app.hermesJobScheduleLabel,
          placeholder: t.app.hermesJobScheduleHint,
          value: _schedule,
          onInput: (value) => setState(() => _schedule = value),
        ),
        p(classes: 'text-xs text-muted-foreground', [
          Component.text(t.app.hermesJobScheduleHelp),
        ]),
        div(classes: 'flex justify-end gap-2', [
          actionButton(
            t.app.cancel,
            onClick: () => setState(() => _editing = null),
          ),
          actionButton(
            t.app.save,
            primary: true,
            id: 'hermes-job-save',
            disabled: _prompt.trim().isEmpty || _schedule.trim().isEmpty,
            onClick: () {
              final edit = HermesJobEdit(
                id: job?.id,
                name: _name.trim().isEmpty ? null : _name.trim(),
                prompt: _prompt.trim(),
                schedule: _schedule.trim(),
              );
              setState(() => _editing = null);
              unawaited(
                _run(
                  (actions) => actions.saveJob(edit),
                  done: job == null
                      ? t.app.hermesJobCreated
                      : t.app.hermesJobUpdated,
                  failed: job == null
                      ? t.app.hermesJobCreateFailed
                      : t.app.hermesJobUpdateFailed,
                ),
              );
            },
          ),
        ]),
      ]);
}
