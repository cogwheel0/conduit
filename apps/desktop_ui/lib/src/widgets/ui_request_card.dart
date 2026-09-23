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
              'pointer-events-auto mx-auto w-full max-w-md rounded border '
              'border-border bg-popover p-4 text-popover-foreground shadow-lg',
          attributes: <String, String>{
            'role': 'alertdialog',
            'aria-label': t.desktop.desktopServerAsks,
          },
          [
            _RequestBody(key: ValueKey(request.requestId), request: request),
            if (waiting.length > 1)
              p(classes: 'mt-2 text-xs text-muted-foreground', [
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

  @override
  Component build(BuildContext context) {
    final args = component.request.messageArgs;
    final title = args['title'] ?? '';
    final message = args['message'] ?? '';
    return div(classes: 'space-y-3', [
      if (title.isNotEmpty)
        h2(classes: 'text-sm font-semibold', [Component.text(title)]),
      if (message.isNotEmpty)
        p(classes: 'whitespace-pre-wrap text-sm text-muted-foreground', [
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
              'rounded px-3 py-1.5 text-sm text-muted-foreground '
              'hover:bg-accent',
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
          classes:
              'rounded bg-primary px-3 py-1.5 text-sm text-primary-foreground',
          type: ButtonType.button,
          onClick: () => _answer(context, allow: true),
        ),
      ]),
    ]);
  }
}
