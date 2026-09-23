import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/direct_providers.dart';
import '../widgets/form_field.dart';

/// Settings > Direct connections (WP-4.2): model providers the app talks to
/// itself, without Open WebUI in between.
///
/// Mobile's wording throughout, which already explains the parts that need
/// explaining -- where a key is kept, why moving a URL asks for it again.
class DirectConnectionsTab extends StatefulComponent {
  const DirectConnectionsTab({super.key});

  @override
  State<DirectConnectionsTab> createState() => _DirectConnectionsTabState();
}

class _DirectConnectionsTabState extends State<DirectConnectionsTab> {
  /// The connection being edited; an empty id is a new one.
  DirectConnectionSummary? _editing;
  String? _deleting;

  static const _blank = DirectConnectionSummary(
    id: '',
    name: '',
    kind: DirectKind.openai,
    baseUrl: '',
  );

  @override
  Component build(BuildContext context) {
    final list = context.watch(directConnectionsProvider);
    final value = list.value;
    return div(classes: 'space-y-4', [
      p(classes: 'text-sm text-muted-foreground', [
        Component.text(t.app.directConnectionsDescription),
      ]),
      if (value != null)
        checkboxField(
          id: 'direct-history',
          text: t.desktop.desktopDirectHistoryLocal,
          checked: value.localHistory,
          onChanged: ({required value}) => unawaited(
            context.read(directActionsProvider).setHistory(localOnly: value),
          ),
        ),
      if (list.hasError && value == null) formError('${list.error}'),
      if (value != null && value.connections.isEmpty && _editing == null)
        div(classes: 'rounded border border-dashed border-border p-4', [
          p(classes: 'text-sm font-medium', [
            Component.text(t.app.directProfilesEmptyTitle),
          ]),
          p(classes: 'text-xs text-muted-foreground', [
            Component.text(t.app.directProfilesEmptySubtitle),
          ]),
        ]),
      if (value != null)
        ul(classes: 'space-y-2', [
          for (final connection in value.connections)
            if (_editing?.id == connection.id)
              li([
                _ConnectionEditor(
                  key: ValueKey('edit-${connection.id}'),
                  connection: connection,
                  onDone: () => setState(() => _editing = null),
                ),
              ])
            else
              _row(context, connection),
        ]),
      if (_editing?.id == '')
        _ConnectionEditor(
          key: const ValueKey('edit-new'),
          connection: _blank,
          onDone: () => setState(() => _editing = null),
        )
      else if (_editing == null)
        button(
          [Component.text(t.app.directConnectProvider)],
          classes:
              'rounded border border-border px-3 py-1.5 text-sm '
              'hover:bg-accent',
          type: ButtonType.button,
          onClick: () => setState(() => _editing = _blank),
        ),
    ]);
  }

  Component _row(BuildContext context, DirectConnectionSummary connection) =>
      li(classes: 'rounded border border-border p-3', [
        div(classes: 'flex items-center gap-3', [
          input<bool>(
            classes: 'size-4',
            type: InputType.checkbox,
            checked: connection.enabled,
            attributes: <String, String>{
              'aria-label': t.desktop.desktopDirectEnable(
                name: connection.name,
              ),
            },
            onChange: (enabled) => unawaited(
              context
                  .read(directActionsProvider)
                  .setEnabled(connection.id, enabled: enabled),
            ),
          ),
          div(classes: 'min-w-0 flex-1', [
            div(classes: 'flex items-center gap-2', [
              span(classes: 'truncate text-sm font-medium', [
                Component.text(connection.name),
              ]),
              span(
                classes:
                    'rounded-full border border-border px-2 text-xs '
                    'text-muted-foreground',
                [
                  Component.text(
                    connection.kind == DirectKind.ollama
                        ? t.app.ollama
                        : t.desktop.desktopOpenAiCompatible,
                  ),
                ],
              ),
            ]),
            span(classes: 'truncate font-mono text-xs text-muted-foreground', [
              Component.text(connection.baseUrl),
            ]),
          ]),
          button(
            [Component.text(t.app.edit)],
            classes: 'rounded px-2.5 py-1 text-xs hover:bg-accent',
            type: ButtonType.button,
            onClick: () => setState(() => _editing = connection),
          ),
          button(
            [Component.text(t.app.delete)],
            classes:
                'rounded px-2.5 py-1 text-xs text-destructive '
                'hover:bg-destructive/10',
            type: ButtonType.button,
            onClick: () => setState(() => _deleting = connection.id),
          ),
        ]),
        if (_deleting == connection.id)
          div(
            classes:
                'mt-2 space-y-2 rounded border border-destructive/40 '
                'bg-destructive/10 p-2 text-xs',
            attributes: const <String, String>{'role': 'alertdialog'},
            [
              p([
                Component.text(
                  t.app.directConnectionDeleteMessage(name: connection.name),
                ),
              ]),
              div(classes: 'flex gap-2', [
                button(
                  [Component.text(t.app.delete)],
                  classes:
                      'rounded bg-destructive px-2 py-1 '
                      'text-destructive-foreground',
                  type: ButtonType.button,
                  onClick: () {
                    setState(() => _deleting = null);
                    unawaited(
                      context.read(directActionsProvider).remove(connection.id),
                    );
                  },
                ),
                button(
                  [Component.text(t.app.cancel)],
                  classes: 'rounded px-2 py-1',
                  type: ButtonType.button,
                  onClick: () => setState(() => _deleting = null),
                ),
              ]),
            ],
          ),
      ]);
}

/// One connection's fields, with Test and Save.
class _ConnectionEditor extends StatefulComponent {
  const _ConnectionEditor({
    required this.connection,
    required this.onDone,
    super.key,
  });

  final DirectConnectionSummary connection;
  final void Function() onDone;

  @override
  State<_ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<_ConnectionEditor> {
  late String _name = component.connection.name;
  late DirectKind _kind = component.connection.kind;
  late String _baseUrl = component.connection.baseUrl;
  late DirectApiMode _apiMode = component.connection.apiMode;
  late String _apiVersion = component.connection.apiVersion ?? '';
  late bool _keyHeader = component.connection.apiKeyHeader;
  late String _manualIds = component.connection.manualModelIds.join('\n');
  late bool _selfSigned = component.connection.allowSelfSignedCertificates;

  /// Empty means "leave the stored key alone"; see [_edit].
  String _apiKey = '';
  bool _busy = false;
  String? _result;
  bool _resultOk = false;

  bool get _isNew => component.connection.id.isEmpty;

  /// The form as the protocol's edit. An untouched key field sends null,
  /// which keeps the stored key -- typing is the only way to change it.
  DirectConnectionEdit _edit() => DirectConnectionEdit(
    id: _isNew ? null : component.connection.id,
    name: _name,
    kind: _kind,
    baseUrl: _baseUrl,
    apiMode: _apiMode,
    apiVersion: _apiVersion.trim().isEmpty ? null : _apiVersion.trim(),
    apiKeyHeader: _keyHeader,
    enabled: component.connection.enabled,
    apiKey: _apiKey.isEmpty ? null : _apiKey,
    manualModelIds: <String>[
      for (final line in _manualIds.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ],
    allowSelfSignedCertificates: _selfSigned,
  );

  @override
  Component build(BuildContext context) {
    final openAi = _kind == DirectKind.openai;
    return div(
      classes: 'space-y-3 rounded border border-border bg-background p-4',
      attributes: <String, String>{
        'role': 'group',
        'aria-label': t.app.directConnectionDetailsTitle,
      },
      [
        textField(
          id: 'direct-name',
          labelText: t.app.directConnectionName,
          value: _name,
          onInput: (value) => setState(() => _name = value),
        ),
        div(classes: 'space-y-1.5', [
          label(
            [Component.text(t.app.directProvider)],
            htmlFor: 'direct-kind',
            classes: 'text-sm font-medium',
          ),
          select(
            [
              option(value: 'openai', selected: openAi, [
                Component.text(t.desktop.desktopOpenAiCompatible),
              ]),
              option(value: 'ollama', selected: !openAi, [
                Component.text(t.app.ollama),
              ]),
            ],
            id: 'direct-kind',
            classes:
                'w-full rounded border border-border bg-background px-2 '
                'py-1.5 text-sm',
            onChange: (values) => setState(
              () => _kind = values.firstOrNull == 'ollama'
                  ? DirectKind.ollama
                  : DirectKind.openai,
            ),
          ),
        ]),
        textField(
          id: 'direct-url',
          labelText: t.app.directApiBaseUrl,
          value: _baseUrl,
          placeholder: openAi
              ? 'https://api.example.com/v1'
              : 'http://localhost:11434',
          onInput: (value) => setState(() => _baseUrl = value),
        ),
        p(classes: '-mt-2 text-xs text-muted-foreground', [
          Component.text(t.app.directBaseUrlDescription),
        ]),
        if (openAi)
          div(classes: 'space-y-1.5', [
            label(
              [Component.text(t.app.directCompletionApi)],
              htmlFor: 'direct-mode',
              classes: 'text-sm font-medium',
            ),
            select(
              [
                option(
                  value: 'chat',
                  selected: _apiMode == DirectApiMode.chat,
                  [Component.text(t.app.directChatCompletions)],
                ),
                option(
                  value: 'responses',
                  selected: _apiMode == DirectApiMode.responses,
                  [Component.text(t.app.directResponses)],
                ),
              ],
              id: 'direct-mode',
              classes:
                  'w-full rounded border border-border bg-background px-2 '
                  'py-1.5 text-sm',
              onChange: (values) => setState(
                () => _apiMode = values.firstOrNull == 'responses'
                    ? DirectApiMode.responses
                    : DirectApiMode.chat,
              ),
            ),
          ]),
        textField(
          id: 'direct-key',
          labelText: t.app.directApiKey,
          value: _apiKey,
          type: InputType.password,
          placeholder: component.connection.hasApiKey
              ? t.app.directConfiguredReplacePlaceholder
              : t.app.directApiKeyPlaceholder,
          onInput: (value) => setState(() => _apiKey = value),
        ),
        if (openAi) ...[
          checkboxField(
            id: 'direct-key-header',
            text: t.app.directApiKeyHeader,
            checked: _keyHeader,
            onChanged: ({required value}) => setState(() => _keyHeader = value),
          ),
          textField(
            id: 'direct-api-version',
            labelText: t.app.directApiVersion,
            value: _apiVersion,
            onInput: (value) => setState(() => _apiVersion = value),
          ),
        ],
        textAreaField(
          id: 'direct-manual-ids',
          labelText: t.app.directManualModelIds,
          value: _manualIds,
          rows: 3,
          monospace: true,
          placeholder: t.app.directManualModelIdsDescription,
          onInput: (value) => setState(() => _manualIds = value),
        ),
        checkboxField(
          id: 'direct-self-signed',
          text: t.app.allowSelfSignedCertificates,
          checked: _selfSigned,
          onChanged: ({required value}) => setState(() => _selfSigned = value),
        ),
        if (_result case final result?)
          p(
            classes:
                'text-sm ${_resultOk ? 'text-muted-foreground' : 'text-destructive'}',
            attributes: <String, String>{
              'role': _resultOk ? 'status' : 'alert',
            },
            [Component.text(result)],
          ),
        div(classes: 'flex justify-end gap-2', [
          button(
            [Component.text(t.app.cancel)],
            classes: 'rounded px-3 py-1.5 text-sm hover:bg-accent',
            type: ButtonType.button,
            onClick: component.onDone,
          ),
          button(
            [Component.text(t.app.directMcpTestConnection)],
            classes:
                'rounded border border-border px-3 py-1.5 text-sm '
                'hover:bg-accent disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_test(context)),
          ),
          button(
            [Component.text(t.app.save)],
            classes:
                'rounded bg-primary px-3 py-1.5 text-sm '
                'text-primary-foreground disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_save(context)),
          ),
        ]),
      ],
    );
  }

  Future<void> _test(BuildContext context) async {
    setState(() => _busy = true);
    try {
      final result = await context.read(directActionsProvider).test(_edit());
      if (!mounted) return;
      setState(() {
        _resultOk = result.reachable;
        final count = result.modelCount;
        _result = !result.reachable
            ? (result.message ?? t.app.directConnectionReachFailed)
            : count != null
            ? t.app.directConnectionProbeConnectedModels(count: count)
            : t.app.directConnectionProbeConnected;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = t.app.directConnectionReachFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(BuildContext context) async {
    setState(() => _busy = true);
    try {
      await context.read(directActionsProvider).save(_edit());
      if (!mounted) return;
      component.onDone();
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = switch (error.code) {
          ConduitErrorCodes.conflict => t.app.directConnectionSaveConflict,
          ConduitErrorCodes.invalidParams =>
            error.debugMessage ?? t.app.directConnectionSaveFailed,
          _ => t.app.directConnectionSaveFailed,
        };
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
