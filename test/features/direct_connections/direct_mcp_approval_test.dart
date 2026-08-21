import 'package:conduit/core/models/chat_message.dart';
import 'package:conduit/features/direct_connections/models/direct_completion.dart';
import 'package:conduit/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit/features/direct_connections/services/direct_run_registry.dart';
import 'package:conduit/features/direct_connections/widgets/direct_mcp_message_interactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const key = (
    ownerConversationId: 'direct-local:chat',
    assistantMessageId: 'assistant',
  );
  final definition = DirectToolDefinition(
    name: 'mcp_deadbeef_lookup',
    serverName: 'Home server',
    displayName: 'Lookup',
    description: '',
    inputSchema: const <String, dynamic>{'type': 'object'},
  );

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
    );

    expect(
      handle.request.argumentsJson.length,
      lessThanOrEqualTo(kMaxDirectMcpApprovalArgumentCharacters),
    );
    expect(handle.request.argumentsJson, endsWith('[truncated]'));
  });

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
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DirectMcpMessageInteractions(message: message)),
        ),
      ),
    );
    expect(find.text('Home server · Lookup'), findsOneWidget);
    await tester.tap(find.text('Deny'));
    expect(await handle.decision, DirectToolApprovalDecision.deny);

    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        child: MaterialApp(
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: DirectMcpMessageInteractions(message: message)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Approval expired'), findsOneWidget);
    expect(find.text('Allow once'), findsNothing);
  });
}
