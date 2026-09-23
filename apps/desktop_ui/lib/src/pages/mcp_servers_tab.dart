import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/mcp_providers.dart';
import '../widgets/form_field.dart';

/// Settings > MCP servers (M4): tool servers the app talks to itself, for
/// models from direct connections.
///
/// Mobile's wording, as the direct connections tab uses it.
class McpServersTab extends StatefulComponent {
  const McpServersTab({super.key});

  @override
  State<McpServersTab> createState() => _McpServersTabState();
}

class _McpServersTabState extends State<McpServersTab> {
  /// The server being edited; an empty id is a new one.
  McpServerSummary? _editing;
  String? _deleting;

  static const _blank = McpServerSummary(id: '', name: '', endpoint: '');

  @override
  Component build(BuildContext context) {
    final list = context.watch(mcpServersProvider);
    final value = list.value;
    return div(classes: 'space-y-4', [
      p(classes: 'text-ui-base text-muted-foreground', [
        Component.text(t.desktop.desktopMcpReachabilityHelp),
      ]),
      if (list.hasError && value == null) formError(t.app.directMcpLoadFailed),
      if (value != null && value.servers.isEmpty && _editing == null)
        div(classes: 'rounded border border-dashed border-border p-4', [
          p(classes: 'text-ui-base font-medium', [
            Component.text(t.app.directMcpEmptyTitle),
          ]),
        ]),
      if (value != null)
        ul(classes: 'space-y-2', [
          for (final server in value.servers)
            if (_editing?.id == server.id)
              li([
                _ServerEditor(
                  key: ValueKey('mcp-edit-${server.id}'),
                  server: server,
                  onDone: () => setState(() => _editing = null),
                ),
              ])
            else
              _row(context, server),
        ]),
      if (_editing?.id == '')
        _ServerEditor(
          key: const ValueKey('mcp-edit-new'),
          server: _blank,
          onDone: () => setState(() => _editing = null),
        )
      else if (_editing == null)
        button(
          [Component.text(t.app.directMcpAddTitle)],
          classes:
              'rounded border border-border px-3 py-1.5 text-ui-base '
              'hover:bg-accent',
          type: ButtonType.button,
          onClick: () => setState(() => _editing = _blank),
        ),
    ]);
  }

  Component _row(
    BuildContext context,
    McpServerSummary server,
  ) => li(classes: 'rounded border border-border p-3', [
    div(classes: 'flex items-center gap-3', [
      input<bool>(
        classes: 'size-4',
        type: InputType.checkbox,
        checked: server.enabled,
        attributes: <String, String>{
          'aria-label': t.desktop.desktopDirectEnable(name: server.name),
        },
        onChange: (enabled) => unawaited(
          context
              .read(mcpActionsProvider)
              .setEnabled(server.id, enabled: enabled),
        ),
      ),
      div(classes: 'min-w-0 flex-1', [
        div(classes: 'flex items-center gap-2', [
          span(classes: 'truncate text-ui-base font-medium', [
            Component.text(server.name),
          ]),
          _badge(_authLabel(server.auth)),
          if (server.auth == McpAuth.oauth)
            _badge(
              server.oauthConnected
                  ? t.desktop.desktopMcpSignedIn
                  : t.desktop.desktopMcpNotSignedIn,
            ),
        ]),
        span(classes: 'truncate font-mono text-xs text-muted-foreground', [
          Component.text(server.endpoint),
        ]),
      ]),
      button(
        [Component.text(t.app.edit)],
        classes: 'rounded px-2.5 py-1 text-ui-sm hover:bg-accent',
        type: ButtonType.button,
        onClick: () => setState(() => _editing = server),
      ),
      button(
        [Component.text(t.app.delete)],
        classes:
            'rounded px-2.5 py-1 text-ui-sm text-destructive '
            'hover:bg-destructive/10',
        type: ButtonType.button,
        onClick: () => setState(() => _deleting = server.id),
      ),
    ]),
    if (_deleting == server.id)
      div(
        classes:
            'mt-2 space-y-2 rounded border border-destructive/40 '
            'bg-destructive/10 p-2 text-ui-sm',
        attributes: const <String, String>{'role': 'alertdialog'},
        [
          p([Component.text(t.app.directMcpDeleteMessage(name: server.name))]),
          div(classes: 'flex gap-2', [
            button(
              [Component.text(t.app.delete)],
              classes:
                  'rounded bg-destructive px-2 py-1 '
                  'text-destructive-foreground',
              type: ButtonType.button,
              onClick: () {
                setState(() => _deleting = null);
                unawaited(context.read(mcpActionsProvider).remove(server.id));
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

Component _badge(String text) => span(
  classes:
      'rounded-full border border-border px-2 text-ui-sm text-muted-foreground',
  [Component.text(text)],
);

String _authLabel(McpAuth auth) => switch (auth) {
  McpAuth.none => t.app.directMcpAuthNone,
  McpAuth.bearer => t.app.directMcpAuthBearer,
  McpAuth.oauth => t.app.directMcpAuthOAuth,
};

/// One server's fields, with Test, Save, the OAuth sign-in and its
/// remembered approvals.
class _ServerEditor extends StatefulComponent {
  const _ServerEditor({required this.server, required this.onDone, super.key});

  final McpServerSummary server;
  final void Function() onDone;

  @override
  State<_ServerEditor> createState() => _ServerEditorState();
}

class _ServerEditorState extends State<_ServerEditor> {
  late McpServerSummary _server = component.server;
  late String _name = _server.name;
  late String _endpoint = _server.endpoint;
  late McpAuth _auth = _server.auth;

  /// Empty means "leave the stored value alone": typing is the only way to
  /// change a secret, as on the direct connections tab.
  String _token = '';
  String _headers = '';

  /// Set once the user has agreed to send credentials over plain HTTP; the
  /// daemon asks by refusing the save with `reason: insecure`.
  late bool _insecureAllowed = _server.allowInsecureCredentials;
  bool _confirmingInsecure = false;
  bool _busy = false;
  bool _signingIn = false;
  String? _result;
  bool _resultOk = false;

  bool get _isNew => _server.id.isEmpty;

  McpServerEdit _edit() => McpServerEdit(
    id: _isNew ? null : _server.id,
    name: _name,
    endpoint: _endpoint,
    enabled: _server.enabled || _isNew,
    auth: _auth,
    bearerToken: _token.isEmpty ? null : _token,
    customHeaders: _headers.trim().isEmpty ? null : _parseHeaders(_headers),
    allowInsecureCredentials: _insecureAllowed,
  );

  static Map<String, String> _parseHeaders(String text) => <String, String>{
    for (final line in text.split('\n'))
      if (line.contains(':'))
        line.substring(0, line.indexOf(':')).trim(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
  };

  @override
  Component build(BuildContext context) {
    return div(
      classes: 'space-y-3 rounded border border-border bg-background p-4',
      attributes: <String, String>{
        'role': 'group',
        'aria-label': _isNew
            ? t.app.directMcpAddTitle
            : t.app.directMcpEditorTitle,
      },
      [
        textField(
          id: 'mcp-name',
          labelText: t.app.directMcpName,
          value: _name,
          onInput: (value) => setState(() => _name = value),
        ),
        textField(
          id: 'mcp-endpoint',
          labelText: t.app.directMcpEndpoint,
          value: _endpoint,
          placeholder: 'https://mcp.example.com/mcp',
          onInput: (value) => setState(() => _endpoint = value),
        ),
        div(classes: 'space-y-1.5', [
          label(
            [Component.text(t.app.directMcpAuthMode)],
            htmlFor: 'mcp-auth',
            classes: 'text-ui-base font-medium',
          ),
          select(
            [
              for (final auth in McpAuth.values)
                option(value: auth.name, selected: _auth == auth, [
                  Component.text(_authLabel(auth)),
                ]),
            ],
            id: 'mcp-auth',
            classes:
                'w-full rounded border border-border bg-background px-2 '
                'py-1.5 text-ui-base',
            onChange: (values) => setState(
              () => _auth = McpAuth.values.firstWhere(
                (auth) => auth.name == values.firstOrNull,
                orElse: () => McpAuth.none,
              ),
            ),
          ),
        ]),
        if (_auth == McpAuth.bearer)
          textField(
            id: 'mcp-token',
            labelText: t.app.directMcpBearerToken,
            value: _token,
            type: InputType.password,
            placeholder: _server.hasBearerToken
                ? t.app.directConfiguredReplacePlaceholder
                : null,
            onInput: (value) => setState(() => _token = value),
          ),
        textAreaField(
          id: 'mcp-headers',
          labelText: t.app.directMcpCustomHeaders,
          value: _headers,
          rows: 2,
          monospace: true,
          placeholder: t.app.directMcpCustomHeadersHint,
          onInput: (value) => setState(() => _headers = value),
        ),
        if (_server.customHeaderNames.isNotEmpty)
          p(classes: '-mt-2 text-ui-sm text-muted-foreground', [
            Component.text(
              t.desktop.desktopMcpHeadersConfigured(
                names: _server.customHeaderNames.join(', '),
              ),
            ),
          ]),
        if (_auth == McpAuth.oauth) _oauth(context),
        if (_confirmingInsecure) _insecureConfirmation(context),
        if (_result case final result?)
          p(
            classes:
                'text-ui-base ${_resultOk ? 'text-muted-foreground' : 'text-destructive'}',
            attributes: <String, String>{
              'role': _resultOk ? 'status' : 'alert',
            },
            [Component.text(result)],
          ),
        if (_server.approvals.isNotEmpty) _approvals(context),
        div(classes: 'flex justify-end gap-2', [
          button(
            [Component.text(t.app.cancel)],
            classes: 'rounded px-3 py-1.5 text-ui-base hover:bg-accent',
            type: ButtonType.button,
            onClick: component.onDone,
          ),
          button(
            [Component.text(t.app.directMcpTestConnection)],
            classes:
                'rounded border border-border px-3 py-1.5 text-ui-base '
                'hover:bg-accent disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_test(context)),
          ),
          button(
            [Component.text(t.app.save)],
            classes:
                'rounded bg-primary px-3 py-1.5 text-ui-base '
                'text-primary-foreground disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_save(context, close: true)),
          ),
        ]),
      ],
    );
  }

  Component _oauth(BuildContext context) =>
      div(classes: 'flex flex-wrap items-center gap-2 text-ui-base', [
        span(classes: 'text-muted-foreground', [
          Component.text(
            _signingIn
                ? t.app.directMcpOAuthPending
                : _server.oauthConnected
                ? t.desktop.desktopMcpSignedIn
                : t.desktop.desktopMcpNotSignedIn,
          ),
        ]),
        if (_signingIn)
          button(
            [Component.text(t.app.cancel)],
            classes: 'rounded px-2.5 py-1 text-ui-sm hover:bg-accent',
            type: ButtonType.button,
            onClick: () => unawaited(
              context.read(mcpActionsProvider).cancelConnect(_server.id),
            ),
          )
        else ...[
          button(
            [
              Component.text(
                _server.oauthConnected
                    ? t.app.directMcpOAuthReconnect
                    : t.app.directMcpOAuthConnect,
              ),
            ],
            classes:
                'rounded border border-border px-2.5 py-1 text-ui-sm '
                'hover:bg-accent disabled:opacity-50',
            type: ButtonType.button,
            disabled: _busy,
            onClick: () => unawaited(_signIn(context)),
          ),
          if (_server.oauthConnected)
            button(
              [Component.text(t.app.directMcpOAuthDisconnect)],
              classes: 'rounded px-2.5 py-1 text-ui-sm hover:bg-accent',
              type: ButtonType.button,
              disabled: _busy,
              onClick: () => unawaited(_signOut(context)),
            ),
        ],
      ]);

  Component _insecureConfirmation(BuildContext context) => div(
    classes:
        'space-y-2 rounded border border-destructive/40 bg-destructive/10 '
        'p-2 text-ui-sm',
    attributes: const <String, String>{'role': 'alertdialog'},
    [
      p(classes: 'font-medium', [
        Component.text(t.app.directMcpInsecureCredentialsTitle),
      ]),
      p([Component.text(t.app.directMcpInsecureCredentialsMessage)]),
      div(classes: 'flex gap-2', [
        button(
          [Component.text(t.app.directMcpInsecureCredentialsConfirm)],
          classes:
              'rounded bg-destructive px-2 py-1 text-destructive-foreground',
          type: ButtonType.button,
          onClick: () {
            setState(() {
              _insecureAllowed = true;
              _confirmingInsecure = false;
            });
            unawaited(_save(context, close: true));
          },
        ),
        button(
          [Component.text(t.app.cancel)],
          classes: 'rounded px-2 py-1',
          type: ButtonType.button,
          onClick: () => setState(() => _confirmingInsecure = false),
        ),
      ]),
    ],
  );

  Component _approvals(BuildContext context) =>
      div(classes: 'space-y-1.5 border-t border-border pt-3', [
        div(classes: 'flex items-center justify-between', [
          span(classes: 'text-ui-base font-medium', [
            Component.text(t.app.directMcpRememberedApprovalsTitle),
          ]),
          button(
            [Component.text(t.app.directMcpRememberedApprovalsRevokeAll)],
            classes: 'rounded px-2 py-0.5 text-ui-sm hover:bg-accent',
            type: ButtonType.button,
            onClick: () => unawaited(_forget(context, null)),
          ),
        ]),
        p(classes: 'text-ui-sm text-muted-foreground', [
          Component.text(t.app.directMcpRememberedApprovalsSubtitle),
        ]),
        ul(classes: 'space-y-1', [
          for (final approval in _server.approvals)
            li(classes: 'flex items-center justify-between text-ui-base', [
              span(classes: 'font-mono text-xs', [
                Component.text(approval.toolName),
              ]),
              button(
                [Component.text(t.app.directMcpRememberedApprovalRevoke)],
                classes: 'rounded px-2 py-0.5 text-ui-sm hover:bg-accent',
                type: ButtonType.button,
                onClick: () => unawaited(_forget(context, approval.digest)),
              ),
            ]),
        ]),
      ]);

  Future<void> _test(BuildContext context) async {
    setState(() {
      _busy = true;
      _resultOk = true;
      _result = t.app.directMcpTesting;
    });
    try {
      final result = await context.read(mcpActionsProvider).test(_edit());
      if (!mounted) return;
      setState(() {
        _resultOk = result.reachable;
        _result = result.reachable
            ? t.app.directMcpTestSucceeded(count: result.toolCount ?? 0)
            : (result.message ?? t.app.directMcpTestFailed);
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = t.app.directMcpTestFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Saves; true when it did. [close] ends editing afterwards.
  Future<bool> _save(BuildContext context, {required bool close}) async {
    setState(() => _busy = true);
    try {
      final list = await context.read(mcpActionsProvider).save(_edit());
      if (!mounted) return true;
      if (close) {
        component.onDone();
      } else {
        // A new server now has an id, which a sign-in needs.
        final saved =
            list.servers
                .where((server) => server.id == _server.id)
                .firstOrNull ??
            list.servers.lastOrNull;
        if (saved != null) setState(() => _server = saved);
      }
      return true;
    } on RpcError catch (error) {
      if (!mounted) return false;
      setState(() {
        if (error.args['reason'] == 'insecure') {
          _confirmingInsecure = true;
          _result = null;
          return;
        }
        _resultOk = false;
        _result = switch (error.code) {
          ConduitErrorCodes.invalidParams =>
            error.debugMessage ?? t.app.directMcpSaveFailed,
          _ => t.app.directMcpSaveFailed,
        };
      });
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Saves what is on screen, then signs in in the browser.
  Future<void> _signIn(BuildContext context) async {
    if (!await _save(context, close: false) || !mounted) return;
    if (_server.id.isEmpty) {
      setState(() => _result = t.desktop.desktopMcpSaveFirst);
      return;
    }
    final actions = context.read(mcpActionsProvider);
    setState(() {
      _signingIn = true;
      _resultOk = true;
      _result = null;
    });
    try {
      final list = await actions.connect(_server.id);
      if (!mounted) return;
      setState(() {
        _server =
            list.servers
                .where((server) => server.id == _server.id)
                .firstOrNull ??
            _server;
        _resultOk = true;
        _result = t.app.directMcpOAuthConnected;
      });
    } on RpcError catch (error) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = error.args['detail'] ?? t.app.directMcpOAuthConnectFailed;
      });
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  Future<void> _signOut(BuildContext context) async {
    setState(() => _busy = true);
    try {
      final list = await context
          .read(mcpActionsProvider)
          .disconnect(_server.id);
      if (!mounted) return;
      setState(
        () => _server =
            list.servers
                .where((server) => server.id == _server.id)
                .firstOrNull ??
            _server,
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = t.app.directMcpOAuthDisconnectFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(BuildContext context, String? digest) async {
    try {
      final list = await context
          .read(mcpActionsProvider)
          .forgetApproval(_server.id, digest: digest);
      if (!mounted) return;
      setState(
        () => _server =
            list.servers
                .where((server) => server.id == _server.id)
                .firstOrNull ??
            _server,
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = t.app.directMcpRememberedApprovalRevokeFailed;
      });
    }
  }
}
