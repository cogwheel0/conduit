import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
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

/// The server's own terminals, as [read] answers each call.
class _Terminals extends TerminalService {
  _Terminals(this.read)
    : super(
        ApiService(
          serverConfig: const ServerConfig(
            id: 'host-test',
            name: 'Host test',
            url: 'https://owui.example',
          ),
          workerManager: WorkerManager(),
        ),
      );

  final Future<List<TerminalServerInfo>> Function() read;

  @override
  Future<List<TerminalServerInfo>> getSystemTerminalServers() => read();
}

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

    // The host holds no chat as the active one, so the account's list is
    // the sidebar's, which leaves out a terminal that needs a saved chat:
    // the chat asked about is offered it, from the terminals listed for it.
    test("a saved chat is offered a terminal that needs one", () async {
      final saved = TerminalServerInfo(
        kind: TerminalServerKind.system,
        selectionId: 'bench',
        systemServerId: 'bench',
        name: 'Bench',
        baseUrl: Uri.parse('http://127.0.0.1:9/bench'),
        requiresSavedChatContext: true,
      );
      final asked = <String>[];
      // Not granted to the chat yet when it is first listed.
      var granted = <TerminalServerInfo>[];
      final c = ProviderContainer(
        overrides: [
          reviewerModeProvider.overrideWith(_ReviewerOff.new),
          openWebUiAccountAvailableProvider.overrideWithValue(true),
          terminalAgentsSupportedProvider.overrideWithValue(true),
          terminalAvailableServersProvider.overrideWith((ref) async => []),
          terminalSystemServersForChatProvider.overrideWithValue((
            chatId,
          ) async {
            asked.add(chatId);
            return granted;
          }),
        ],
      );
      addTearDown(c.dispose);
      c.read(selectedTerminalIdProvider.notifier).set('bench');
      check(await terminalAgentScopeFor(c, _chat())).isNull();
      // Granted since: the next listing reads the chat's terminals again.
      granted = [saved];
      final scope = await terminalAgentScopeFor(c, _chat());
      check(scope).isNotNull()
        ..has((s) => s.terminalId, 'terminalId').equals('bench')
        ..has((s) => s.chatId, 'chatId').equals('chat-1');
      check(asked).deepEquals(['chat-1', 'chat-1']);
      // A new chat keeps to the account's list.
      check(await terminalAgentScopeFor(c, null)).isNull();
    });

    test(
      "two lookups for one saved chat at once each keep their own read",
      () async {
        final saved = TerminalServerInfo(
          kind: TerminalServerKind.system,
          selectionId: 'bench',
          systemServerId: 'bench',
          name: 'Bench',
          baseUrl: Uri.parse('http://127.0.0.1:9/bench'),
          requiresSavedChatContext: true,
        );
        final reads = <Completer<List<TerminalServerInfo>>>[];
        final c = ProviderContainer(
          overrides: [
            reviewerModeProvider.overrideWith(_ReviewerOff.new),
            openWebUiAccountAvailableProvider.overrideWithValue(true),
            terminalAgentsSupportedProvider.overrideWithValue(true),
            terminalAvailableServersProvider.overrideWith((ref) async => []),
            // The server's own terminals, a read held for each call; the
            // chat's list is the real provider's, over that service.
            terminalServiceProvider.overrideWithValue(
              _Terminals(() {
                final read = Completer<List<TerminalServerInfo>>();
                reads.add(read);
                return read.future;
              }),
            ),
          ],
        );
        addTearDown(c.dispose);
        c.read(selectedTerminalIdProvider.notifier).set('bench');
        final first = terminalAgentScopeFor(c, _chat());
        final second = terminalAgentScopeFor(c, _chat());
        check(reads).length.equals(2);
        // The first read answers while the second is still out: the first
        // lookup has its answer, whatever the second's turns out to be.
        reads.first.complete([saved]);
        check(await first)
            .isNotNull()
            .has((s) => s.terminalId, 'terminalId')
            .equals('bench');
        reads.last.complete([]);
        check(await second).isNull();
      },
    );

    test('no terminal selected offers none', () async {
      final c = container([_server('bench', kind: TerminalServerKind.system)]);
      check(await terminalAgentScopeFor(c, null)).isNull();
    });
  });
}
