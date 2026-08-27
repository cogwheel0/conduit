import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/core/services/secure_credential_storage.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_client.dart';
import 'package:conduit/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit/features/direct_connections/widgets/direct_mcp_message_interactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = (
    ownerConversationId: 'direct-local:chat',
    assistantMessageId: 'assistant',
  );
  final server = DirectMcpServer(
    id: 'home',
    name: 'Home server',
    endpoint: 'https://home.example/mcp',
  );
  final definition = DirectToolDefinition(
    name: 'mcp_deadbeef_lookup',
    serverId: 'home',
    serverName: 'Home server',
    remoteName: 'lookup',
    displayName: 'Lookup',
    description: '',
    approvalFingerprint: 'a' * 64,
    inputSchema: const <String, dynamic>{'type': 'object'},
  );

  test(
    'fingerprint canonicalizes maps but binds ordered schema and identity',
    () {
      final first = directMcpApprovalFingerprint(
        serverId: 'home',
        serverEndpoint: 'https://example.test/mcp',
        remoteToolName: 'lookup',
        inputSchema: const {
          'required': ['city', 'unit'],
          'type': 'object',
        },
      );
      expect(
        directMcpApprovalFingerprint(
          serverId: 'home',
          serverEndpoint: 'https://example.test/other-mcp',
          remoteToolName: 'lookup',
          inputSchema: const {
            'required': ['city', 'unit'],
            'type': 'object',
          },
        ),
        isNot(first),
      );
      expect(
        directMcpApprovalFingerprint(
          serverId: 'home',
          serverEndpoint: 'https://example.test/mcp',
          remoteToolName: 'lookup',
          inputSchema: const {
            'type': 'object',
            'required': ['city', 'unit'],
          },
        ),
        first,
      );
      for (final changed in [
        (
          serverId: 'home',
          origin: 'https://example.test:443',
          tool: 'lookup',
          required: ['unit', 'city'],
        ),
        (
          serverId: 'other',
          origin: 'https://example.test:443',
          tool: 'lookup',
          required: ['city', 'unit'],
        ),
        (
          serverId: 'home',
          origin: 'https://other.test:443',
          tool: 'lookup',
          required: ['city', 'unit'],
        ),
        (
          serverId: 'home',
          origin: 'https://example.test:443',
          tool: 'other',
          required: ['city', 'unit'],
        ),
      ]) {
        expect(
          directMcpApprovalFingerprint(
            serverId: changed.serverId,
            serverEndpoint: changed.origin,
            remoteToolName: changed.tool,
            inputSchema: {'type': 'object', 'required': changed.required},
          ),
          isNot(first),
        );
      }
    },
  );

  test('fingerprint rejects unsafe schema values and complexity', () {
    String fingerprint(Map<String, dynamic> schema) =>
        directMcpApprovalFingerprint(
          serverId: 'home',
          serverEndpoint: 'https://example.test/mcp',
          remoteToolName: 'lookup',
          inputSchema: schema,
        );

    expect(() => fingerprint({'value': double.nan}), throwsFormatException);
    Object nested = 'leaf';
    for (
      var index = 0;
      index <= kDirectMcpApprovalFingerprintMaxDepth;
      index++
    ) {
      nested = [nested];
    }
    expect(() => fingerprint({'value': nested}), throwsFormatException);
    expect(
      () => fingerprint({
        'values': List.filled(kDirectMcpApprovalFingerprintMaxNodes, null),
      }),
      throwsFormatException,
    );
  });

  test(
    'approval is owned by one exact reservation and resolves once',
    () async {
      final registry = DirectRunRegistry();
      final reservation = registry.reserve(key, 'profile');
      final handle = registry.requestMcpApproval(
        reservation,
        callId: 'call-1',
        definition: definition,
        arguments: const {'query': 'weather'},
        expectedServer: server,
      );

      expect(
        registry.resolveMcpApproval(
          key: key,
          approvalId: handle.request.id,
          decision: DirectToolApprovalDecision.allowOnce,
        ),
        isTrue,
      );
      expect(await handle.decision, DirectToolApprovalDecision.allowOnce);
      expect(
        registry.resolveMcpApproval(
          key: key,
          approvalId: handle.request.id,
          decision: DirectToolApprovalDecision.deny,
        ),
        isFalse,
      );
    },
  );

  test('replacement and profile cancellation deny pending approvals', () async {
    final registry = DirectRunRegistry();
    final replaced = registry.reserve(key, 'profile');
    final first = registry.requestMcpApproval(
      replaced,
      callId: 'call-1',
      definition: definition,
      arguments: const {},
      expectedServer: server,
    );
    registry.reserve(key, 'profile');
    expect(await first.decision, DirectToolApprovalDecision.deny);
    expect(
      registry.resolveMcpApprovalById(
        first.request.id,
        DirectToolApprovalDecision.allowOnce,
      ),
      isFalse,
    );

    final otherKey = (
      ownerConversationId: 'direct-local:other',
      assistantMessageId: 'assistant-2',
    );
    final pending = registry.reserve(otherKey, 'profile');
    final second = registry.requestMcpApproval(
      pending,
      callId: 'call-2',
      definition: definition,
      arguments: const {},
      expectedServer: server,
    );
    registry.cancelProfile('profile');
    expect(await second.decision, DirectToolApprovalDecision.deny);
  });

  test('stop and sign-out deny pending approvals', () async {
    final registry = DirectRunRegistry();
    final stopped = registry.reserve(key, 'profile');
    final stoppedApproval = registry.requestMcpApproval(
      stopped,
      callId: 'call-stop',
      definition: definition,
      arguments: const {},
      expectedServer: server,
    );
    await registry.cancel(key);
    expect(await stoppedApproval.decision, DirectToolApprovalDecision.deny);
    expect(
      registry.resolveMcpApprovalById(
        stoppedApproval.request.id,
        DirectToolApprovalDecision.allowOnce,
      ),
      isFalse,
    );

    final otherKey = (
      ownerConversationId: 'direct-local:other',
      assistantMessageId: 'assistant-2',
    );
    final signedOut = registry.reserve(otherKey, 'profile');
    final signedOutApproval = registry.requestMcpApproval(
      signedOut,
      callId: 'call-sign-out',
      definition: definition,
      arguments: const {},
      expectedServer: server,
    );
    await Future.wait(registry.cancelAll());
    expect(await signedOutApproval.decision, DirectToolApprovalDecision.deny);
    expect(
      registry.resolveMcpApprovalById(
        signedOutApproval.request.id,
        DirectToolApprovalDecision.allowOnce,
      ),
      isFalse,
    );
  });

  test('approval display arguments are bounded', () {
    final registry = DirectRunRegistry();
    final reservation = registry.reserve(key, 'profile');
    final handle = registry.requestMcpApproval(
      reservation,
      callId: 'call-1',
      definition: definition,
      arguments: {
        'value': List.filled(
          kMaxDirectMcpApprovalArgumentCharacters * 2,
          'x',
        ).join(),
      },
      expectedServer: server,
    );

    expect(
      handle.request.argumentsJson.length,
      lessThanOrEqualTo(kMaxDirectMcpApprovalArgumentCharacters),
    );
    expect(handle.request.argumentsJson, endsWith('[truncated]'));
  });

  test(
    'session approval is reused across chats and cleared on change',
    () async {
      final registry = DirectRunRegistry()..synchronizeMcpServers([server]);
      final first = registry.requestMcpApproval(
        registry.reserve(key, 'profile'),
        callId: 'call-1',
        definition: definition,
        arguments: const {'secret': 'one'},
        expectedServer: server,
      );
      expect(
        registry.resolveMcpApprovalById(
          first.request.id,
          DirectToolApprovalDecision.allowSession,
        ),
        isTrue,
      );
      expect(await first.decision, DirectToolApprovalDecision.allowSession);
      await Future.wait(registry.cancelAll());

      final second = registry.requestMcpApproval(
        registry.reserve((
          ownerConversationId: 'direct-local:second',
          assistantMessageId: 'assistant-2',
        ), 'profile'),
        callId: 'call-2',
        definition: definition,
        arguments: const {'secret': 'two'},
        expectedServer: server,
      );
      expect(second.requiresUserDecision, isFalse);
      expect(second.request.argumentsJson, '{}');
      expect(await second.decision, DirectToolApprovalDecision.allowSession);

      registry.synchronizeMcpServers([server.copyWith(name: 'Changed')]);
      final third = registry.requestMcpApproval(
        registry.reserve((
          ownerConversationId: 'direct-local:third',
          assistantMessageId: 'assistant-3',
        ), 'profile'),
        callId: 'call-3',
        definition: definition,
        arguments: const {},
        expectedServer: server.copyWith(name: 'Changed'),
      );
      expect(third.requiresUserDecision, isTrue);
      expect(
        registry.resolveMcpApprovalById(
          third.request.id,
          DirectToolApprovalDecision.allowSession,
        ),
        isTrue,
      );
      registry.blockAdmissionForAppDataClear();
      await Future.wait(registry.cancelAll());
      registry.resumeAdmissionAfterAppDataClearAbort();
      final changedServer = server.copyWith(name: 'Changed');
      registry.synchronizeMcpServers([changedServer]);
      final afterSignOut = registry.requestMcpApproval(
        registry.reserve((
          ownerConversationId: 'direct-local:fourth',
          assistantMessageId: 'assistant-4',
        ), 'profile'),
        callId: 'call-4',
        definition: definition,
        arguments: const {},
        expectedServer: changedServer,
      );
      expect(afterSignOut.requiresUserDecision, isTrue);
    },
  );

  test('fingerprint-backed remembered approval omits call arguments', () async {
    final remembered = server.copyWith(
      rememberedApprovals: [
        DirectMcpRememberedApproval(
          digest: definition.approvalFingerprint,
          remoteToolName: definition.remoteName,
          displayName: definition.displayName,
          createdAt: DateTime.utc(2026),
        ),
      ],
    );
    final registry = DirectRunRegistry()..synchronizeMcpServers([remembered]);
    final handle = registry.requestMcpApproval(
      registry.reserve(key, 'profile'),
      callId: 'call-1',
      definition: definition,
      arguments: const {'private': 'argument'},
      expectedServer: remembered,
    );

    expect(handle.requiresUserDecision, isFalse);
    expect(handle.request.argumentsJson, '{}');
    expect(await handle.decision, DirectToolApprovalDecision.allowAlways);
  });

  test(
    'always approval settles only after a successful secure write',
    () async {
      final registry = DirectRunRegistry()..synchronizeMcpServers([server]);
      final handle = registry.requestMcpApproval(
        registry.reserve(key, 'profile'),
        callId: 'call-1',
        definition: definition,
        arguments: const {},
        expectedServer: server,
      );

      await expectLater(
        registry.resolveMcpApprovalAlwaysById(
          handle.request.id,
          (_, _) => Future.error(StateError('write failed')),
        ),
        throwsStateError,
      );
      expect(registry.hasLiveMcpApproval(handle.request.id), isTrue);
      await expectLater(
        registry.resolveMcpApprovalAlwaysById(
          handle.request.id,
          (expected, _) async => [expected],
        ),
        throwsStateError,
      );
      expect(registry.hasLiveMcpApproval(handle.request.id), isTrue);

      expect(
        await registry.resolveMcpApprovalAlwaysById(
          handle.request.id,
          (expected, approval) async => [
            expected.copyWith(rememberedApprovals: [approval]),
          ],
        ),
        isTrue,
      );
      expect(await handle.decision, DirectToolApprovalDecision.allowAlways);
    },
  );

  testWidgets('live approval can be denied and restored approval expires', (
    tester,
  ) async {
    final registry = DirectRunRegistry();
    final reservation = registry.reserve(key, 'profile');
    final handle = registry.requestMcpApproval(
      reservation,
      callId: 'call-1',
      definition: definition,
      arguments: const {'query': 'weather'},
      expectedServer: server,
    );
    final message = ChatMessage(
      id: key.assistantMessageId,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        kDirectMcpApprovalMetadataKey: handle.request.toMetadata('pending'),
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [directRunRegistryProvider.overrideWithValue(registry)],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DirectMcpMessageInteractions(message: message)),
        ),
      ),
    );
    expect(find.text('Home server · Lookup'), findsOneWidget);
    expect(find.text('Allow once'), findsOneWidget);
    expect(find.text('Allow for session'), findsOneWidget);
    expect(find.text('Always allow'), findsOneWidget);
    expect(find.text('Deny'), findsOneWidget);
    await tester.tap(find.text('Always allow'));
    await tester.pumpAndSettle();
    expect(find.text('Always allow this tool?'), findsOneWidget);
    expect(find.textContaining('Home server'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(registry.hasLiveMcpApproval(handle.request.id), isTrue);
    await tester.tap(find.text('Deny'));
    expect(await handle.decision, DirectToolApprovalDecision.deny);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DirectMcpMessageInteractions(message: message)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Approval expired'), findsOneWidget);
    expect(find.text('Allow once'), findsNothing);
  });

  testWidgets('failed always write stays pending with a safe error', (
    tester,
  ) async {
    final registry = DirectRunRegistry()..synchronizeMcpServers([server]);
    final handle = registry.requestMcpApproval(
      registry.reserve(key, 'profile'),
      callId: 'call-1',
      definition: definition,
      arguments: const {},
      expectedServer: server,
    );
    final message = ChatMessage(
      id: key.assistantMessageId,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        kDirectMcpApprovalMetadataKey: handle.request.toMetadata('pending'),
      },
    );
    final store = DirectMcpServerStore(
      SecureCredentialStorage(
        instance: _FailingMcpSecureStorage(
          DirectMcpServersDocument([server]).encode(),
        ),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          directRunRegistryProvider.overrideWithValue(registry),
          directMcpServerStoreProvider.overrideWithValue(store),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DirectMcpMessageInteractions(message: message)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always allow'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Always allow').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not remember this approval. You can retry or choose another option.',
      ),
      findsOneWidget,
    );
    expect(registry.hasLiveMcpApproval(handle.request.id), isTrue);
    expect(find.text('Allow once'), findsOneWidget);
  });
}

final class _FailingMcpSecureStorage implements FlutterSecureStorage {
  _FailingMcpSecureStorage(this.source);

  final String source;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(source);
    if (invocation.memberName == #write) {
      return Future<void>.error(StateError('write failed'));
    }
    return super.noSuchMethod(invocation);
  }
}
