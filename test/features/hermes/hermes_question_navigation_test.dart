import 'package:conduit/features/hermes/providers/hermes_mobile_navigation.dart';
import 'package:conduit/features/hermes/widgets/hermes_message_interactions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Conversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => Conversation(
    id: 'audit-conversation',
    title: 'Audit conversation',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    metadata: const {'hermesSessionId': 'audit-session'},
  );
}

class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const [];
}

void main() {
  testWidgets('question answer survives Tasks and return to the same request', (
    tester,
  ) async {
    final question = ChatMessage(
      id: 'audit-question',
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026),
      metadata: {
        'transport': kHermesTransport,
        kHermesDecisionMeta: {
          'state': 'pending',
          'kind': HermesDecisionKind.clarification.name,
          'prompt': 'Which section should I update?',
          'requestId': 'audit-request',
          'runtimeId': 'audit-runtime',
          'storedSessionId': 'audit-session',
          'expiresAt': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        },
      },
    );
    final container = ProviderContainer(
      overrides: [
        hermesApiServiceProvider.overrideWithValue(null),
        hermesMobileLayoutProvider.overrideWithValue(true),
        activeConversationProvider.overrideWith(_Conversation.new),
        chatMessagesProvider.overrideWith(_Messages.new),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    final navigation = container.read(hermesMobileNavigationProvider.notifier);
    navigation.showConversation();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: HermesComposerPromptOverlay(message: question)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('hermes-written-answer'));
    await tester.enterText(field, 'Preserve this unanswered draft.');
    navigation.select(HermesWorkArea.tasks);
    await tester.pumpAndSettle();
    expect(field, findsNothing, reason: 'Tasks hides the chat prompt.');
    navigation.showConversation();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Preserve this unanswered draft.',
      reason:
          'Navigating away must not silently erase a pending written answer.',
    );
    navigation.select(HermesWorkArea.tasks);
    await tester.pumpAndSettle();
    container.read(hermesConnectionGenerationProvider.notifier).bump();
    await tester.pumpAndSettle();
    navigation.showConversation();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
      reason: 'A new connection principal must not inherit an answer.',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
