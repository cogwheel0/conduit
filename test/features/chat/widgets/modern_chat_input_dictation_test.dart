import 'dart:async';

import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/connectivity_service.dart'
    show isOnlineProvider;
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Stopping server dictation, or sending while it records, hands what was
/// said to the server; its text is in the composer when the stop returns
/// (#752).
void main() {
  const model = Model(id: 'alpha', name: 'Alpha');

  late List<String> sends;
  late _DictatingVoiceInput voice;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    sends = [];
    voice = _DictatingVoiceInput();
    container = ProviderContainer(
      overrides: [
        voiceInputServiceProvider.overrideWithValue(voice),
        voiceInputAvailableProvider.overrideWith((ref) async => true),
        selectedModelProvider.overrideWith(() => _Selected(model)),
        activeConversationProvider.overrideWith(() => _Active('chat-a')),
        modelsProvider.overrideWith(() => _Models(const [model])),
        chatMessagesProvider.overrideWith(_Messages.new),
        reviewerModeProvider.overrideWithValue(false),
        isOnlineProvider.overrideWithValue(true),
        temporaryChatEnabledProvider.overrideWith(_NotTemporary.new),
        webSearchEnabledProvider.overrideWith(_WebSearchOff.new),
        imageGenerationEnabledProvider.overrideWith(_ImageGenerationOff.new),
        authTokenProvider3.overrideWithValue('token'),
        isAuthenticatedProvider2.overrideWithValue(true),
        appSettingsProvider.overrideWith(_Settings.new),
        isChatStreamingProvider.overrideWithValue(false),
        webSearchAvailableProvider.overrideWithValue(false),
        imageGenerationAvailableProvider.overrideWithValue(false),
        personalizationSettingsProvider.overrideWith(_Personalization.new),
        directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
        currentUserProvider2.overrideWithValue(
          const User(
            id: 'me',
            username: 'me',
            email: 'me@example.test',
            role: 'user',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModernChatInput(onSendMessage: sends.add)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String composerText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<void> startDictation(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pumpAndSettle();
    expect(voice.listening, isTrue);
  }

  testWidgets('send while recording sends what was said', (tester) async {
    await pump(tester);
    await startDictation(tester);

    voice.transcriptOnStop = 'book the table for eight';
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pumpAndSettle();

    expect(voice.stopCalls, 1);
    expect(sends, ['book the table for eight']);
  });

  testWidgets('stop while recording keeps what was said', (tester) async {
    await pump(tester);
    await startDictation(tester);

    voice.transcriptOnStop = 'book the table for eight';
    await tester.tap(
      find.byKey(const ValueKey('composer-dictation-stop-button')),
    );
    await tester.pumpAndSettle();

    expect(voice.stopCalls, 1);
    expect(composerText(tester), 'book the table for eight');
    expect(sends, isEmpty);
  });

  testWidgets('send keeps the text when the chat changed meanwhile', (
    tester,
  ) async {
    await pump(tester);
    await startDictation(tester);

    voice
      ..transcriptOnStop = 'book the table for eight'
      ..stopGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pump();
    // The user opens another chat while the server transcribes.
    container.read(activeConversationProvider.notifier).set(_stored('chat-b'));
    voice.stopGate!.complete();
    await tester.pumpAndSettle();

    expect(sends, isEmpty);
    expect(composerText(tester), 'book the table for eight');
  });

  testWidgets('send keeps the text when another chat was opened while '
      'recording', (tester) async {
    await pump(tester);
    await startDictation(tester);

    // The composer stays up across a chat switch, and so does the dictation.
    container.read(activeConversationProvider.notifier).set(_stored('chat-b'));
    await tester.pumpAndSettle();
    voice.transcriptOnStop = 'book the table for eight';
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pumpAndSettle();

    expect(sends, isEmpty);
    expect(composerText(tester), 'book the table for eight');
  });

  testWidgets('send with nothing said sends nothing', (tester) async {
    await pump(tester);
    await startDictation(tester);

    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pumpAndSettle();

    expect(voice.stopCalls, 1);
    expect(sends, isEmpty);
  });
}

/// Server dictation: no text while recording; stopping hands the speech to
/// the server, and its transcript reaches the listener before the stop
/// returns, as [VoiceInputService.stopListening] does.
class _DictatingVoiceInput extends VoiceInputService {
  StreamController<String>? _run;
  String? transcriptOnStop;
  int stopCalls = 0;

  /// Holds the stop open, like a transcription still on its way.
  Completer<void>? stopGate;

  bool get listening => _run != null;

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async => true;

  @override
  Future<Stream<String>> beginListening({
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
    bool holdServerRecorderForResponseWait = false,
  }) async {
    final run = StreamController<String>.broadcast();
    _run = run;
    return run.stream;
  }

  @override
  Future<void> stopListening() async {
    stopCalls++;
    final run = _run;
    _run = null;
    if (run == null) return;
    await stopGate?.future;
    final transcript = transcriptOnStop;
    if (transcript != null) run.add(transcript);
    await run.close();
  }

  @override
  Future<void> dispose() async {}
}

final class _Selected extends SelectedModel {
  _Selected(this.model);

  final Model model;

  @override
  Model build() => model;
}

Conversation _stored(String id) => withChatStorageProvenance(
  Conversation(
    id: id,
    title: id,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  ChatStorageKind.openWebUi,
);

final class _Active extends ActiveConversationNotifier {
  _Active(this.id);

  final String id;

  @override
  Conversation? build() => _stored(id);
}

final class _Messages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

final class _NotTemporary extends TemporaryChatEnabled {
  @override
  bool build() => false;
}

final class _WebSearchOff extends WebSearchEnabledNotifier {
  @override
  bool build() => false;
}

final class _ImageGenerationOff extends ImageGenerationEnabledNotifier {
  @override
  bool build() => false;
}

final class _Models extends Models {
  _Models(this.listed);

  final List<Model> listed;

  @override
  Future<List<Model>> build() async => listed;
}

final class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(sendOnEnter: true);
}

final class _Personalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

final class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}
