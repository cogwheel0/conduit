import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:conduit_core/ports/flush_scheduler.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/flutter_flush_scheduler.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/renderer/details_block_widget.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _InactiveTts extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

class _NoActiveConversation extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _OpenDatabaseAccess extends OpenWebUiDatabaseAccessNotifier {
  @override
  OpenWebUiDatabaseAccessPhase build() => OpenWebUiDatabaseAccessPhase.open;
}

class _PausableFrameFlushScheduler implements FlushScheduler {
  var paused = false;
  final _pending = <void Function()>[];

  @override
  void scheduleFlush(void Function() callback) {
    if (paused) {
      _pending.add(callback);
    } else {
      const FlutterFlushScheduler().scheduleFlush(callback);
    }
  }

  void release() {
    paused = false;
    for (final callback in _pending) {
      const FlutterFlushScheduler().scheduleFlush(callback);
    }
    _pending.clear();
  }
}

const _answerWithTool =
    'Reasoning completed.\n\n'
    '<details type="tool_calls" name="lookup" done="true" id="call-a">'
    '<summary>Tool Executed</summary></details>\n\nAnswer.';

void main() {
  for (final canonicalFirst in [true, false]) {
    testWidgets(
      'tool tile survives ${canonicalFirst ? 'canonical then live' : 'live then canonical'} '
      'publication, remount, and completion',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
        final database = AppDatabase(NativeDatabase.memory());
        final scheduler = _PausableFrameFlushScheduler();
        final container = ProviderContainer(
          overrides: [
            openWebUiDatabaseAccessProvider.overrideWith(
              _OpenDatabaseAccess.new,
            ),
            appDatabaseProvider.overrideWithValue(database),
            activeConversationProvider.overrideWith(_NoActiveConversation.new),
            apiServiceProvider.overrideWithValue(null),
            socketServiceProvider.overrideWithValue(null),
            hermesApiServiceProvider.overrideWithValue(null),
            textToSpeechControllerProvider.overrideWith(_InactiveTts.new),
            streamingHapticsEnabledProvider.overrideWithValue(false),
            flushSchedulerProvider.overrideWithValue(scheduler),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        final notifier = container.read(chatMessagesProvider.notifier);
        notifier.setMessages([
          ChatMessage(
            id: 'assistant',
            role: 'assistant',
            content: '',
            isStreaming: true,
            timestamp: DateTime(2024),
          ),
        ]);

        Widget harness() => UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final message = ref.watch(chatMessagesProvider).last;
                  return AssistantMessageWidget(
                    message: message,
                    isStreaming: message.isStreaming,
                    showFollowUps: false,
                    showActionBar: false,
                    animateOnMount: false,
                    suppressStreamingHaptics: true,
                    onDelete: () {},
                  );
                },
              ),
            ),
          ),
        );

        await tester.pumpWidget(harness());
        await tester.pumpAndSettle();

        notifier.bufferLastMessageContent('Reasoning completed.');
        if (canonicalFirst) {
          // A structural event copies the buffer to canonical state. Before
          // the frame builds that state, the next event has already supplied
          // a newer tool projection to the live buffer.
          notifier.updateMessageById(
            'assistant',
            (message) => message.copyWith(metadata: {'checkpoint': 1}),
          );
          notifier.bufferLastMessageContent(_answerWithTool);
        } else {
          // Conversely, canonical state can contain a newer projection while
          // the visible provider is still waiting for its normal cadence.
          await tester.pump();
          await tester.pump();
          scheduler.paused = true;
          notifier.bufferLastMessageContent(_answerWithTool);
          notifier.updateMessageById(
            'assistant',
            (message) => message.copyWith(metadata: {'checkpoint': 1}),
          );
        }
        await tester.pump();
        await tester.pump();
        expect(find.byType(MarkdownDetailsBlock), findsOneWidget);
        if (!canonicalFirst) {
          expect(
            container.read(streamingContentProvider),
            'Reasoning completed.',
          );
        }

        // Virtualization can remount the row between those two publications.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(harness());
        expect(find.byType(MarkdownDetailsBlock), findsOneWidget);

        scheduler.release();
        await tester.pump();
        await tester.pump();
        expect(find.byType(MarkdownDetailsBlock), findsOneWidget);

        notifier.finishStreaming();
        await tester.pump();
        await tester.pump();
        expect(container.read(streamingContentProvider), isNull);
        expect(find.byType(MarkdownDetailsBlock), findsOneWidget);
        expect(find.text('Answer.', findRichText: true), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
