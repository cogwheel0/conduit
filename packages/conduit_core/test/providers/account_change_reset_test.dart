import 'package:checks/checks.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/account_change_reset.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

final class _Picked extends SelectedModel {
  @override
  Model? build() => null;
}

final class _Open extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

Conversation _chat(String id, ChatStorageKind storage) =>
    withChatStorageProvenance(
      Conversation(
        id: id,
        title: 'Sample chat',
        createdAt: DateTime.utc(2026, 11, 1),
        updatedAt: DateTime.utc(2026, 11, 1),
      ),
      storage,
    );

void main() {
  ProviderContainer container() {
    final container = ProviderContainer(
      overrides: [
        selectedModelProvider.overrideWith(_Picked.new),
        activeConversationProvider.overrideWith(_Open.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('an account change drops what names the account and keeps an open '
      'on-device chat', () {
    final c = container();
    final onDevice = _chat('direct-local:sample', ChatStorageKind.directLocal);
    c.read(activeConversationProvider.notifier).set(onDevice);
    c.read(pendingFolderIdProvider.notifier).set('folder-1');
    c.read(isLoadingConversationProvider.notifier).set(true);
    c.read(selectedModelProvider.notifier).set(const Model(id: 'm', name: 'M'));

    resetOpenWebUiAccountState(c, keepLocalModel: true);

    check(c.read(activeConversationProvider)).equals(onDevice);
    check(c.read(pendingFolderIdProvider)).isNull();
    check(c.read(isLoadingConversationProvider)).isFalse();
    check(c.read(selectedModelProvider)).isNull();
  });

  test('an account change closes an open Open WebUI chat', () {
    final c = container();
    c
        .read(activeConversationProvider.notifier)
        .set(_chat('server-chat', ChatStorageKind.openWebUi));

    resetOpenWebUiAccountState(c, keepLocalModel: true);

    check(c.read(activeConversationProvider)).isNull();
  });

  test('a Hermes model survives only when the host keeps local models', () {
    for (final keep in <bool>[true, false]) {
      final c = container();
      final hermes = hermesSyntheticModel();
      c.read(selectedModelProvider.notifier).set(hermes);

      resetOpenWebUiAccountState(c, keepLocalModel: keep);

      check(c.read(selectedModelProvider)).equals(keep ? hermes : null);
    }
  });
}
