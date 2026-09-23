import 'dart:async';

import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../l10n/strings.g.dart';
import '../rpc/ui_request_providers.dart';
import 'form_field.dart';

/// The server's question, waiting for an answer (WP-3.6).
///
/// Shows the oldest waiting request. A tool asking to run, or a function
/// asking for a value mid-reply, holds up that reply until someone answers.
///
/// `alertdialog` so it is announced, but not modal. The person may need to
/// read the transcript to decide, and a modal would stop them.
///
/// The server wrote the title and message. They are shown as text, never
/// as markup: this is the origin that holds the preload bridge.
class UiRequestCard extends StatelessComponent {
  const UiRequestCard({super.key});

  @override
  Component build(BuildContext context) {
    final waiting = context.watch(uiRequestsProvider);
    if (waiting.isEmpty) return const Component.fragment([]);
    final request = waiting.first;
    return div(
      classes: 'pointer-events-none fixed inset-x-0 bottom-28 z-40 px-4',
      [
        div(
          classes:
              'pointer-events-auto mx-auto w-full max-w-md rounded-lg border '
              'border-border bg-popover p-4 text-popover-foreground shadow-lg',
          attributes: <String, String>{
            'role': 'alertdialog',
            'aria-label': t.desktop.desktopServerAsks,
          },
          [
            _RequestBody(key: ValueKey(request.requestId), request: request),
            if (waiting.length > 1)
              p(classes: 'mt-2 text-ui-sm text-foreground-subtle', [
                Component.text('+${waiting.length - 1}'),
              ]),
          ],
        ),
      ],
    );
  }
}

class _RequestBody extends StatefulComponent {
  const _RequestBody({required this.request, super.key});

  final UiRequest request;

  @override
  State<_RequestBody> createState() => _RequestBodyState();
}

class _RequestBodyState extends State<_RequestBody> {
  late String _text = component.request.messageArgs['initialValue'] ?? '';

  bool get _isPrompt => component.request.kind == UiRequestKind.inputPrompt;

  void _answer(BuildContext context, {required bool allow}) => unawaited(
    context
        .read(uiRequestsProvider.notifier)
        .answer(
          component.request,
          allow: allow,
          text: _isPrompt ? _text : null,
        ),
  );

  /// "Always allow" asks once more, as on mobile: it outlives this turn.
  bool _confirmingAlways = false;

  void _choose(BuildContext context, String choice) => unawaited(
    context
        .read(uiRequestsProvider.notifier)
        .answerWith(component.request, choice: choice),
  );

  /// An MCP tool asking to run (M4): which server, which tool, with what,
  /// and how long a yes should last.
  Component _mcpApproval(BuildContext context) {
    final args = component.request.messageArgs;
    final server = args['serverName'] ?? '';
    final tool = args['toolName'] ?? '';
    final arguments = '${component.request.detail['arguments'] ?? ''}';
    Component action(String text, String choice, {bool primary = false}) =>
        button(
          [Component.text(text)],
          classes: primary
              ? 'rounded-lg bg-primary px-3 py-1.5 text-ui-base text-primary-foreground'
              : 'rounded-lg px-3 py-1.5 text-ui-base hover:bg-hover',
          type: ButtonType.button,
          onClick: () => _choose(context, choice),
        );
    return div(classes: 'space-y-3', [
      h2(classes: 'text-ui-base font-semibold', [
        Component.text(t.app.directMcpApprovalTitle),
      ]),
      p(classes: 'text-ui-base', [
        span(classes: 'font-medium', [Component.text(tool)]),
        Component.text(' · $server'),
      ]),
      if (arguments.isNotEmpty && arguments != '{}')
        pre(
          classes:
              'max-h-40 overflow-auto whitespace-pre-wrap break-all rounded-lg '
              'bg-muted p-2 font-mono text-xs',
          [Component.text(arguments)],
        ),
      if (_confirmingAlways) ...[
        p(classes: 'text-ui-base text-foreground-subtle', [
          Component.text(
            t.app.directMcpApprovalAlwaysMessage(
              serverName: server,
              toolName: tool,
            ),
          ),
        ]),
        div(classes: 'flex justify-end gap-2', [
          button(
            [Component.text(t.app.cancel)],
            classes: 'rounded-lg px-3 py-1.5 text-ui-base hover:bg-hover',
            type: ButtonType.button,
            onClick: () => setState(() => _confirmingAlways = false),
          ),
          action(
            t.app.directMcpApprovalAllowAlways,
            'allowAlways',
            primary: true,
          ),
        ]),
      ] else
        div(classes: 'flex flex-wrap justify-end gap-2', [
          action(t.app.directMcpApprovalDeny, 'deny'),
          button(
            [Component.text(t.app.directMcpApprovalAllowAlways)],
            classes: 'rounded-lg px-3 py-1.5 text-ui-base hover:bg-hover',
            type: ButtonType.button,
            onClick: () => setState(() => _confirmingAlways = true),
          ),
          action(t.app.directMcpApprovalAllowSession, 'allowSession'),
          action(t.app.directMcpApprovalAllowOnce, 'allow', primary: true),
        ]),
    ]);
  }

  /// A Hermes agent asking to go on (M7): what it wants to do, and the
  /// answers it offers -- once, for the session, always, or no.
  Component _hermesApproval(BuildContext context) {
    final summary = component.request.messageArgs['summary'] ?? '';
    final offered = <String>[
      for (final choice
          in (component.request.detail['choices'] as List?) ??
              const <Object?>[])
        '$choice',
    ];
    String label(String choice) => switch (choice) {
      'once' => t.app.hermesApprovalAllowOnce,
      'session' => t.app.hermesApprovalAllowSession,
      'always' => t.app.hermesApprovalAlwaysAllow,
      'deny' => t.app.hermesApprovalDenyAction,
      _ => choice,
    };
    return div(classes: 'space-y-3', [
      h2(classes: 'text-ui-base font-semibold', [
        Component.text(t.app.hermesApprovalRequired),
      ]),
      p(classes: 'whitespace-pre-wrap text-ui-base', [
        Component.text(
          summary.isEmpty ? t.app.hermesApprovalFallback : summary,
        ),
      ]),
      div(classes: 'flex flex-wrap justify-end gap-2', [
        for (final choice in <String>[
          if (offered.contains('deny') || offered.isEmpty) 'deny',
          for (final choice in offered)
            if (choice != 'deny' && choice != 'once') choice,
          if (offered.contains('once') || offered.isEmpty) 'once',
        ])
          button(
            [Component.text(label(choice))],
            classes: choice == 'once'
                ? 'rounded-lg bg-primary px-3 py-1.5 text-ui-base text-primary-foreground'
                : 'rounded-lg px-3 py-1.5 text-ui-base hover:bg-hover',
            type: ButtonType.button,
            onClick: () => _choose(context, choice),
          ),
      ]),
    ]);
  }

  @override
  Component build(BuildContext context) {
    if (component.request.kind == UiRequestKind.mcpApproval) {
      return _mcpApproval(context);
    }
    if (component.request.kind == UiRequestKind.hermesDecision) {
      return _hermesApproval(context);
    }
    final args = component.request.messageArgs;
    final title = args['title'] ?? '';
    final message = args['message'] ?? '';
    return div(classes: 'space-y-3', [
      if (title.isNotEmpty)
        h2(classes: 'text-ui-base font-semibold', [Component.text(title)]),
      if (message.isNotEmpty)
        p(classes: 'whitespace-pre-wrap text-ui-base text-foreground-subtle', [
          Component.text(message),
        ]),
      if (_isPrompt)
        textField(
          id: 'ui-request-input',
          labelText: title.isEmpty ? t.desktop.desktopServerAsks : title,
          hideLabel: true,
          placeholder: args['placeholder'],
          value: _text,
          autofocus: true,
          onInput: (value) => setState(() => _text = value),
        ),
      div(classes: 'flex justify-end gap-2', [
        button(
          [
            Component.text(
              args['cancelLabel'] ??
                  (_isPrompt ? t.app.cancel : t.desktop.desktopDeny),
            ),
          ],
          classes:
              'rounded-lg px-3 py-1.5 text-ui-base text-foreground-subtle '
              'hover:bg-hover',
          type: ButtonType.button,
          onClick: () => _answer(context, allow: false),
        ),
        button(
          [
            Component.text(
              args['confirmLabel'] ??
                  (_isPrompt ? t.app.ok : t.desktop.desktopAllow),
            ),
          ],
          classes: 'rounded-lg bg-primary px-3 py-1.5 text-ui-base text-primary-foreground',
          type: ButtonType.button,
          onClick: () => _answer(context, allow: true),
        ),
      ]),
    ]);
  }
}
