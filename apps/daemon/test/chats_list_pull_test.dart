@TestOn('vm')
library;

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/pull_sync.dart' show PullResult;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// A sync engine whose pulls fail while [reachable] is false, as they do
/// with the server out of reach.
final class _Engine extends SyncEngine {
  var reachable = false;
  var pulls = 0;

  @override
  SyncStatus build() => const SyncStatus();

  @override
  Future<PullResult?> requestPull({required String reason}) async {
    pulls++;
    state = SyncStatus(lastError: reachable ? null : 'pull failed');
    return null;
  }
}

final class _Conversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];
}

final class _Folders extends Folders {
  @override
  Future<List<Folder>> build() async => const <Folder>[];
}

void main() {
  late _Engine engine;
  late ProviderContainer container;
  late DateTime now;
  late ChatsService chats;

  setUp(() {
    engine = _Engine();
    container = ProviderContainer(
      overrides: [
        syncEngineProvider.overrideWith(() => engine),
        conversationsProvider.overrideWith(_Conversations.new),
        foldersProvider.overrideWith(_Folders.new),
        currentUserProvider2.overrideWithValue(null),
      ],
    );
    now = DateTime(2026, 11, 9, 12);
    chats = ChatsService(container, now: () => now);
  });

  tearDown(() => container.dispose());

  Future<void> list() async {
    await chats.list();
    // The pull runs in the background.
    await Future<void>.delayed(Duration.zero);
  }

  test('a list soon after a successful pull does not pull again', () async {
    engine.reachable = true;
    await list();
    now = now.add(const Duration(seconds: 5));
    await list();
    expect(engine.pulls, 1);

    now = now.add(const Duration(seconds: 30));
    await list();
    expect(engine.pulls, 2);
  });

  test('a list after a failed pull pulls again, so the server coming back '
      'is caught up at once', () async {
    // Launched with the server out of reach.
    await list();
    expect(engine.pulls, 1);

    // It is back; the window lists again a few seconds later.
    engine.reachable = true;
    now = now.add(const Duration(seconds: 5));
    await list();
    expect(engine.pulls, 2);

    // That one succeeded: the floor holds again.
    now = now.add(const Duration(seconds: 5));
    await list();
    expect(engine.pulls, 2);
  });
}
