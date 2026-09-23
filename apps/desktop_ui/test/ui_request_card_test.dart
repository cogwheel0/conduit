@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/l10n/strings.g.dart';
import 'package:conduit_desktop_ui/src/rpc/ui_request_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/ui_request_card.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

/// Records answers instead of sending them.
class _Recording extends UiRequests {
  _Recording(this._initial);
  final List<UiRequest> _initial;
  final List<({String id, bool allow, String? text})> answers = [];

  @override
  List<UiRequest> build() => _initial;

  @override
  Future<void> answer(
    UiRequest request, {
    required bool allow,
    String? text,
  }) async {
    answers.add((id: request.requestId, allow: allow, text: text));
    state = [
      for (final r in state)
        if (r.requestId != request.requestId) r,
    ];
  }

  final List<({String id, String choice})> choices = [];

  @override
  Future<void> answerWith(
    UiRequest request, {
    required String choice,
    String? text,
  }) async {
    choices.add((id: request.requestId, choice: choice));
    state = [
      for (final r in state)
        if (r.requestId != request.requestId) r,
    ];
  }
}

const _mcp = UiRequest(
  requestId: 'r3',
  kind: UiRequestKind.mcpApproval,
  messageCode: 'mcp.approval',
  messageArgs: {'serverName': 'Docs', 'toolName': 'search'},
  detail: {'arguments': '{"query":"llamas"}'},
);

const _confirm = UiRequest(
  requestId: 'r1',
  kind: UiRequestKind.confirm,
  messageCode: 'server.prompt',
  messageArgs: {'title': 'Run tool?', 'message': 'delete_file("a.txt")'},
);

const _prompt = UiRequest(
  requestId: 'r2',
  kind: UiRequestKind.inputPrompt,
  messageCode: 'server.prompt',
  messageArgs: {'title': 'Your name?', 'initialValue': 'Ada'},
  defaultChoice: 'cancel',
);

void main() {
  late _Recording recording;

  Component scoped(List<UiRequest> waiting) {
    recording = _Recording(waiting);
    return ProviderScope(
      overrides: [uiRequestsProvider.overrideWith(() => recording)],
      child: const UiRequestCard(),
    );
  }

  testComponents('nothing waiting, nothing shown', (tester) async {
    tester.pumpComponent(scoped(const []));
    await pumpEventQueue();
    expect(find.text(t.desktop.desktopAllow), findsNothing);
  });

  testComponents('a confirmation shows what the server asked', (tester) async {
    tester.pumpComponent(scoped(const [_confirm]));
    await pumpEventQueue();
    expect(find.text('Run tool?'), findsOneComponent);
    // As text: this is model- or server-written, and the origin holds the
    // preload bridge.
    expect(find.text('delete_file("a.txt")'), findsOneComponent);
  });

  testComponents('allow and deny answer, and the card goes', (tester) async {
    tester.pumpComponent(scoped(const [_confirm, _prompt]));
    await pumpEventQueue();

    await tester.click(
      find.ancestor(
        of: find.text(t.desktop.desktopDeny),
        matching: find.tag('button'),
      ),
    );
    await pumpEventQueue();
    expect(recording.answers.single.allow, isFalse);
    // The next waiting request takes its place: its heading, and the same
    // words again as its input's hidden label.
    expect(find.text('Your name?'), findsNComponents(2));
  });

  testComponents('a prompt sends what is in its field', (tester) async {
    tester.pumpComponent(scoped(const [_prompt]));
    await pumpEventQueue();
    await tester.click(
      find.ancestor(of: find.text(t.app.ok), matching: find.tag('button')),
    );
    await pumpEventQueue();
    expect(recording.answers.single, (id: 'r2', allow: true, text: 'Ada'));
  });

  testComponents('the server can relabel the buttons', (tester) async {
    tester.pumpComponent(
      scoped(const [
        UiRequest(
          requestId: 'r3',
          kind: UiRequestKind.confirm,
          messageCode: 'server.prompt',
          messageArgs: {'title': 'Deploy?', 'confirmLabel': 'Ship it'},
        ),
      ]),
    );
    await pumpEventQueue();
    expect(find.text('Ship it'), findsOneComponent);
  });

  testComponents('an MCP tool shows its call, and each answer says how long', (
    tester,
  ) async {
    tester.pumpComponent(scoped(const [_mcp, _mcp]));
    await pumpEventQueue();
    expect(find.text(t.app.directMcpApprovalTitle), findsOneComponent);
    expect(find.text('search'), findsOneComponent);
    expect(find.text('{"query":"llamas"}'), findsOneComponent);

    await tester.click(
      find.ancestor(
        of: find.text(t.app.directMcpApprovalAllowSession),
        matching: find.tag('button'),
      ),
    );
    await pumpEventQueue();
    expect(recording.choices.single.choice, 'allowSession');
  });

  testComponents('"always" asks once more before it counts', (tester) async {
    tester.pumpComponent(scoped(const [_mcp]));
    await pumpEventQueue();
    await tester.click(
      find.ancestor(
        of: find.text(t.app.directMcpApprovalAllowAlways),
        matching: find.tag('button'),
      ),
    );
    await pumpEventQueue();
    expect(recording.choices, isEmpty);
    expect(
      find.text(
        t.app.directMcpApprovalAlwaysMessage(
          serverName: 'Docs',
          toolName: 'search',
        ),
      ),
      findsOneComponent,
    );
    await tester.click(
      find.ancestor(
        of: find.text(t.app.directMcpApprovalAllowAlways),
        matching: find.tag('button'),
      ),
    );
    await pumpEventQueue();
    expect(recording.choices.single.choice, 'allowAlways');
  });
}
