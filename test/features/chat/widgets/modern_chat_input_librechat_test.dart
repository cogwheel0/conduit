import 'package:conduit/features/chat/widgets/model_suggestion_overlay.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/database/chat_database_repository.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/features/librechat/models/librechat_prompts.dart'
    show kLibreChatPromptMetaKey;
import 'package:conduit_core/features/librechat/providers/librechat_composer_providers.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _otherModel = Model(id: 'other-model', name: 'Other model');

final Model _libreChatModel = libreChatCatalog(
  startupConfig: const <String, dynamic>{},
  endpoints: const <String, dynamic>{
    'Sample': <String, dynamic>{'order': 0},
  },
  models: const <String, List<String>>{
    'Sample': <String>['sample-model'],
  },
).single;

final class _Selected extends SelectedModel {
  _Selected(this.initial);

  final Model initial;

  @override
  Model? build() => initial;
}

final class _Active extends ActiveConversationNotifier {
  _Active(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

final class _Models extends Models {
  @override
  Future<List<Model>> build() async => [_libreChatModel, _otherModel];
}

final _overlay = find.byType(ModelSuggestionOverlay);

/// What the composer sent, in the test running.
final _sent = <String>[];

/// `@` switches the chat's model; a LibreChat turn takes no mention, and a
/// LibreChat chat goes on only with LibreChat's models.
void main() {
  testWidgets('@ lists no models while a LibreChat model is selected', (
    tester,
  ) async {
    await _pumpComposer(tester, _libreChatModel);

    await tester.enterText(find.byType(TextField), '@oth');
    await tester.pump(const Duration(milliseconds: 300));

    expect(_overlay, findsNothing);
    expect(find.text(_otherModel.name), findsNothing);
  });

  testWidgets('an open model list closes when a LibreChat model is chosen', (
    tester,
  ) async {
    final container = await _pumpComposer(tester, _otherModel);

    await tester.enterText(find.byType(TextField), '@sam');
    await tester.pump(const Duration(milliseconds: 300));
    expect(_overlay, findsOneWidget);

    container.read(selectedModelProvider.notifier).set(_libreChatModel);
    await tester.pump(const Duration(milliseconds: 300));

    expect(_overlay, findsNothing);
  });

  testWidgets('a LibreChat model chosen from @ is switched to with no '
      'mention', (tester) async {
    final container = await _pumpComposer(tester, _otherModel);

    await tester.enterText(find.byType(TextField), 'Hi @sam');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(of: _overlay, matching: find.text(_libreChatModel.name)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(selectedModelProvider), _libreChatModel);
    // Chosen by the user, as from the picker: a refresh keeps it.
    expect(container.read(isManualModelSelectionProvider), isTrue);
    // Nothing of the @query is left to be sent as an Open WebUI mention.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Hi ',
    );
    expect(_overlay, findsNothing);
  });

  testWidgets('a prompt whose command was replaced meanwhile goes at the '
      'caret', (tester) async {
    await _fillPromptAfterTextChanged(tester);

    expect(tester.takeException(), isNull);
    final composer = find.descendant(
      of: find.byType(ModernChatInput),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(composer.first).controller!.text,
      'HiPlan 3 days',
    );
  });

  testWidgets('a prompt whose command became another of the same length '
      'goes at the caret', (tester) async {
    // `/tr` became `/tx` where it stood.
    await _fillPromptAfterTextChanged(tester, replacement: 'Note /tx');

    expect(tester.takeException(), isNull);
    final composer = find.descendant(
      of: find.byType(ModernChatInput),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(composer.first).controller!.text,
      'Note /txPlan 3 days',
    );
  });

  testWidgets('a prompt whose command is still there replaces it', (
    tester,
  ) async {
    await _fillPromptAfterTextChanged(tester, replacement: 'Note /tr');

    expect(tester.takeException(), isNull);
    final composer = find.descendant(
      of: find.byType(ModernChatInput),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(composer.first).controller!.text,
      'Note Plan 3 days',
    );
  });

  testWidgets('@ lists no models in a LibreChat chat', (tester) async {
    final chat = withChatStorageProvenance(
      Conversation(
        id: 'librechat-chat',
        title: 'Sample chat',
        createdAt: DateTime.utc(2026, 10, 18),
        updatedAt: DateTime.utc(2026, 10, 18),
      ),
      ChatStorageKind.libreChat,
    );
    await _pumpComposer(tester, _otherModel, active: chat);

    await tester.enterText(find.byType(TextField), '@sam');
    await tester.pump(const Duration(milliseconds: 300));

    expect(_overlay, findsNothing);
    // The chat's database watch closes on a timer once the tree is gone.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('a model mentioned before switching to LibreChat goes out as '
      'the text shown', (tester) async {
    _sent.clear();
    final container = await _pumpComposer(tester, _otherModel);

    await tester.enterText(find.byType(TextField), 'Ask @oth');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.descendant(of: _overlay, matching: find.text(_otherModel.name)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // Then LibreChat's model is picked, which takes no mention.
    container.read(selectedModelProvider.notifier).set(_libreChatModel);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
    await tester.pump();
    expect(_sent, ['Ask @${_otherModel.name}']);
  });
}

/// A prompt's dialog is up while dictation replaces the composer's text.
Future<void> _fillPromptAfterTextChanged(
  WidgetTester tester, {
  String replacement = 'Hi',
}) async {
  await _pumpComposer(
    tester,
    _libreChatModel,
    overrides: [
      libreChatPromptsProvider.overrideWith(
        (ref) async => const [
          // As LibreChat's own prompts are marked, so its fill runs.
          Prompt(
            command: '/trip',
            title: 'Trip',
            content: 'Plan {{days}} days',
            meta: <String, dynamic>{kLibreChatPromptMetaKey: true},
          ),
        ],
      ),
    ],
  );
  final composer = find.descendant(
    of: find.byType(ModernChatInput),
    matching: find.byType(TextField),
  );
  await tester.enterText(composer.first, 'Note /tr');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Trip').last);
  await tester.pumpAndSettle();

  tester.widget<TextField>(composer.first).controller!.text = replacement;
  await tester.pump();
  await tester.enterText(
    find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(TextFormField),
    ),
    '3',
  );
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _pumpComposer(
  WidgetTester tester,
  Model model, {
  Conversation? active,
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedModelProvider.overrideWith(() => _Selected(model)),
        activeConversationProvider.overrideWith(() => _Active(active)),
        modelsProvider.overrideWith(_Models.new),
        isChatStreamingProvider.overrideWithValue(false),
        apiServiceProvider.overrideWithValue(null),
        ...overrides,
      ],
      child: MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ModernChatInput(onSendMessage: _sent.add)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(ModernChatInput)),
  );
}
