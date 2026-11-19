@TestOn('vm')
library;

import 'package:checks/checks.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart'
    show selectedTerminalIdProvider;
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        apiServiceProvider,
        loadConversationProvider,
        openWebUiAuthSessionEpochProvider;
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The terminal a chat's tools run on is the one the account selected
/// (`terminal.select`) when the turn goes out, whichever way it goes out:
/// typed, a queued batch, words in a call. Every send reads it from the
/// chat's scope, so the scope follows the account's selection.
void main() {
  test("a chat's scope takes the terminal the account selects, as it is "
      'selected', () async {
    final epoch = Object();
    final now = DateTime.utc(2026, 11, 2);
    final container = ProviderContainer(
      overrides: [
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        apiServiceProvider.overrideWith((ref) => null),
        loadConversationProvider.overrideWith(
          (ref, id) async => Conversation(
            id: id,
            title: 'Harbour logs',
            createdAt: now,
            updatedAt: now,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final turns = TurnsService(container, EventBus());
    addTearDown(turns.dispose);
    container.read(selectedTerminalIdProvider.notifier).set('box-a');

    // A chat a window holds open: its queue and its calls send from here
    // without a typed send choosing anything first.
    final scope = await turns.holdScope('chat-harbour');
    addTearDown(() => turns.releaseScope('chat-harbour'));
    check(scope.read(selectedTerminalIdProvider)).equals('box-a');

    container.read(selectedTerminalIdProvider.notifier).set('box-b');
    check(
      because: 'a queued or voice turn would still run on the last terminal',
      scope.read(selectedTerminalIdProvider),
    ).equals('box-b');

    container.read(selectedTerminalIdProvider.notifier).clear();
    check(scope.read(selectedTerminalIdProvider)).isNull();
  });
}
