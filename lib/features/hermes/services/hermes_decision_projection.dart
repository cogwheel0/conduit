import 'package:uuid/uuid.dart';

import '../../../core/models/chat_message.dart';
import 'hermes_pending_decision_store.dart';
import 'hermes_run_transport.dart';

List<ChatMessage> hermesPendingDesktopDecisionMessages(
  List<HermesPendingDesktopDecision> pending, {
  required String modelId,
}) {
  const uuid = Uuid();
  return <ChatMessage>[
    for (final record in pending)
      ChatMessage(
        id: uuid.v4(),
        role: 'assistant',
        content: '',
        timestamp: DateTime.now(),
        model: modelId,
        metadata: <String, dynamic>{
          'transport': kHermesTransport,
          'hermesSessionId': record.storedSessionId,
          'restoredDesktopDecision': true,
          if (record.kind == HermesPendingDesktopDecisionKind.approval)
            kHermesApprovalMeta: <String, dynamic>{
              'state': 'pending',
              'approvalId': record.requestId,
              'runId': record.runtimeId,
              'storedSessionId': record.storedSessionId,
              'summary': ?record.prompt,
              if (record.choices.isNotEmpty) 'choices': record.choices,
            }
          else
            kHermesDecisionMeta: <String, dynamic>{
              'state': 'pending',
              'kind': record.decisionKind!.name,
              'requestId': record.requestId,
              'runtimeId': record.runtimeId,
              'storedSessionId': record.storedSessionId,
              'prompt': ?record.prompt,
              'mcpServer': ?record.mcpServer,
              'mcpAction': ?record.mcpAction,
              if (record.choices.isNotEmpty) 'choices': record.choices,
              if (record.multiSelect) 'multiSelect': true,
              'expiresAt': record.expiresAt.toIso8601String(),
            },
        },
      ),
  ];
}
