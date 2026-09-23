import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../../l10n/strings.g.dart';
import '../../rpc/workspace_providers.dart';
import 'workspace_common.dart';

/// A prompt's saved versions, newest first: compare one with production,
/// restore its text into the editor, put it in production, or delete it.
class PromptHistoryPanel extends StatefulComponent {
  const PromptHistoryPanel({
    required this.promptId,
    required this.canWrite,
    required this.onRestore,
    required this.onProduction,
    super.key,
  });

  final String promptId;
  final bool canWrite;
  final void Function(WorkspacePromptVersion version) onRestore;
  final void Function(WorkspaceDetail detail) onProduction;

  @override
  State<PromptHistoryPanel> createState() => _PromptHistoryPanelState();
}

class _PromptHistoryPanelState extends State<PromptHistoryPanel> {
  WorkspacePromptDiff? _diff;
  String? _status;
  bool _statusIsError = false;
  String? _confirmingDelete;

  void _say(String text, {bool error = false}) => setState(() {
    _status = text;
    _statusIsError = error;
  });

  Future<void> _compare(
    BuildContext context,
    WorkspacePromptVersion version,
    String productionId,
  ) async {
    try {
      final diff = await context
          .read(workspaceActionsProvider)
          .promptDiff(
            component.promptId,
            fromId: version.id,
            toId: productionId,
          );
      setState(() => _diff = diff);
    } on Object {
      _say(t.app.workspacePromptHistoryDiffFailed, error: true);
    }
  }

  Future<void> _setProduction(
    BuildContext context,
    WorkspacePromptVersion version,
  ) async {
    try {
      final detail = await context
          .read(workspaceActionsProvider)
          .promptSetVersion(component.promptId, version.id);
      context.invalidate(workspacePromptHistoryProvider(component.promptId));
      component.onProduction(detail);
      _say(t.app.workspacePromptHistoryProductionSet);
    } on Object {
      _say(t.app.workspacePromptSaveFailed, error: true);
    }
  }

  Future<void> _delete(BuildContext context, String versionId) async {
    try {
      await context
          .read(workspaceActionsProvider)
          .promptDeleteVersion(component.promptId, versionId);
      context.invalidate(workspacePromptHistoryProvider(component.promptId));
      setState(() => _confirmingDelete = null);
      _say(t.app.workspacePromptHistoryDeleted);
    } on Object {
      _say(t.app.workspacePromptSaveFailed, error: true);
    }
  }

  @override
  Component build(BuildContext context) {
    final history = context.watch(
      workspacePromptHistoryProvider(component.promptId),
    );
    final versions =
        history.value?.versions ?? const <WorkspacePromptVersion>[];
    final production = versions
        .where((v) => v.production)
        .map((v) => v.id)
        .firstOrNull;
    return section(
      classes: 'space-y-2 rounded border border-border p-4',
      attributes: <String, String>{'aria-label': t.app.workspacePromptHistory},
      [
        h3(classes: 'text-ui-base font-semibold', [
          Component.text(t.app.workspacePromptHistory),
        ]),
        if (_status case final status?)
          statusLine(status, error: _statusIsError),
        if (history.isLoading && history.value == null)
          statusLine(t.app.loadingShort)
        else if (history.hasError && history.value == null)
          statusLine(t.app.workspacePromptHistoryLoadFailed, error: true)
        else if (versions.isEmpty)
          statusLine(t.app.workspacePromptHistoryEmpty),
        ul(classes: 'space-y-2', [
          for (final version in versions)
            li(
              classes: 'space-y-1 rounded border border-border p-2',
              attributes: <String, String>{'data-version': version.id},
              [
                div(classes: 'flex items-center gap-2 text-ui-base', [
                  span(classes: 'min-w-0 flex-1 truncate', [
                    Component.text(
                      version.commitMessage ??
                          t.app.workspacePromptHistoryCommitFallback,
                    ),
                  ]),
                  if (version.production)
                    badge(t.app.workspacePromptHistoryLive, muted: false),
                ]),
                p(classes: 'text-ui-xs text-muted-foreground', [
                  Component.text(
                    [
                      ?version.authorName,
                      if (version.createdAtMs > 0) dayOf(version.createdAtMs),
                    ].join(' · '),
                  ),
                ]),
                div(classes: 'flex flex-wrap gap-1', [
                  if (!version.production && production != null)
                    actionButton(
                      t.app.workspacePromptHistoryDiff,
                      onClick: () =>
                          unawaited(_compare(context, version, production)),
                    ),
                  if (component.canWrite) ...[
                    actionButton(
                      t.app.workspacePromptHistoryRestore,
                      onClick: () => component.onRestore(version),
                    ),
                    if (!version.production) ...[
                      actionButton(
                        t.app.workspacePromptHistorySetProduction,
                        onClick: () =>
                            unawaited(_setProduction(context, version)),
                      ),
                      actionButton(
                        t.app.workspacePromptHistoryDelete,
                        destructive: true,
                        onClick: () =>
                            setState(() => _confirmingDelete = version.id),
                      ),
                    ],
                  ],
                ]),
                if (_confirmingDelete == version.id)
                  confirmBox(
                    title: t.app.workspacePromptHistoryDeleteConfirmTitle,
                    message: t.app.workspacePromptHistoryDeleteConfirmMessage,
                    confirmText: t.app.delete,
                    onConfirm: () => unawaited(_delete(context, version.id)),
                    onCancel: () => setState(() => _confirmingDelete = null),
                  ),
              ],
            ),
        ]),
        if (_diff case final diff?)
          modal(
            label: t.app.workspacePromptHistoryDiffTitle,
            width: 'max-w-3xl',
            onClose: () => setState(() => _diff = null),
            children: [
              if (diff.nameChanged)
                statusLine(t.app.workspacePromptHistoryDiffNameChanged),
              if (diff.lines.isEmpty)
                statusLine(t.app.workspacePromptHistoryDiffEmpty)
              else
                pre(
                  classes:
                      'overflow-x-auto rounded bg-muted p-3 font-mono text-xs',
                  [
                    for (final line in diff.lines)
                      div(classes: _lineClass(line), [
                        Component.text(line.isEmpty ? ' ' : line),
                      ]),
                  ],
                ),
              div(classes: 'flex justify-end', [
                actionButton(
                  t.app.close,
                  onClick: () => setState(() => _diff = null),
                ),
              ]),
            ],
          ),
      ],
    );
  }

  static String _lineClass(String line) {
    if (line.startsWith('+++') || line.startsWith('---')) {
      return 'text-muted-foreground';
    }
    if (line.startsWith('+')) return 'bg-success/10 text-success';
    if (line.startsWith('-')) return 'bg-destructive/10 text-destructive';
    if (line.startsWith('@@')) return 'text-muted-foreground';
    return '';
  }
}
