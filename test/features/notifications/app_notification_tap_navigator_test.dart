import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/features/navigation/providers/conversation_selection_provider.dart';
import 'package:conduit/features/notifications/services/notification_tap_router.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit_core/database/chat_database_repository.dart'
    show ChatStorageKind, kChatStorageKindMetadataKey;
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the chat a tap asked to open and answers with [result].
final class _RecordingSelection extends ConversationSelection {
  _RecordingSelection(this.result, this.selected);

  final ConversationSelectionResult result;
  final List<Conversation> selected;

  @override
  Future<ConversationSelectionResult> select(Conversation summary) async {
    selected.add(summary);
    return result;
  }
}

/// The Hermes service of one connection; nothing else is called on it.
class _HermesService extends Fake implements HermesBackendService {
  _HermesService(this.connectionId);

  final String? connectionId;

  @override
  HermesConfig get config => HermesConfig(connectionId: connectionId);
}

/// The Hermes connection in use, switchable by the test.
class _ActiveHermes extends Notifier<String?> {
  @override
  String? build() => 'conn-home';

  void use(String connectionId) => state = connectionId;
}

final _activeHermesProvider = NotifierProvider<_ActiveHermes, String?>(
  _ActiveHermes.new,
);

/// A session list that loads when the test says.
class _PendingSessions extends HermesSessionsController {
  _PendingSessions(this._sessions);

  final Future<List<HermesSessionSummary>> _sessions;

  @override
  Future<List<HermesSessionSummary>> build() => _sessions;
}

final _navigatorProvider = Provider<AppNotificationTapNavigator>(
  AppNotificationTapNavigator.new,
);

void main() {
  group('openOpenWebUiChat', () {
    late List<Conversation> selected;

    ProviderContainer containerAnswering(ConversationSelectionResult result) {
      selected = [];
      final container = ProviderContainer(
        overrides: [
          conversationSelectionProvider.overrideWith(
            () => _RecordingSelection(result, selected),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('opens the chat through the selection flow', () async {
      final container = containerAnswering(
        const ConversationSelectionResult.canceled(),
      );

      await container.read(_navigatorProvider).openOpenWebUiChat('c1');

      // The flow waits for the account's storage, loads the chat (from the
      // server without a copy here) and makes it the active conversation.
      check(selected).length.equals(1);
      check(selected.single.id).equals('c1');
      check(
        selected.single.metadata[kChatStorageKindMetadataKey],
      ).equals(ChatStorageKind.openWebUi.name);
    });

    test('a chat that fails to load does not throw', () async {
      final container = containerAnswering(
        ConversationSelectionResult.failed(
          StateError('storage'),
          StackTrace.empty,
        ),
      );

      await container.read(_navigatorProvider).openOpenWebUiChat('c1');

      check(selected.single.id).equals('c1');
    });
  });

  group('openHermesSession', () {
    late Completer<List<HermesSessionSummary>> sessions;
    late ProviderContainer container;

    Future<void> mount(WidgetTester tester) async {
      sessions = Completer<List<HermesSessionSummary>>();
      container = ProviderContainer(
        overrides: [
          hermesActiveConnectionIdProvider.overrideWith(
            (ref) => ref.watch(_activeHermesProvider),
          ),
          hermesApiServiceProvider.overrideWith(
            (ref) => _HermesService(ref.watch(_activeHermesProvider)),
          ),
          hermesSessionsProvider.overrideWith(
            () => _PendingSessions(sessions.future),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: NavigationService.navigatorKey,
            home: const SizedBox(),
          ),
        ),
      );
    }

    /// Whether opening the session started (it bumps the navigation epoch
    /// before anything else).
    bool started() => container.read(hermesSessionNavigationEpochProvider) > 0;

    testWidgets('opens on the connection it was tapped for', (tester) async {
      await mount(tester);
      final opening = container
          .read(_navigatorProvider)
          .openHermesSession('s-1', connectionId: 'conn-home', title: 'Plan')
          // Opening reads providers this test leaves real; it only has to
          // start.
          .catchError((Object _) {});
      await tester.pump();
      sessions.complete(const []);
      await tester.pump();
      await opening;

      check(started()).isTrue();
    });

    testWidgets('does not open on a connection switched to meanwhile', (
      tester,
    ) async {
      await mount(tester);
      final opening = container
          .read(_navigatorProvider)
          .openHermesSession('s-1', connectionId: 'conn-home', title: 'Plan');
      await tester.pump();
      // Another tap, or the user, switches while the session list loads.
      container.read(_activeHermesProvider.notifier).use('conn-work');
      sessions.complete(const []);
      await tester.pump();
      await opening;

      check(started()).isFalse();
    });
  });
}
