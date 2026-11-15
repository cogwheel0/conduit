@TestOn('vm')
library;

import 'dart:async';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/sharing/providers/principal_lookup.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_common.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:conduitd/conduitd.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

const _server = ServerConfig(
  id: 'server',
  name: 'Home server',
  url: 'https://home.invalid',
);

const _ava = User(
  id: 'user-1',
  username: 'ava',
  email: 'ava@example.com',
  name: 'Ava',
  role: 'user',
);

/// `access.*` over one signed-in account whose server answers from memory.
void main() {
  late _Api api;
  late Object epoch;
  late ResourceSharingCapabilities chats;

  setUp(() {
    api = _Api();
    epoch = Object();
    chats = ResourceSharingCapabilities.none;
  });
  tearDown(() => api.dispose());

  ProviderContainer containerWith({WorkspacePrincipalLookup? lookup}) {
    final container = ProviderContainer(
      overrides: [
        apiServiceProvider.overrideWith((ref) => api),
        currentUserProvider2.overrideWith((ref) => _ava),
        isAuthenticatedProvider2.overrideWithValue(true),
        activeServerProvider.overrideWith((ref) async => _server),
        openWebUiAuthSessionEpochProvider.overrideWith((ref) => epoch),
        workspaceCapabilitiesProvider.overrideWith(
          (ref) async => WorkspaceCapabilities(chats: chats),
        ),
        workspacePrincipalLookupProvider.overrideWithValue(lookup),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Matcher refused(String code) =>
      throwsA(isA<RpcError>().having((e) => e.code, 'code', code));

  group('access.set keeps to what the account may give', () {
    const sharer = ResourceSharingCapabilities(
      section: WorkspaceSectionCapabilities(share: true),
      allowGroupGrants: true,
    );

    test('no new person when grants to people are off', () async {
      chats = sharer;
      api.grants = <Map<String, dynamic>>[
        {
          'principal_type': 'user',
          'principal_id': 'kept',
          'permission': 'read',
        },
      ];
      final access = AccessService(containerWith());
      await expectLater(
        access.set(
          const AccessEdit(
            kind: AccessResourceKind.chat,
            id: 'chat-1',
            grants: <AccessGrantDto>[
              AccessGrantDto(principalType: 'user', principalId: 'kept'),
              AccessGrantDto(principalType: 'user', principalId: 'new'),
            ],
          ),
        ),
        refused(ConduitErrorCodes.unauthorized),
      );
      expect(api.written, isEmpty);

      // The person already granted, and a group, are the account's to keep.
      await access.set(
        const AccessEdit(
          kind: AccessResourceKind.chat,
          id: 'chat-1',
          grants: <AccessGrantDto>[
            AccessGrantDto(principalType: 'user', principalId: 'kept'),
            AccessGrantDto(principalType: 'group', principalId: 'team'),
          ],
        ),
      );
      expect(api.written, hasLength(1));
    });

    test('no audience the account may not choose', () async {
      chats = sharer;
      final access = AccessService(containerWith());
      for (final audience in <AccessAudience>[
        AccessAudience.public,
        AccessAudience.open,
      ]) {
        await expectLater(
          access.set(
            AccessEdit(
              kind: AccessResourceKind.chat,
              id: 'chat-1',
              audience: audience,
            ),
          ),
          refused(ConduitErrorCodes.unauthorized),
          reason: '$audience',
        );
      }
      expect(api.written, isEmpty);
    });
  });

  test('grants named for one account are never shown to the next', () async {
    final named = Completer<WorkspacePrincipalPreview?>();
    final asked = Completer<void>();
    final container = containerWith(
      lookup: WorkspacePrincipalLookup(
        fetchUser: (id) {
          asked.complete();
          return named.future;
        },
        fetchGroups: () async => const <WorkspacePrincipalPreview>[],
      ),
    );
    api.grants = <Map<String, dynamic>>[
      {'principal_type': 'user', 'principal_id': 'kept', 'permission': 'read'},
    ];
    final reading = AccessService(
      container,
    ).get(const AccessRef(kind: AccessResourceKind.chat, id: 'chat-1'));
    await asked.future;
    // Another account signs in while the names are looked up.
    epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    named.complete(
      const WorkspacePrincipalPreview(
        id: 'kept',
        type: WorkspacePrincipalType.user,
        name: 'Kept Person',
        email: 'kept@example.com',
      ),
    );
    await expectLater(reading, refused(ConduitErrorCodes.sessionExpired));
  });

  test('people found for one account are never shown to the next', () async {
    final container = containerWith();
    final groups = Completer<List<WorkspacePrincipalPreview>>();
    api.groups = () => groups.future;
    final found = AccessService(container)
        .principals(const AccessPrincipalQuery(query: ''));
    epoch = Object();
    container.invalidate(openWebUiAuthSessionEpochProvider);
    groups.complete(const <WorkspacePrincipalPreview>[
      WorkspacePrincipalPreview(
        id: 'team',
        type: WorkspacePrincipalType.group,
        name: 'Team',
      ),
    ]);
    await expectLater(found, refused(ConduitErrorCodes.sessionExpired));
  });
}

/// The account's server, answered from memory.
final class _Api extends ApiService {
  _Api() : super(serverConfig: _server, workerManager: WorkerManager());

  var grants = <Map<String, dynamic>>[];
  final written = <List<Map<String, dynamic>>>[];
  Future<List<WorkspacePrincipalPreview>> Function() groups = () async =>
      const <WorkspacePrincipalPreview>[];

  @override
  Future<List<Map<String, dynamic>>> getChatAccessGrants(
    String originalChatId, {
    ApiAuthSnapshot? authSnapshot,
  }) async => grants;

  @override
  Future<void> updateChatAccessGrants(
    String originalChatId,
    List<Map<String, dynamic>> grants, {
    ApiAuthSnapshot? authSnapshot,
  }) async {
    written.add(grants);
    this.grants = grants;
  }

  @override
  Future<List<WorkspacePrincipalPreview>> getWorkspaceGroups({
    ApiAuthSnapshot? authSnapshot,
  }) => groups();
}
