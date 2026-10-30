import 'dart:async';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'dart:typed_data';
import 'package:drift/native.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/features/chat/composer/composer_draft_store.dart';
import 'package:conduit/features/chat/providers/composer_draft_provider.dart';
import '../../../support/native_database.dart';

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

/// Dictation transcribes into the draft; sending is a separate action.
void main() {
  const model = Model(id: 'alpha', name: 'Alpha');

  late List<String> sends;
  late _DictatingVoiceInput voice;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, {ComposerDraftContext? draftOwner}) async {
    sends = [];
    voice = _DictatingVoiceInput();
    container = ProviderContainer(
      overrides: [
        if (draftOwner != null) composerDraftContextProvider.overrideWithValue(draftOwner),
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

  testWidgets('dictation preserves typed text and requires an explicit send', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'A small garden.');
    await startDictation(tester);
    expect(find.byKey(const ValueKey('primary-btn-send')), findsNothing);

    voice.transcriptOnStop = 'Add a blue pot.';
    await tester.tap(
      find.byKey(const ValueKey('composer-dictation-stop-button')),
    );
    await tester.pumpAndSettle();

    expect(voice.stopCalls, 1);
    expect(sends, isEmpty);
    expect(composerText(tester), 'A small garden. Add a blue pot.');
    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pumpAndSettle();
    expect(sends, ['A small garden. Add a blue pot.']);
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

  testWidgets('Enter stops dictation and keeps the combined text unsent', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), 'Four tiles');
    await startDictation(tester);
    voice.transcriptOnStop = 'and one blue tile';
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(voice.stopCalls, 1);
    expect(sends, isEmpty);
    expect(composerText(tester), 'Four tiles and one blue tile');
  });

  testWidgets('a late transcript stays in the chat that started it', (
    tester,
  ) async {
    await pump(tester);
    await startDictation(tester);

    voice
      ..transcriptOnStop = 'book the table for eight'
      ..stopGate = Completer<void>();
    await tester.tap(
      find.byKey(const ValueKey('composer-dictation-stop-button')),
    );
    await tester.pump();
    // The user opens another chat while the server transcribes.
    container.read(activeConversationProvider.notifier).set(_stored('chat-b'));
    voice.stopGate!.complete();
    await tester.pumpAndSettle();

    expect(sends, isEmpty);
    expect(composerText(tester), isEmpty);
    container.read(activeConversationProvider.notifier).set(_stored('chat-a'));
    await tester.pumpAndSettle();
    expect(composerText(tester), 'book the table for eight');
  });

  testWidgets(
    'dictation stays with its starting chat after another chat opens while '
    'recording',
    (tester) async {
      await pump(tester);
      await startDictation(tester);

      voice.transcriptOnStop = 'book the table for eight';
      // Switching chats stops capture; the final words stay with its owner.
      container
          .read(activeConversationProvider.notifier)
          .set(_stored('chat-b'));
      await tester.pumpAndSettle();
      expect(voice.stopCalls, 1);
      expect(sends, isEmpty);
      expect(composerText(tester), isEmpty);
      container
          .read(activeConversationProvider.notifier)
          .set(_stored('chat-a'));
      await tester.pumpAndSettle();
      expect(composerText(tester), 'book the table for eight');
    },
  );

  testWidgets('unmounting waits for the final audio before closing its writer', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = ComposerDraftStore(db);
    final ComposerDraftContext owner = (
      owner: (backend: 'example', account: 'paper', principal: 'reader', session: null),
      scope: 'new:', chatId: '', store: store, temporary: false,
    );
    try {
      await pump(tester, draftOwner: owner);
      await tester.tap(find.byIcon(Icons.mic));
      await pumpDatabaseOperation(tester, () => voice.recordingReady.future);
      voice.recording!.add(Uint8List.fromList([1, 2]));
      voice.tailOnStop = Uint8List.fromList([3, 4]);
      voice.stopGate = Completer<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      voice.stopGate!.complete();
      await pumpDatabaseOperation(tester, () => voice.stopped.future);
      final saved = await pumpDatabaseOperation(tester, () => store.recordings.watch('new:', '').firstWhere((rows) => rows.any((row) => row.byteCount > 0)));
      expect(saved, hasLength(1));
      final pcm = await pumpDatabaseOperation(tester, () => store.recordings.readPcm(saved.single.id));
      expect(pcm, [1, 2, 3, 4]);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await pumpDatabaseOperation(tester, db.close);
    }
  });

  testWidgets('stopping with nothing said sends nothing', (tester) async {
    await pump(tester);
    await startDictation(tester);

    await tester.tap(
      find.byKey(const ValueKey('composer-dictation-stop-button')),
    );
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
  VoiceInputRecording? recording;
  Uint8List? tailOnStop;
  final recordingReady = Completer<void>();
  final stopped = Completer<void>();

  /// Holds the stop open, like a transcription still on its way.
  Completer<void>? stopGate;

  bool get listening => _run != null;

  @override
  bool get isSupportedPlatform => true;

  @override
  bool get recordingRecoverySupported => true;

  @override
  Future<bool> initialize({bool forceLocalStt = false}) async => true;

  @override
  Future<Stream<String>> beginListening({
    bool iosAudioSessionManagedExternally = false,
    bool nativeAccumulateResults = true,
    bool holdServerRecorderForResponseWait = false,
    VoiceInputRecording? recording,
  }) async {
    final run = StreamController<String>.broadcast();
    _run = run;
    this.recording = recording;
    if (!recordingReady.isCompleted) recordingReady.complete();
    return run.stream;
  }

  @override
  Future<void> stopListening() async {
    stopCalls++;
    final run = _run;
    _run = null;
    if (run == null) return;
    await stopGate?.future;
    if (tailOnStop case final tail?) recording?.add(tail);
    final transcript = transcriptOnStop;
    if (transcript != null) run.add(transcript);
    await run.close();
    if (!stopped.isCompleted) stopped.complete();
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
