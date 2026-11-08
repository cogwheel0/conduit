import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart'
    show settleNativeAccountsDetail;
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// LibreChat accounts saved beside Open WebUI's.
final class _SavedLibreChat extends LibreChatRegistryController {
  _SavedLibreChat(this.accounts);

  final List<LibreChatAccount> accounts;

  @override
  Future<LibreChatRegistry> build() async =>
      LibreChatRegistry(accounts: accounts, activeId: accounts.first.id);
}

/// A session still being read out of secure storage.
final class _SlowSession extends LibreChatSessionController {
  _SlowSession(this.answer);

  final Completer<LibreChatSessionState> answer;

  @override
  Future<LibreChatSessionState> build() => answer.future;
}

/// The native Accounts page shows the LibreChat account in charge as in
/// use, or signed out with its sign-in a tap away.
void main() {
  test('the session in charge is read before the page is', () async {
    final account = LibreChatAccount.forUser(
      const LibreChatServer(baseUrl: 'https://chat.example.com'),
      const LibreChatUser(id: 'u1', name: 'Dev'),
    );
    final answer = Completer<LibreChatSessionState>();
    final container = ProviderContainer(
      overrides: [
        primaryAccountKindProvider.overrideWithValue(
          PrimaryAccountKind.libreChat,
        ),
        libreChatRegistryProvider.overrideWith(
          () => _SavedLibreChat([account]),
        ),
        libreChatSessionProvider.overrideWith(() => _SlowSession(answer)),
      ],
    );
    addTearDown(container.dispose);

    var settled = false;
    final settling = settleNativeAccountsDetail(
      container.read,
    ).then((_) => settled = true);
    await pumpEventQueue();
    // Still loading, it is neither signed in nor out: a page built now
    // would show it in use, with no way to sign in.
    check(settled).isFalse();

    answer.complete(LibreChatNeedsSignIn(account));
    await settling;
    check(
      container.read(libreChatSessionProvider).value,
    ).isA<LibreChatNeedsSignIn>();
  });
}
