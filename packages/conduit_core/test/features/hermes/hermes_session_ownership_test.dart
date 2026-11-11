import 'package:checks/checks.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/ports/key_value_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

void main() {
  group('HermesCapabilities.apiOwnsSessions', () {
    test('is set only by an explicit run_unknown_resolution feature', () {
      check(
        HermesCapabilities.fromJson(const {
          'features': {'run_unknown_resolution': true, 'session_fork': true},
        }).apiOwnsSessions,
      ).isTrue();
      check(
        HermesCapabilities.fromJson(const {
          'features': {'session_fork': true},
          'endpoints': {
            'run_unknown_resolution': {
              'method': 'POST',
              'path': '/v1/runs/{run_id}/resolve-unknown',
            },
          },
        }).apiOwnsSessions,
      ).isFalse();
      check(HermesCapabilities.enabledByDefault.apiOwnsSessions).isFalse();
    });
  });

  group('isForeignHermesSessionSource', () {
    test('API-owned and unknown sources can be continued', () {
      for (final source in [null, '', '  ', 'api_server', 'bot_room']) {
        check(isForeignHermesSessionSource(source)).isFalse();
      }
    });

    test('sessions from other Hermes surfaces are foreign', () {
      for (final source in ['telegram', 'cli', 'desktop', 'cron', 'Mobile']) {
        check(isForeignHermesSessionSource(source)).isTrue();
      }
    });
  });

  group('read-only Hermes sessions', () {
    setUp(() => PreferencesStore.debugOverride(InMemoryKeyValueStore()));
    tearDown(PreferencesStore.debugReset);

    ProviderContainer container() {
      final container = ProviderContainer(
        overrides: [hermesApiServiceProvider.overrideWithValue(null)],
      );
      addTearDown(container.dispose);
      return container;
    }

    Conversation chat(String sessionId, {String title = 'Tide tables'}) =>
        Conversation(
          id: 'local:hermes_$sessionId',
          title: title,
          createdAt: DateTime.utc(2026, 7, 14),
          updatedAt: DateTime.utc(2026, 7, 14),
          metadata: {'backend': 'hermes', 'hermesSessionId': sessionId},
        );

    // A refused send marks the session without a source, and replaced the
    // owner the session's opening had named, so the notice named none.
    test('a mark without a source keeps the owner named before', () {
      final scope = container();
      final sessions = scope.read(hermesReadOnlySessionsProvider.notifier);

      sessions.mark('s-1', source: 'cli');
      sessions.mark('s-1');
      check(scope.read(hermesReadOnlySessionsProvider)).deepEquals({
        's-1': 'cli',
      });

      sessions
        ..mark('s-1', source: 'telegram')
        ..mark('s-2');
      check(scope.read(hermesReadOnlySessionsProvider)).deepEquals({
        's-1': 'telegram',
        's-2': '',
      });
    });

    // Its rows still offered delete and regenerate while the composer said
    // Conduit may only read the chat.
    test('the open chat is read-only while its Hermes session is', () {
      final scope = container();
      scope
          .read(activeConversationProvider.notifier)
          .set(markNativeHermesConversation(chat('s-1')));
      check(scope.read(activeHermesSessionReadOnlyProvider)).isFalse();

      scope.read(hermesReadOnlySessionsProvider.notifier).mark('s-2');
      check(scope.read(activeHermesSessionReadOnlyProvider)).isFalse();

      scope.read(hermesReadOnlySessionsProvider.notifier).mark('s-1');
      check(scope.read(activeHermesSessionReadOnlyProvider)).isTrue();

      // Metadata alone, which a server could have written, is not a Hermes
      // chat Conduit opened.
      scope
          .read(activeConversationProvider.notifier)
          .set(chat('s-1', title: 'Tide tables, again'));
      check(scope.read(activeHermesSessionReadOnlyProvider)).isFalse();
    });
  });
}
