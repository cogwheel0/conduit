import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_hydration_service.dart'
    show readNativeOtherAccountCount;
import 'package:conduit_core/auth/openwebui_account_summaries.dart';
import 'package:conduit_core/features/librechat/models/librechat_account.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/models/openwebui_registry.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// LibreChat accounts saved beside Open WebUI's.
final class _SavedLibreChat extends LibreChatRegistryController {
  _SavedLibreChat(this.accounts);

  final List<LibreChatAccount> accounts;

  @override
  Future<LibreChatRegistry> build() async =>
      LibreChatRegistry(accounts: accounts);
}

/// LibreChat accounts still being read out of secure storage.
final class _UnreadLibreChat extends LibreChatRegistryController {
  @override
  Future<LibreChatRegistry> build() => Completer<LibreChatRegistry>().future;
}

/// The native Settings root offers to sign out of the active account alone
/// when there are others, and of every account otherwise.
void main() {
  OpenWebUiAccountEntry homeAccount() => OpenWebUiAccountEntry(
    account: OpenWebUiAccount(
      id: 'alex-home',
      serverId: 'home',
      userId: 'u-alex',
    ),
    server: OpenWebUiServer(
      id: 'home',
      name: 'Home',
      endpoints: [
        OpenWebUiEndpoint(id: 'home-lan', url: 'https://home.example.com'),
      ],
    ),
    summary: const OpenWebUiAccountSummary(name: 'Alex'),
    isActive: true,
    hasSession: true,
  );

  test('LibreChat accounts not read yet may be others', () async {
    final home = homeAccount();
    final container = ProviderContainer(
      overrides: [
        openWebUiAccountsProvider.overrideWith((ref) async => [home]),
        libreChatRegistryProvider.overrideWith(_UnreadLibreChat.new),
      ],
    );
    addTearDown(container.dispose);
    await container.read(openWebUiAccountsProvider.future);

    // Unknown, so the sign-out says it signs out of every account, rather
    // than passing for this one's alone.
    check(readNativeOtherAccountCount(container.read)).isNull();
  });

  test('saved LibreChat accounts count as other accounts', () async {
    final home = homeAccount();
    final container = ProviderContainer(
      overrides: [
        openWebUiAccountsProvider.overrideWith((ref) async => [home]),
        libreChatRegistryProvider.overrideWith(
          () => _SavedLibreChat([
            LibreChatAccount.forUser(
              const LibreChatServer(baseUrl: 'https://chat.example.com'),
              const LibreChatUser(id: 'u1', name: 'Dev'),
            ),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(openWebUiAccountsProvider.future);
    await container.read(libreChatRegistryProvider.future);

    // Signing out of every account would forget the LibreChat one, and its
    // chats, with this one.
    check(readNativeOtherAccountCount(container.read)).equals(1);
  });
}
