import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_mcp_content_load_session.dart';
import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_content.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';
import 'package:test/test.dart';

final _server = DirectMcpServer(
  id: 'server-1',
  name: 'Docs',
  endpoint: 'https://mcp.example/mcp',
);

final _prompt = DirectMcpPromptSummary(
  name: 'summarize',
  displayName: 'Summarize',
  description: 'Condense a document',
  arguments: const [],
  inventoryIdentity: 'p1',
);

const _resource = DirectMcpResourceSummary(
  uri: 'file:///notes.md',
  displayName: 'Notes',
  description: 'Team notes',
  mimeType: 'text/markdown',
  inventoryIdentity: 'r1',
);

DirectMcpPromptPreview _preview(String text) => DirectMcpPromptPreview(
  messages: [DirectMcpPromptMessage(role: 'user', text: text)],
);

void main() {
  group('DirectMcpContentLoadSession', () {
    test('hands back what the loader returns', () async {
      final session = DirectMcpContentLoadSession();

      final outcome = await session.loadPrompt(
        (server, prompt, arguments, signal) async {
          check(server).identicalTo(_server);
          check(arguments).deepEquals({'topic': 'MCP'});
          return _preview('hello');
        },
        _server,
        _prompt,
        const {'topic': 'MCP'},
      );

      check(outcome)
          .isA<DirectMcpLoaded<DirectMcpPromptPreview>>()
          .has((loaded) => loaded.value.messages.single.text, 'text')
          .equals('hello');
    });

    test('reads a resource', () async {
      final session = DirectMcpContentLoadSession();

      final outcome = await session.loadResource(
        (server, resource, signal) async {
          check(resource.uri).equals('file:///notes.md');
          return const DirectMcpResourcePreview(text: 'body');
        },
        _server,
        _resource,
      );

      check(outcome)
          .isA<DirectMcpLoaded<DirectMcpResourcePreview>>()
          .has((loaded) => loaded.value.text, 'text')
          .equals('body');
    });

    test('reports a failure with its error', () async {
      final session = DirectMcpContentLoadSession();
      const failure = DirectProviderException(
        'too big',
        reason: DirectProviderFailureReason.tooLarge,
      );

      final outcome = await session.loadResource(
        (_, _, _) => throw failure,
        _server,
        _resource,
      );

      check(outcome)
          .isA<DirectMcpLoadFailed<DirectMcpResourcePreview>>()
          .has((failed) => failed.error, 'error')
          .identicalTo(failure);
    });

    test('a newer load aborts the one in flight and wins', () async {
      final session = DirectMcpContentLoadSession();
      final firstStarted = Completer<void>();
      final firstMayFinish = Completer<DirectMcpPromptPreview>();
      late final bool Function() firstAborted;

      final first = session.loadPrompt(
        (server, prompt, arguments, signal) {
          firstAborted = () => signal.aborted;
          firstStarted.complete();
          return firstMayFinish.future;
        },
        _server,
        _prompt,
        const {},
      );
      await firstStarted.future;

      final second = await session.loadPrompt(
        (_, _, _, _) async => _preview('second'),
        _server,
        _prompt,
        const {},
      );
      firstMayFinish.complete(_preview('first'));

      check(firstAborted()).isTrue();
      check(await first).isA<DirectMcpLoadSuperseded<DirectMcpPromptPreview>>();
      check(second).isA<DirectMcpLoaded<DirectMcpPromptPreview>>();
    });

    test('cancel supersedes the load in flight', () async {
      final session = DirectMcpContentLoadSession();
      final started = Completer<void>();
      final finish = Completer<DirectMcpResourcePreview>();

      final load = session.loadResource(
        (_, _, _) {
          started.complete();
          return finish.future;
        },
        _server,
        _resource,
      );
      await started.future;
      session.cancel();
      finish.complete(const DirectMcpResourcePreview(text: 'late'));

      check(await load)
          .isA<DirectMcpLoadSuperseded<DirectMcpResourcePreview>>();
    });

    test('an error after cancelling is not a failure', () async {
      final session = DirectMcpContentLoadSession();
      final started = Completer<void>();
      final finish = Completer<DirectMcpResourcePreview>();

      final load = session.loadResource(
        (_, _, _) {
          started.complete();
          return finish.future;
        },
        _server,
        _resource,
      );
      await started.future;
      session.dispose();
      finish.completeError(StateError('connection closed'));

      check(await load)
          .isA<DirectMcpLoadSuperseded<DirectMcpResourcePreview>>();
    });
  });

  group('content search', () {
    final prompts = [
      _prompt,
      DirectMcpPromptSummary(
        name: 'translate',
        displayName: 'Translate text',
        description: 'Into French',
        arguments: const [],
        inventoryIdentity: 'p2',
      ),
    ];

    test('an empty query keeps every prompt', () {
      check(filterDirectMcpPrompts(prompts, '  ')).length.equals(2);
    });

    test('matches the name, display name or description in any case', () {
      check(filterDirectMcpPrompts(prompts, 'CONDENSE').map((p) => p.name))
          .deepEquals(['summarize']);
      check(filterDirectMcpPrompts(prompts, ' translate ').map((p) => p.name))
          .deepEquals(['translate']);
      check(filterDirectMcpPrompts(prompts, 'zzz')).isEmpty();
    });

    test('resources match their URI too', () {
      check(filterDirectMcpResources(const [_resource], 'notes.md')).length
          .equals(1);
      check(filterDirectMcpResources(const [_resource], 'team')).length
          .equals(1);
      check(filterDirectMcpResources(const [_resource], 'nope')).isEmpty();
    });
  });

  group('size limits', () {
    test('an insertion is limited in bytes, not characters', () {
      check(directMcpInsertionTooLarge('a' * kDirectMcpMaxInsertionBytes))
          .isFalse();
      check(directMcpInsertionTooLarge('a' * (kDirectMcpMaxInsertionBytes + 1)))
          .isTrue();
      // Each of these is three bytes in UTF-8.
      check(
        directMcpInsertionTooLarge(
          'あ' * (kDirectMcpMaxInsertionBytes ~/ 3 + 1),
        ),
      ).isTrue();
    });

    test('a prompt argument is limited in bytes', () {
      check(
        directMcpArgumentValueTooLarge(
          'a' * kDirectMcpMaxPromptArgumentValueBytes,
        ),
      ).isFalse();
      check(
        directMcpArgumentValueTooLarge(
          'a' * (kDirectMcpMaxPromptArgumentValueBytes + 1),
        ),
      ).isTrue();
    });
  });
}
