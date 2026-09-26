@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/rpc/chat_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/conversation_map.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr/dom.dart' show button, ul;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

class _Actions extends ChatActions {
  _Actions(super.ref);

  final List<String> calls = <String>[];

  @override
  Future<void> setCurrent(String chatId, String messageId) async =>
      calls.add('current($chatId,$messageId)');
}

/// q1 -> a1 -> q2 -> {a2, a2b}: one run, then a regeneration's fork.
const _tree = ChatTree(
  chatId: 'c1',
  currentId: 'a2b',
  nodes: <ChatTreeNode>[
    ChatTreeNode(id: 'q1', role: 'user', preview: 'First', timestampMs: 1),
    ChatTreeNode(
      id: 'a1',
      parentId: 'q1',
      role: 'assistant',
      preview: 'Reply one',
      timestampMs: 2,
    ),
    ChatTreeNode(
      id: 'q2',
      parentId: 'a1',
      role: 'user',
      preview: 'Second',
      timestampMs: 3,
    ),
    ChatTreeNode(
      id: 'a2',
      parentId: 'q2',
      role: 'assistant',
      preview: 'Old answer',
      timestampMs: 4,
    ),
    ChatTreeNode(
      id: 'a2b',
      parentId: 'q2',
      role: 'assistant',
      preview: 'New answer',
      timestampMs: 5,
    ),
  ],
);

void main() {
  testComponents('a run is flat; only the fork indents', (tester) async {
    late _Actions actions;
    tester.pumpComponent(
      ProviderScope(
        overrides: [
          chatActionsProvider.overrideWith((ref) => actions = _Actions(ref)),
        ],
        child: const ConversationMap(tree: _tree),
      ),
    );
    await pumpEventQueue();
    // The outer list, the fork's list, and one list per branch.
    expect(find.tag('ul'), findsNComponents(4));
    expect(find.byComponentPredicate((c) => c is ul), findsNComponents(4));

    // The current answer is marked, and choosing the old one shows it.
    expect(
      find.byComponentPredicate(
        (c) => c is button && c.attributes?['aria-current'] == 'true',
      ),
      findsOneComponent,
    );
    await tester.click(find.componentWithText(button, 'Old answer'));
    expect(actions.calls, <String>['current(c1,a2)']);
  });
}
