import '../../../core/models/chat_message.dart';
import 'hermes_pending_decision_store.dart';
import 'hermes_run_transport.dart';

List<ChatMessage> hermesPendingDesktopDecisionMessages(
  List<HermesPendingDesktopDecision> pending, {
  required String modelId,
}) {
  return <ChatMessage>[
    for (final record in pending)
      ChatMessage(
        id: _decisionMessageId(record),
        role: 'assistant',
        content: '',
        timestamp: record.expiresAt.subtract(HermesPendingDecisionStore.ttl),
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

String _decisionMessageId(HermesPendingDesktopDecision record) =>
    'hermes-decision-${record.kind.name}-'
    '${record.origin.length}:${record.origin}'
    '${record.storedSessionId.length}:${record.storedSessionId}'
    '${record.requestId.length}:${record.requestId}';
