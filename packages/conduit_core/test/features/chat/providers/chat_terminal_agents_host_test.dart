import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _agent = 'agent:bench:codex:gpt-5.1';

class _ReviewerOff extends ReviewerMode {
  @override
  bool build() => false;
}

Conversation _chat({String? model, List<String?> replies = const []}) =>
    Conversation(
      id: 'chat-1',
      title: 'Sketches',
      createdAt: DateTime.utc(2026, 3, 1),
      updatedAt: DateTime.utc(2026, 3, 1),
      model: model,
      messages: [
        for (final (i, reply) in replies.indexed)
          ChatMessage(
            id: 'm-$i',
            role: 'assistant',
            content: 'Done.',
            model: reply,
            timestamp: DateTime.utc(2026, 3, 1),
          ),
      ],
    );

TerminalServerInfo _server(String id, {required TerminalServerKind kind}) =>
    TerminalServerInfo(
      kind: kind,
      selectionId: id,
      systemServerId: kind == TerminalServerKind.system ? id : null,
      name: 'Bench',
      baseUrl: Uri.parse('http://127.0.0.1:9/$id'),
    );

void main() {
  group('conversationUsesTerminalAgent', () {
    test('an agent selected, started with, or replying counts', () {
      check(
        conversationUsesTerminalAgent(const Model(id: _agent, name: 'C'), null),
      ).isTrue();
      check(conversationUsesTerminalAgent(null, _chat(model: _agent))).isTrue();
      check(
        conversationUsesTerminalAgent(
          null,
          _chat(model: 'fake-model', replies: ['fake-model', _agent]),
        ),
      ).isTrue();
    });

    test('a chat with ordinary models only does not', () {
      check(
        conversationUsesTerminalAgent(
          const Model(id: 'fake-model', name: 'Kestrel'),
          _chat(model: 'fake-model', replies: ['fake-model', null]),
        ),
      ).isFalse();
      check(conversationUsesTerminalAgent(null, null)).isFalse();
    });
  });

  group('terminalAgentScopeFor', () {
    ProviderContainer container(List<TerminalServerInfo> servers) {
      final c = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWith(_ReviewerOff.new),
          openWebUiAccountAvailableProvider.overrideWithValue(true),
          terminalAgentsSupportedProvider.overrideWithValue(true),
          terminalAvailableServersProvider.overrideWith((ref) async => servers),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test("a new chat on the server's own terminal is offered agents", () async {
      final c = container([_server('bench', kind: TerminalServerKind.system)]);
      c.read(selectedTerminalIdProvider.notifier).set('bench');
      final scope = await terminalAgentScopeFor(c, null);
      check(scope).isNotNull()
        ..has((s) => s.terminalId, 'terminalId').equals('bench')
        ..has((s) => s.terminalName, 'terminalName').equals('Bench')
        ..has((s) => s.chatId, 'chatId').isNull();
    });

    test('a temporary chat or a terminal added by address is not', () async {
      final c = container([_server('bench', kind: TerminalServerKind.direct)]);
      c.read(selectedTerminalIdProvider.notifier).set('bench');
      check(await terminalAgentScopeFor(c, null)).isNull();
      final s = container([_server('bench', kind: TerminalServerKind.system)]);
      s.read(selectedTerminalIdProvider.notifier).set('bench');
      check(await terminalAgentScopeFor(s, null, temporary: true)).isNull();
    });

    test('no terminal selected offers none', () async {
      final c = container([_server('bench', kind: TerminalServerKind.system)]);
      check(await terminalAgentScopeFor(c, null)).isNull();
    });
  });
}
