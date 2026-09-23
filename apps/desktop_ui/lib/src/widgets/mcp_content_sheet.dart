import 'dart:async';
import 'dart:convert';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/mcp_providers.dart';
import 'form_field.dart';

/// The most a message may hold, as on mobile: an insertion that would take
/// the draft past it is refused rather than truncated.
const int kComposerMaxBytes = 256 * 1024;

/// MCP content (M4): a server's prompts and resources, previewed and
/// inserted into the draft as text.
///
/// Mobile's sheet, as a panel over the composer. The server wrote every
/// name and every word of the preview; all of it is shown as text.
class McpContentSheet extends StatefulComponent {
  const McpContentSheet({
    required this.servers,
    required this.draft,
    required this.onInsert,
    required this.onClose,
    super.key,
  });

  /// The MCP servers the composer offers, as `local_mcp:<id>` tools.
  final List<ToolSummary> servers;

  /// What is already typed, so an insertion that would overflow the
  /// message can be refused before it happens.
  final String draft;
  final void Function(String text) onInsert;
  final void Function() onClose;

  @override
  State<McpContentSheet> createState() => _McpContentSheetState();
}

/// What is chosen in the list: one prompt or one resource.
typedef _Choice = ({McpPromptSummary? prompt, McpResourceSummary? resource});

class _McpContentSheetState extends State<McpContentSheet> {
  late String _serverId = _idOf(component.servers.first);
  McpContent? _content;
  bool _loading = false;
  String? _error;
  String _query = '';
  _Choice? _chosen;
  final Map<String, String> _arguments = <String, String>{};
  McpContentPreview? _preview;
  bool _busy = false;

  static String _idOf(ToolSummary tool) =>
      tool.id.substring(tool.id.indexOf(':') + 1);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _content = null;
      _chosen = null;
      _preview = null;
    });
    try {
      final content = await context.read(mcpActionsProvider).content(_serverId);
      if (!mounted) return;
      setState(() => _content = content);
    } on Object {
      if (!mounted) return;
      setState(() => _error = t.app.directMcpContentLoadFailed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _matches(String name, String description) {
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        name.toLowerCase().contains(query) ||
        description.toLowerCase().contains(query);
  }

  @override
  Component build(BuildContext context) {
    final content = _content;
    final prompts = <McpPromptSummary>[
      for (final prompt in content?.prompts ?? const <McpPromptSummary>[])
        if (_matches(prompt.displayName, prompt.description)) prompt,
    ];
    final resources = <McpResourceSummary>[
      for (final resource in content?.resources ?? const <McpResourceSummary>[])
        if (_matches(resource.displayName, resource.uri)) resource,
    ];
    final empty =
        content != null && content.prompts.isEmpty && content.resources.isEmpty;
    return div(
      classes: 'mt-2 space-y-3 rounded border border-border bg-background p-3',
      attributes: <String, String>{
        'role': 'dialog',
        'aria-label': t.app.directMcpContentTitle,
      },
      [
        div(classes: 'flex items-center gap-2', [
          h2(classes: 'flex-1 text-ui-base font-semibold', [
            Component.text(t.app.directMcpContentTitle),
          ]),
          button(
            [Component.text('↻')],
            classes: 'rounded px-2 py-0.5 text-ui-sm hover:bg-accent',
            type: ButtonType.button,
            attributes: <String, String>{
              'aria-label': t.app.directMcpContentRefresh,
            },
            onClick: () => unawaited(_load()),
          ),
          button(
            [Component.text('×')],
            classes: 'rounded px-2 py-0.5 text-ui-sm hover:bg-accent',
            type: ButtonType.button,
            attributes: <String, String>{'aria-label': t.app.close},
            onClick: component.onClose,
          ),
        ]),
        if (component.servers.length > 1)
          div(classes: 'space-y-1', [
            label(
              [Component.text(t.app.directMcpContentServer)],
              htmlFor: 'mcp-content-server',
              classes: 'text-ui-sm font-medium',
            ),
            select(
              [
                for (final server in component.servers)
                  option(
                    value: _idOf(server),
                    selected: _idOf(server) == _serverId,
                    [Component.text(server.name)],
                  ),
              ],
              id: 'mcp-content-server',
              classes:
                  'w-full rounded border border-border bg-background px-2 '
                  'py-1 text-ui-base',
              onChange: (values) {
                final id = values.firstOrNull;
                if (id == null || id == _serverId) return;
                setState(() => _serverId = id);
                unawaited(_load());
              },
            ),
          ]),
        textField(
          id: 'mcp-content-search',
          labelText: t.app.directMcpContentSearch,
          hideLabel: true,
          placeholder: t.app.directMcpContentSearch,
          value: _query,
          onInput: (value) => setState(() => _query = value),
        ),
        if (_loading)
          p(classes: 'text-ui-sm text-muted-foreground', [
            Component.text(t.app.directMcpContentLoading),
          ]),
        if (_error case final error?) formError(error),
        if (empty)
          p(classes: 'text-ui-sm text-muted-foreground', [
            Component.text(t.app.directMcpContentEmpty),
          ])
        else if (content != null && prompts.isEmpty && resources.isEmpty)
          p(classes: 'text-ui-sm text-muted-foreground', [
            Component.text(t.app.directMcpContentNoMatches),
          ]),
        if (prompts.isNotEmpty) ...[
          h3(classes: 'text-ui-sm font-medium text-muted-foreground', [
            Component.text(t.app.directMcpContentPrompts),
          ]),
          ul(classes: 'max-h-40 space-y-1 overflow-auto', [
            for (final prompt in prompts)
              _item(
                prompt.displayName,
                prompt.description,
                chosen: _chosen?.prompt?.name == prompt.name,
                onChoose: () => _choose((prompt: prompt, resource: null)),
              ),
          ]),
        ],
        if (resources.isNotEmpty) ...[
          h3(classes: 'text-ui-sm font-medium text-muted-foreground', [
            Component.text(t.app.directMcpContentResources),
          ]),
          ul(classes: 'max-h-40 space-y-1 overflow-auto', [
            for (final resource in resources)
              _item(
                resource.displayName,
                resource.uri,
                chosen: _chosen?.resource?.uri == resource.uri,
                onChoose: () => _choose((prompt: null, resource: resource)),
              ),
          ]),
        ],
        if (_chosen?.prompt case final prompt?)
          for (final argument in prompt.arguments)
            textField(
              id: 'mcp-arg-${argument.name}',
              labelText: argument.required
                  ? '${argument.label} *'
                  : argument.label,
              placeholder: argument.description.isEmpty
                  ? null
                  : argument.description,
              value: _arguments[argument.name] ?? '',
              onInput: (value) => setState(() {
                _arguments[argument.name] = value;
                _preview = null;
              }),
            ),
        if (_preview case final preview?) ...[
          h3(classes: 'text-ui-sm font-medium text-muted-foreground', [
            Component.text(t.app.directMcpContentPreviewTitle),
          ]),
          pre(
            classes:
                'max-h-48 overflow-auto whitespace-pre-wrap rounded bg-muted '
                'p-2 text-ui-sm',
            [Component.text(_format(preview))],
          ),
        ],
        if (_chosen != null)
          div(classes: 'flex justify-end gap-2', [
            button(
              [Component.text(t.app.directMcpContentPreviewTitle)],
              classes:
                  'rounded border border-border px-3 py-1 text-ui-base '
                  'hover:bg-accent disabled:opacity-50',
              type: ButtonType.button,
              disabled: _busy || !_argumentsComplete,
              onClick: () => unawaited(_fetch()),
            ),
            button(
              [Component.text(t.app.directMcpContentInsert)],
              classes:
                  'rounded bg-primary px-3 py-1 text-ui-base '
                  'text-primary-foreground disabled:opacity-50',
              type: ButtonType.button,
              disabled: _busy || !_argumentsComplete,
              onClick: () => unawaited(_insert()),
            ),
          ]),
      ],
    );
  }

  Component _item(
    String name,
    String detail, {
    required bool chosen,
    required void Function() onChoose,
  }) => li([
    button(
      [
        span(classes: 'block truncate text-ui-base', [Component.text(name)]),
        if (detail.isNotEmpty)
          span(classes: 'block truncate text-ui-sm text-muted-foreground', [
            Component.text(detail),
          ]),
      ],
      classes:
          'w-full rounded px-2 py-1 text-left hover:bg-accent '
          '${chosen ? 'bg-accent' : ''}',
      type: ButtonType.button,
      attributes: <String, String>{'aria-pressed': '$chosen'},
      onClick: onChoose,
    ),
  ]);

  void _choose(_Choice choice) => setState(() {
    _chosen = choice;
    _arguments.clear();
    _preview = null;
    _error = null;
  });

  bool get _argumentsComplete {
    final prompt = _chosen?.prompt;
    if (prompt == null) return true;
    return prompt.arguments.every(
      (argument) =>
          !argument.required ||
          (_arguments[argument.name]?.trim().isNotEmpty ?? false),
    );
  }

  /// The preview as it would be inserted: a heading naming where it came
  /// from, then each message under its role, as mobile writes it.
  String _format(McpContentPreview preview) {
    final server = _content?.serverName ?? '';
    final chosen = _chosen;
    if (chosen?.prompt case final prompt?) {
      return <String>[
        t.app.directMcpContentPromptHeading(
          serverName: server,
          promptName: prompt.displayName,
        ),
        for (final message in preview.messages)
          '${_role(message.role)}:\n${message.text}',
      ].join('\n\n');
    }
    final text = preview.messages.map((message) => message.text).join('\n');
    return '${t.app.directMcpContentResourceHeading(serverName: server, resourceUri: chosen?.resource?.uri ?? '')}'
        '\n\n$text';
  }

  static String _role(String role) => switch (role) {
    'assistant' => t.app.directMcpContentRoleAssistant,
    _ => t.app.directMcpContentRoleUser,
  };

  Future<McpContentPreview?> _fetch() async {
    final chosen = _chosen;
    // The buttons are disabled for both, but a handler should not trust
    // that it can only be reached through an enabled button.
    if (chosen == null || _busy || !_argumentsComplete) return null;
    setState(() {
      _busy = true;
      _error = null;
    });
    final actions = context.read(mcpActionsProvider);
    try {
      final preview = chosen.prompt != null
          ? await actions.getPrompt(
              McpGetPrompt(
                serverId: _serverId,
                name: chosen.prompt!.name,
                arguments: <String, String>{
                  for (final entry in _arguments.entries)
                    if (entry.value.trim().isNotEmpty)
                      entry.key: entry.value.trim(),
                },
              ),
            )
          : await actions.readResource(
              McpReadResource(serverId: _serverId, uri: chosen.resource!.uri),
            );
      if (!mounted) return null;
      setState(() => _preview = preview);
      return preview;
    } on RpcError catch (error) {
      if (!mounted) return null;
      setState(
        () => _error = switch (error.args['reason']) {
          'changed' => t.app.directMcpContentChanged,
          'unsupported' => t.app.directMcpContentUnsupported,
          'tooLarge' => t.app.directMcpContentTooLarge,
          _ => t.app.directMcpContentRequestFailed,
        },
      );
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _insert() async {
    final preview = _preview ?? await _fetch();
    if (preview == null || !mounted) return;
    final text = _format(preview);
    final draft = component.draft;
    final combined = draft.trim().isEmpty ? text : '$draft\n\n$text';
    if (utf8.encode(combined).length > kComposerMaxBytes) {
      setState(() => _error = t.app.directMcpContentComposerTooLarge);
      return;
    }
    component.onInsert(combined);
  }
}
