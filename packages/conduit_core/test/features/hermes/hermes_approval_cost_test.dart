import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_approval_cost.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:test/test.dart';

// Sentences as Hermes v0.23.0 writes them (`tools/mcp_tool_costs.py`,
// `tools/mcp_tool_handlers.py`), rendered from its own code.
const _gatedOverLimit =
    "MCP tool 'render' on UNTRUSTED server 'mesh-studio' wants to run. "
    "This call goes past the chat's spend limit. Costs about 5 credits. "
    "This chat has used about 48 credits on 'mesh-studio' (limit 50). "
    'This tool is write-capable (no readOnlyHint=true annotation) and may '
    'modify external state.\n\nArguments:\n  prompt: a teal lighthouse';

const _limitOnly =
    "MCP tool 'render' on server 'mesh-studio' would take this chat past "
    'its spend limit. Costs about 5 credits. This chat has used about 48 '
    "credits on 'mesh-studio' (limit 50).";

void main() {
  group('approval costs', () {
    test('read the price, spend and limit of a gated call', () {
      final cost = parseHermesApprovalCost([_gatedOverLimit])!;

      check(cost.cost).equals('5 credits');
      check(cost.approximate).isTrue();
      check(cost.spent).equals('48 credits');
      check(cost.limit).equals('50');
      check(cost.server).equals('mesh-studio');
      check(cost.overLimit).isTrue();
      // Everything else stays as Hermes wrote it.
      check(cost.remainder).equals(
        "MCP tool 'render' on UNTRUSTED server 'mesh-studio' wants to run. "
        'This tool is write-capable (no readOnlyHint=true annotation) and '
        'may modify external state.\n\nArguments:\n  prompt: a teal '
        'lighthouse',
      );
    });

    test('read a spend-limit approval of a trusted server', () {
      final cost = parseHermesApprovalCost([_limitOnly])!;

      check(cost.overLimit).isTrue();
      check(cost.cost).equals('5 credits');
      check(cost.remainder).isEmpty();
    });

    test('read ranges, notes, one unit and a fresh limit', () {
      final range = parseHermesApprovalCost([
        "Costs 2-1,250.5 credits (per image). This chat has used about 1 "
        "credit on 'mesh-studio'.",
      ])!;
      check(range.cost).equals('2–1,250.5 credits');
      check(range.approximate).isFalse();
      check(range.note).equals('per image');
      check(range.spent).equals('1 credit');
      check(range.limit).isNull();
      check(range.overLimit).isFalse();

      final fresh = parseHermesApprovalCost([
        "Costs about 1 credit. Spend limit for this chat on 'mesh-studio': "
        '50 credits.',
      ])!;
      check(fresh.cost).equals('1 credit');
      check(fresh.spent).isNull();
      check(fresh.limit).equals('50 credits');
      check(fresh.server).equals('mesh-studio');
    });

    test('leave other approvals alone', () {
      check(parseHermesApprovalCost(['rm -rf build'])).isNull();
      check(parseHermesApprovalCost([null, ''])).isNull();
      // Words that merely resemble the sentences are not a price.
      check(
        parseHermesApprovalCost(['echo "Costs about five credits."']),
      ).isNull();
    });

    test('take the first text that states a price', () {
      final cost = parseHermesApprovalCost([
        "Server 'mesh-studio' is configured 'trust: untrusted'.",
        _gatedOverLimit,
      ])!;
      check(cost.spent).equals('48 credits');
    });

    test('round-trip what a card keeps', () {
      final cost = parseHermesApprovalCost([_gatedOverLimit])!;
      final kept = HermesApprovalCost.fromJson(cost.toJson())!;

      check(kept.toJson()).deepEquals(cost.toJson());
      check(HermesApprovalCost.fromJson({'cost': 7})).isNull();
      check(HermesApprovalCost.fromJson('cost')).isNull();
    });
  });

  test('a REST approval keeps the price its command states', () {
    final message = applyHermesRunEventForTest(
      ChatMessage(
        id: 'a',
        role: 'assistant',
        content: '',
        timestamp: DateTime.utc(2030),
      ),
      const HermesApprovalRequested(
        approvalId: 'prm_a1',
        summary: "Server 'mesh-studio' is configured 'trust: untrusted'.",
        choices: ['once', 'deny'],
        executionGeneration: 2,
        raw: {'command': _gatedOverLimit},
      ),
      runId: 'run-1',
    );

    final approval = message.metadata![kHermesApprovalMeta] as Map;
    check(approval['summary'])
        .equals("Server 'mesh-studio' is configured 'trust: untrusted'.");
    final cost = HermesApprovalCost.fromJson(approval['cost'])!;
    check(cost.cost).equals('5 credits');
    check(cost.overLimit).isTrue();
  });
}
