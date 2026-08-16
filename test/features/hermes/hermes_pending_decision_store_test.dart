import 'package:checks/checks.dart';
import 'package:conduit/core/persistence/persistence_keys.dart';
import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await SharedPreferences.getInstance());
  });

  tearDown(PreferencesStore.debugReset);

  test('persists only bounded redacted prompt presentation', () async {
    await HermesPendingDecisionStore.upsert(
      origin: 'https://hermes.example:443',
      storedSessionId: 'stored-1',
      runtimeId: 'runtime-1',
      requestId: 'request-1',
      kind: HermesPendingDesktopDecisionKind.secret,
      prompt: 'Authorization: top-secret please provide value',
      sensitiveValues: const <String>['top-secret'],
    );

    final records = await HermesPendingDecisionStore.forSession(
      origin: 'https://hermes.example:443',
      storedSessionId: 'stored-1',
    );
    check(records).length.equals(1);
    check(records.single.prompt ?? '').not((it) => it.contains('top-secret'));
    final stored = PreferencesStore.getStringList(
      PreferenceKeys.hermesPendingDesktopDecisions,
    )!.single;
    check(stored).not((it) => it.contains('top-secret'));
    check(stored).not((it) => it.contains('answer'));
  });

  test('resolution and origin cleanup remove only matching records', () async {
    for (final request in const <String>['request-1', 'request-2']) {
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example:443',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-1',
        requestId: request,
        kind: HermesPendingDesktopDecisionKind.clarification,
      );
    }
    await HermesPendingDecisionStore.upsert(
      origin: 'https://other.example:443',
      storedSessionId: 'stored-2',
      runtimeId: 'runtime-2',
      requestId: 'request-3',
      kind: HermesPendingDesktopDecisionKind.approval,
    );

    await HermesPendingDecisionStore.resolve(
      origin: 'https://hermes.example:443',
      runtimeId: 'runtime-1',
      requestId: 'request-1',
    );
    check(
      await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example:443',
        storedSessionId: 'stored-1',
      ),
    ).length.equals(1);

    await HermesPendingDecisionStore.clearOrigin('https://hermes.example:443');
    check(
      await HermesPendingDecisionStore.forSession(
        origin: 'https://other.example:443',
        storedSessionId: 'stored-2',
      ),
    ).length.equals(1);
  });

  test('persists the bounded MCP setup target and action', () async {
    await HermesPendingDecisionStore.upsert(
      origin: 'https://hermes.example:443',
      storedSessionId: 'stored-1',
      runtimeId: 'runtime-1',
      requestId: 'request-1',
      kind: HermesPendingDesktopDecisionKind.mcpSetup,
      mcpServer: 'github',
      mcpAction: 'authorize',
    );

    final record = (await HermesPendingDecisionStore.forSession(
      origin: 'https://hermes.example:443',
      storedSessionId: 'stored-1',
    )).single;
    check(record.mcpServer).equals('github');
    check(record.mcpAction).equals('authorize');
  });

  test('older resume data preserves clarification choices', () async {
    const args = (
      origin: 'https://hermes.example:443',
      storedSessionId: 'stored-1',
      runtimeId: 'runtime-1',
      requestId: 'request-1',
    );
    await HermesPendingDecisionStore.upsert(
      origin: args.origin,
      storedSessionId: args.storedSessionId,
      runtimeId: args.runtimeId,
      requestId: args.requestId,
      kind: HermesPendingDesktopDecisionKind.clarification,
      choices: const ['alpha', 'beta'],
      multiSelect: true,
    );
    await HermesPendingDecisionStore.upsert(
      origin: args.origin,
      storedSessionId: args.storedSessionId,
      runtimeId: args.runtimeId,
      requestId: args.requestId,
      kind: HermesPendingDesktopDecisionKind.clarification,
    );

    final record = (await HermesPendingDecisionStore.forSession(
      origin: args.origin,
      storedSessionId: args.storedSessionId,
    )).single;
    check(record.choices).deepEquals(const ['alpha', 'beta']);
    check(record.multiSelect).isTrue();
  });

  test(
    'rebinds one request to the latest runtime without duplication',
    () async {
      await HermesPendingDecisionStore.upsert(
        origin: 'https://hermes.example:443',
        storedSessionId: 'stored-1',
        runtimeId: 'runtime-old',
        requestId: 'request-1',
        kind: HermesPendingDesktopDecisionKind.clarification,
      );

      await HermesPendingDecisionStore.rebindSession(
        origin: 'https://hermes.example:443',
        fromStoredSessionId: 'stored-1',
        toStoredSessionId: 'stored-1',
        runtimeId: 'runtime-new',
      );

      final records = await HermesPendingDecisionStore.forSession(
        origin: 'https://hermes.example:443',
        storedSessionId: 'stored-1',
      );
      check(records).length.equals(1);
      check(records.single.runtimeId).equals('runtime-new');
    },
  );
}
