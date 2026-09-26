import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../file_picker.dart';
import '../l10n/strings.g.dart';
import '../rpc/direct_providers.dart';
import '../rpc/rpc_providers.dart';
import '../widgets/form_field.dart';
import 'ollama_models.dart';
import '../widgets/ui.dart';

/// Settings > Direct connections: model providers the app talks to
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

  /// Ollama connections whose models are shown.
  final Set<String> _modelsOpen = <String>{};

  static const _blank = DirectConnectionSummary(
    id: '',
    name: '',
    kind: DirectKind.openai,
    baseUrl: '',
  );

  /// A new connection for the Open WebUI account: OpenAI-compatible
  /// only, and named by Open WebUI after its host.
  static const _blankAccount = DirectConnectionSummary(
    id: '',
    name: '',
    kind: DirectKind.openai,
    baseUrl: '',
    openWebUi: true,
  );

  bool _addingTo({required bool account}) =>
      _editing?.id == '' && _editing!.openWebUi == account;

  @override
  Component build(BuildContext context) {
    final list = context.watch(directConnectionsProvider);
    final value = list.value;
    return div(classes: 'space-y-4', [
      p(classes: 'text-ui-base text-foreground-subtle', [
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
      if (value != null)
        ..._section(
          context,
          value.connections.where((c) => !c.openWebUi).toList(),
          account: false,
        ),
      // Open WebUI's own direct connections, kept in the account and
      // shared with its other clients.
      if (value != null && value.openWebUiAvailable) ...[
        div(classes: 'space-y-1 border-t border-border pt-4', [
          h3(classes: 'text-ui-base font-semibold', [
            Component.text(t.app.openWebUiDirectConnectionsSectionTitle),
          ]),
          p(classes: 'text-ui-sm text-foreground-subtle', [
            Component.text(t.app.openWebUiDirectConnectionsSectionDescription),
          ]),
        ]),
        ..._section(
          context,
          value.connections.where((c) => c.openWebUi).toList(),
          account: true,
        ),
      ],
    ]);
  }

  /// One group of connections: its empty state, its rows, and its way to
  /// add one.
  List<Component> _section(
    BuildContext context,
    List<DirectConnectionSummary> connections, {
    required bool account,
  }) => <Component>[
    if (connections.isEmpty && !_addingTo(account: account))
      div(classes: 'rounded-lg border border-dashed border-border p-4', [
        p(classes: 'text-ui-base font-medium', [
          Component.text(
            account
                ? t.app.openWebUiDirectProfilesEmptyTitle
                : t.app.directProfilesEmptyTitle,
          ),
        ]),
        p(classes: 'text-ui-sm text-foreground-subtle', [
          Component.text(
            account
                ? t.app.openWebUiDirectProfilesEmptySubtitle
                : t.app.directProfilesEmptySubtitle,
          ),
        ]),
      ]),
    ul(classes: 'space-y-2', [
      for (final connection in connections)
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
    if (_addingTo(account: account))
      _ConnectionEditor(
        key: ValueKey(account ? 'edit-new-account' : 'edit-new'),
        connection: account ? _blankAccount : _blank,
        onDone: () => setState(() => _editing = null),
      )
    else if (_editing == null)
      button(
        [Component.text(t.app.directConnectProvider)],
        classes:
            'rounded-lg border border-border px-3 py-1.5 text-ui-base '
            'hover:bg-hover',
        type: ButtonType.button,
        attributes: <String, String>{
          if (account)
            'aria-label':
                '${t.app.directConnectProvider} · '
                '${t.app.openWebUiDirectConnectionSourceLabel}',
        },
        onClick: () =>
            setState(() => _editing = account ? _blankAccount : _blank),
      ),
  ];

  Component _row(
    BuildContext context,
    DirectConnectionSummary connection,
  ) => li(classes: 'rounded-lg border border-border p-3', [
    div(classes: 'flex items-center gap-3', [
      input<bool>(
        classes: 'size-4',
        type: InputType.checkbox,
        checked: connection.enabled,
        attributes: <String, String>{
          'aria-label': t.desktop.desktopDirectEnable(name: connection.name),
        },
        onChange: (enabled) => unawaited(
          context
              .read(directActionsProvider)
              .setEnabled(connection.id, enabled: enabled),
        ),
      ),
      div(classes: 'min-w-0 flex-1', [
        div(classes: 'flex items-center gap-2', [
          span(classes: 'truncate text-ui-base font-medium', [
            Component.text(connection.name),
          ]),
          span(
            classes:
                'rounded-full border border-border px-2 text-ui-sm '
                'text-foreground-subtle',
            [
              Component.text(
                connection.kind == DirectKind.ollama
                    ? t.app.ollama
                    : t.desktop.desktopOpenAiCompatible,
              ),
            ],
          ),
        ]),
        span(classes: 'truncate font-mono text-xs text-foreground-subtle', [
          Component.text(connection.baseUrl),
        ]),
        if (!connection.compatible)
          p(classes: 'text-ui-sm text-destructive', [
            Component.text(t.app.openWebUiDirectConnectionUnsupportedAuth),
          ]),
      ]),
      if (connection.kind == DirectKind.ollama)
        button(
          [Component.text(t.app.ollamaModelActions)],
          classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
          type: ButtonType.button,
          attributes: <String, String>{
            'aria-expanded': '${_modelsOpen.contains(connection.id)}',
          },
          onClick: () => setState(
            () => _modelsOpen.contains(connection.id)
                ? _modelsOpen.remove(connection.id)
                : _modelsOpen.add(connection.id),
          ),
        ),
      if (connection.compatible)
        button(
          [Component.text(t.app.edit)],
          classes: 'rounded-lg px-2.5 py-1 text-ui-sm hover:bg-hover',
          type: ButtonType.button,
          onClick: () => setState(() => _editing = connection),
        ),
      button(
        [Component.text(t.app.delete)],
        classes:
            'rounded-lg px-2.5 py-1 text-ui-sm text-destructive '
            'hover:bg-destructive/10',
        type: ButtonType.button,
        onClick: () => setState(() => _deleting = connection.id),
      ),
    ]),
    if (_modelsOpen.contains(connection.id))
      OllamaModels(
        key: ValueKey('ollama-${connection.id}'),
        connectionId: connection.id,
      ),
    if (_deleting == connection.id)
      div(
        classes:
            'mt-2 space-y-2 rounded-lg border border-destructive/40 '
            'bg-destructive/10 p-2 text-ui-sm',
        attributes: const <String, String>{'role': 'alertdialog'},
        [
          p([
            Component.text(
              connection.openWebUi
                  ? t.app.openWebUiDirectConnectionDeleteMessage(
                      name: connection.name,
                    )
                  : t.app.directConnectionDeleteMessage(name: connection.name),
            ),
          ]),
          div(classes: 'flex gap-2', [
            button(
              [Component.text(t.app.delete)],
              classes:
                  'rounded-lg bg-destructive px-2 py-1 '
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
              classes: 'rounded-lg px-2 py-1',
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
  late String _prefix = component.connection.modelIdPrefix ?? '';
  late String _tags = component.connection.tags.join(', ');

  /// Typed headers replace the stored ones; untouched, they are kept.
  String _headers = '';

  /// A picked certificate or key: its PEM and file name. Null leaves the
  /// stored one alone; [_clearTls] removes both.
  ({String pem, String label})? _certificate;
  ({String pem, String label})? _privateKey;
  bool _clearTls = false;
  String _keyPassword = '';

  /// Open or not is this component's to say: a native `<details>` is
  /// closed again by the rebuild that typing in it causes.
  bool _advancedOpen = false;
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
    openWebUi: component.connection.openWebUi,
    modelIdPrefix: _prefix.trim().isEmpty ? null : _prefix.trim(),
    tags: <String>[
      for (final tag in _tags.split(RegExp('[,\n]')))
        if (tag.trim().isNotEmpty) tag.trim(),
    ],
    customHeaders: _headers.trim().isEmpty
        ? null
        : <String, String>{
            for (final line in _headers.split('\n'))
              if (line.contains(':'))
                line.substring(0, line.indexOf(':')).trim(): line
                    .substring(line.indexOf(':') + 1)
                    .trim(),
          },
    certificatePem: _clearTls ? '' : _certificate?.pem,
    certificateLabel: _certificate?.label,
    privateKeyPem: _clearTls ? '' : _privateKey?.pem,
    privateKeyLabel: _privateKey?.label,
    privateKeyPassword: _clearTls
        ? ''
        : (_keyPassword.isEmpty ? null : _keyPassword),
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
      classes: 'space-y-3 rounded-lg border border-border bg-panel p-4',
      attributes: <String, String>{
        'role': 'group',
        'aria-label': t.app.directConnectionDetailsTitle,
      },
      [
        // Open WebUI names these after their host and supports only
        // OpenAI-compatible ones, so neither is asked.
        if (component.connection.openWebUi)
          p(classes: 'text-ui-sm text-foreground-subtle', [
            Component.text(t.app.openWebUiDirectConnectionEditorDescription),
            Component.text(' '),
            Component.text(t.app.openWebUiDirectConnectionProviderDescription),
          ])
        else ...[
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
              classes: 'text-ui-base font-medium',
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
                  'w-full rounded-lg border border-border bg-panel px-2 '
                  'py-1.5 text-ui-base',
              onChange: (values) => setState(
                () => _kind = values.firstOrNull == 'ollama'
                    ? DirectKind.ollama
                    : DirectKind.openai,
              ),
            ),
          ]),
        ],
        textField(
          id: 'direct-url',
          labelText: t.app.directApiBaseUrl,
          value: _baseUrl,
          placeholder: openAi
              ? 'https://api.example.com/v1'
              : 'http://localhost:11434',
          onInput: (value) => setState(() => _baseUrl = value),
        ),
        p(classes: '-mt-2 text-ui-sm text-foreground-subtle', [
          Component.text(t.app.directBaseUrlDescription),
        ]),
        if (openAi)
          div(classes: 'space-y-1.5', [
            label(
              [Component.text(t.app.directCompletionApi)],
              htmlFor: 'direct-mode',
              classes: 'text-ui-base font-medium',
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
                  'w-full rounded-lg border border-border bg-panel px-2 '
                  'py-1.5 text-ui-base',
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
        _advanced(context),
        if (_result case final result?)
          p(
            classes:
                'text-ui-base ${_resultOk ? 'text-foreground-subtle' : 'text-destructive'}',
            attributes: <String, String>{
              'role': _resultOk ? 'status' : 'alert',
            },
            [Component.text(result)],
          ),
        div(classes: 'flex justify-end gap-2', [
          button(
            [Component.text(t.app.cancel)],
            classes: 'rounded-lg px-3 py-1.5 text-ui-base hover:bg-hover',
            type: ButtonType.button,
            onClick: component.onDone,
          ),
          button(
            [Component.text(t.app.directMcpTestConnection)],
            classes:
                'rounded-lg border border-border px-3 py-1.5 text-ui-base '
                'hover:bg-hover disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_test(context)),
          ),
          button(
            [Component.text(t.app.save)],
            classes:
                'rounded-lg bg-primary px-3 py-1.5 text-ui-base '
                'text-primary-foreground disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_save(context)),
          ),
        ]),
      ],
    );
  }

  /// What most connections never need: a display prefix, tags, extra
  /// headers and a client certificate. Collapsed, as on the server form.
  Component _advanced(BuildContext context) {
    final connection = component.connection;
    final certificate = _clearTls
        ? null
        : (_certificate?.label ?? connection.certificateLabel);
    final key = _clearTls
        ? null
        : (_privateKey?.label ?? connection.privateKeyLabel);
    return div([
      button(
        [
          icon(
            _advancedOpen ? LucideIcon.chevronDown : LucideIcon.chevronRight,
            classes: 'size-4 shrink-0 text-foreground-subtle',
          ),
          Component.text(t.app.advancedSettings),
        ],
        classes: 'inline-flex items-center gap-1 text-ui-base font-medium',
        type: ButtonType.button,
        attributes: <String, String>{'aria-expanded': '$_advancedOpen'},
        onClick: () => setState(() => _advancedOpen = !_advancedOpen),
      ),
      if (_advancedOpen)
        div(classes: 'mt-3 space-y-3', [
          textField(
            id: 'direct-prefix',
            labelText: t.app.directModelIdPrefix,
            value: _prefix,
            onInput: (value) => setState(() => _prefix = value),
          ),
          p(classes: '-mt-2 text-ui-sm text-foreground-subtle', [
            Component.text(t.app.directModelIdPrefixDescription),
          ]),
          textField(
            id: 'direct-tags',
            labelText: t.app.directModelTags,
            value: _tags,
            placeholder: 'local, private',
            onInput: (value) => setState(() => _tags = value),
          ),
          p(classes: '-mt-2 text-ui-sm text-foreground-subtle', [
            Component.text(t.app.directModelTagsDescription),
          ]),
          textAreaField(
            id: 'direct-headers',
            labelText: t.app.directCustomHeaders,
            value: _headers,
            rows: 2,
            monospace: true,
            placeholder: t.app.directMcpCustomHeadersHint,
            onInput: (value) => setState(() => _headers = value),
          ),
          p(classes: '-mt-2 text-ui-sm text-foreground-subtle', [
            Component.text(
              connection.customHeaderNames.isEmpty
                  ? t.app.customHeadersDescription
                  : t.desktop.desktopMcpHeadersConfigured(
                      names: connection.customHeaderNames.join(', '),
                    ),
            ),
          ]),
          div(classes: 'space-y-2', [
            p(classes: 'text-ui-base font-medium', [
              Component.text(t.app.mutualTlsSectionTitle),
            ]),
            p(classes: 'text-ui-sm text-foreground-subtle', [
              Component.text(t.app.mutualTlsSectionDescription),
            ]),
            _pemRow(
              context,
              id: 'direct-certificate',
              labelText: t.app.mutualTlsSelectCertificate,
              accept: '.pem,.crt,.cer',
              marker: 'CERTIFICATE',
              invalid: t.app.mutualTlsCertificatePemRequired,
              current: certificate,
              onPicked: (pem, name) => setState(() {
                _certificate = (pem: pem, label: name);
                _clearTls = false;
              }),
            ),
            _pemRow(
              context,
              id: 'direct-private-key',
              labelText: t.app.mutualTlsSelectPrivateKey,
              accept: '.pem,.key',
              marker: 'PRIVATE KEY',
              invalid: t.app.mutualTlsPrivateKeyPemRequired,
              current: key,
              onPicked: (pem, name) => setState(() {
                _privateKey = (pem: pem, label: name);
                _clearTls = false;
              }),
            ),
            textField(
              id: 'direct-key-password',
              labelText: t.app.mutualTlsPrivateKeyPasswordHint,
              value: _keyPassword,
              type: InputType.password,
              onInput: (value) => setState(() => _keyPassword = value),
            ),
            if (certificate != null || key != null)
              button(
                [Component.text(t.app.mutualTlsClearCredentials)],
                classes: 'text-ui-sm text-foreground-subtle underline',
                type: ButtonType.button,
                onClick: () => setState(() {
                  _certificate = null;
                  _privateKey = null;
                  _keyPassword = '';
                  _clearTls = true;
                }),
              ),
          ]),
        ]),
    ]);
  }

  Component _pemRow(
    BuildContext context, {
    required String id,
    required String labelText,
    required String accept,
    required String marker,
    required String invalid,
    required String? current,
    required void Function(String pem, String label) onPicked,
  }) => div(classes: 'flex items-center gap-2 text-ui-base', [
    span(id: '$id-label', classes: 'w-24 shrink-0', [
      Component.text(labelText),
    ]),
    button(
      [
        Component.text(
          current == null
              ? t.desktop.desktopChooseFile
              : t.desktop.desktopReplaceFile,
        ),
      ],
      id: id,
      classes: 'rounded-lg border border-border px-2.5 py-1 text-ui-sm hover:bg-hover',
      type: ButtonType.button,
      attributes: <String, String>{'aria-labelledby': '$id-label $id'},
      onClick: () async {
        try {
          final file = await context
              .read(filePickerProvider)
              .pickText(accept: accept);
          if (file == null || !mounted) return;
          if (!containsPemBlock(file.content, marker)) {
            setState(() {
              _resultOk = false;
              _result = invalid;
            });
            return;
          }
          onPicked(file.content, file.name);
        } on UnsupportedError {
          if (!mounted) return;
          setState(() {
            _resultOk = false;
            _result = t.app.mutualTlsFileReadFailed;
          });
        }
      },
    ),
    if (current != null)
      span(classes: 'truncate font-mono text-xs text-foreground-subtle', [
        Component.text(current),
      ]),
  ]);

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
