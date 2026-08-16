import 'package:checks/checks.dart';
import 'package:conduit/features/hermes/services/hermes_decision_projection.dart';
import 'package:conduit/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps restored decision message IDs stable', () {
    final pending = <HermesPendingDesktopDecision>[
      HermesPendingDesktopDecision(
        origin: 'https://hermes.example',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: 'request-1',
        kind: HermesPendingDesktopDecisionKind.clarification,
        expiresAt: DateTime.utc(2030),
      ),
    ];

    final first = hermesPendingDesktopDecisionMessages(
      pending,
      modelId: 'hermes',
    ).single;
    final second = hermesPendingDesktopDecisionMessages(
      pending,
      modelId: 'hermes',
    ).single;

    check(second.id).equals(first.id);
    check(second.timestamp).equals(first.timestamp);
  });

  test('keeps variable-length decision identity components distinct', () {
    final expiresAt = DateTime.utc(2030);
    final messages = hermesPendingDesktopDecisionMessages([
      HermesPendingDesktopDecision(
        origin: 'https://hermes.example',
        storedSessionId: 'a-b',
        runtimeId: 'runtime',
        requestId: 'c',
        kind: HermesPendingDesktopDecisionKind.clarification,
        expiresAt: expiresAt,
      ),
      HermesPendingDesktopDecision(
        origin: 'https://hermes.example',
        storedSessionId: 'a',
        runtimeId: 'runtime',
        requestId: 'b-c',
        kind: HermesPendingDesktopDecisionKind.clarification,
        expiresAt: expiresAt,
      ),
    ], modelId: 'hermes');

    check(messages.map((message) => message.id).toSet()).length.equals(2);
  });

  test('scopes restored decision IDs to the gateway origin', () {
    final expiresAt = DateTime.utc(2030);
    final messages = hermesPendingDesktopDecisionMessages([
      for (final origin in [
        'https://one.hermes.example',
        'https://two.hermes.example',
      ])
        HermesPendingDesktopDecision(
          origin: origin,
          storedSessionId: 'stored',
          runtimeId: 'runtime',
          requestId: 'request',
          kind: HermesPendingDesktopDecisionKind.clarification,
          expiresAt: expiresAt,
        ),
    ], modelId: 'hermes');

    check(messages.map((message) => message.id).toSet()).length.equals(2);
  });
}
