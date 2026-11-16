@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/features/librechat/models/librechat_capabilities.dart';
import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/providers/librechat_providers.dart';
import 'package:conduit_core/features/librechat/services/librechat_api_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_auth_service.dart';
import 'package:conduit_core/features/librechat/services/librechat_http_client.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_handle.dart';
import 'package:conduit_core/features/librechat/services/librechat_session_store.dart';
import 'package:conduit_core/testing.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

/// The daemon's LibreChat service against the core's fake LibreChat server
/// (an in-process Dio adapter): no network.
void main() {
  const server = LibreChatServer(baseUrl: 'https://chat.example.com');

  test(
    "a memory write begun for one LibreChat account is not the next one's",
    () async {
      final fake = FakeLibreChatServer()
        ..addUser(email: 'avery@example.com', password: 'pw-avery')
        ..addUser(email: 'blake@example.com', password: 'pw-blake');
      final asked = Completer<void>();
      final release = Completer<void>();
      final created = <String>[];
      // The first account's memories are read slowly: another account signs
      // in meanwhile.
      fake
        ..on('GET', '/api/memories', (request, _) async {
          if (fake.userFor(request)?.email == 'avery@example.com' &&
              !release.isCompleted) {
            if (!asked.isCompleted) asked.complete();
            await release.future;
          }
          return FakeLibreChatResponse.json({
            'memories': <Object?>[],
            'totalTokens': 0,
            'tokenLimit': 1000,
            'usagePercentage': 0,
          });
        })
        ..on('POST', '/api/memories', (request, _) {
          created.add(fake.userFor(request)!.email);
          return FakeLibreChatResponse.json({'created': true});
        });
      Future<LibreChatApiService> apiFor(String email, String password) async {
        final auth = LibreChatAuthService(server, adapter: fake);
        addTearDown(auth.close);
        final signedIn = await auth.signIn(
          email: email,
          password: password,
        ) as LibreChatSignedIn;
        final client = LibreChatHttpClient(
          server: server,
          adapter: fake,
          session: LibreChatSessionHandle(
            session: signedIn.session,
            store: InMemoryLibreChatSessionStore(),
            renew: auth.renew,
          ),
        );
        addTearDown(client.close);
        return LibreChatApiService(client);
      }

      final avery = await apiFor('avery@example.com', 'pw-avery');
      final blake = await apiFor('blake@example.com', 'pw-blake');
      var current = avery;
      final container = ProviderContainer(
        overrides: [
          libreChatApiServiceProvider.overrideWith((ref) => current),
          libreChatCapabilitiesProvider.overrideWith(
            (ref) async => LibreChatCapabilities.minimal,
          ),
        ],
        retry: (_, _) => null,
      );
      addTearDown(container.dispose);
      final service = LibreChatService(
        container,
        events: EventBus(),
        accounts: AccountsService(container, events: EventBus()),
      );

      final saving = service.saveMemory(
        const LibreChatMemoryEdit(key: 'trail_notes', value: 'Ridge loop'),
      );
      await asked.future;
      current = blake;
      container.invalidate(libreChatApiServiceProvider);
      release.complete();
      await expectLater(
        saving,
        throwsA(
          isA<RpcError>().having(
            (e) => e.code,
            'code',
            ConduitErrorCodes.sessionExpired,
          ),
        ),
      );
      expect(created, isEmpty, reason: 'the memory was saved for an account');
    },
  );
}
