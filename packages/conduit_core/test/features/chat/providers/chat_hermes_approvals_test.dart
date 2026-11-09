import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

ChatMessage _answer(Map<String, dynamic> metadata) => ChatMessage(
  id: 'answer',
  role: 'assistant',
  content: '',
  timestamp: DateTime.utc(2026, 11, 8),
  metadata: <String, dynamic>{'transport': kHermesTransport, ...metadata},
);

void main() {
  test('reads a pending approval with the choices Hermes offers', () {
    final approval = pendingHermesApprovalOf(
      _answer(<String, dynamic>{
        kHermesApprovalMeta: <String, dynamic>{
          'state': 'pending',
          'approvalId': 'approval-1',
          'runId': 'run-1',
          'summary': 'Clean the build folder',
          'choices': <String>['once', 'always', 'deny', 'everything'],
        },
      }),
    );

    expect(approval, isNotNull);
    expect(approval!.messageId, 'answer');
    expect(approval.approvalId, 'approval-1');
    expect(approval.runId, 'run-1');
    expect(approval.summary, 'Clean the build folder');
    // Only the answers Hermes defines.
    expect(approval.choices, <String>['once', 'always', 'deny']);
    expect(approval.restoredDesktopDecision, isFalse);
  });

  test('ignores an approval already being answered or answered', () {
    for (final state in <String>['resolving', 'approved', 'denied']) {
      expect(
        pendingHermesApprovalOf(
          _answer(<String, dynamic>{
            kHermesApprovalMeta: <String, dynamic>{
              'state': state,
              'approvalId': 'approval-1',
              'runId': 'run-1',
            },
          }),
        ),
        isNull,
        reason: state,
      );
    }
  });

  test('ignores answers that are not Hermes, or lack the ids to answer', () {
    expect(
      pendingHermesApprovalOf(
        ChatMessage(
          id: 'answer',
          role: 'assistant',
          content: '',
          timestamp: DateTime.utc(2026, 11, 8),
          metadata: const <String, dynamic>{
            kHermesApprovalMeta: <String, dynamic>{
              'approvalId': 'approval-1',
              'runId': 'run-1',
            },
          },
        ),
      ),
      isNull,
    );
    expect(
      pendingHermesApprovalOf(
        _answer(<String, dynamic>{
          kHermesApprovalMeta: <String, dynamic>{'runId': 'run-1'},
        }),
      ),
      isNull,
    );
    // A restored desktop approval is answered through its session, so one
    // without it cannot be answered at all.
    expect(
      pendingHermesApprovalOf(
        _answer(<String, dynamic>{
          'restoredDesktopDecision': true,
          kHermesApprovalMeta: <String, dynamic>{
            'approvalId': 'approval-1',
            'runId': 'run-1',
          },
        }),
      ),
      isNull,
    );
  });
}
