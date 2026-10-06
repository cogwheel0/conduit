import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:conduit/features/chat/providers/text_to_speech_provider.dart';
import 'package:conduit/features/chat/widgets/chat_comparison_widgets.dart';
import 'package:conduit/features/chat/widgets/model_selector_sheet.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        ChatForkAvailability,
        ComparisonAdmissionException,
        ComparisonAdmissionFailure,
        ComparisonMergeController,
        ChatMessagesNotifier,
        chatBranchSiblingsProvider,
        chatForkAvailabilityProvider,
        chatMessagesProvider,
        comparisonMergeCommandAvailableProvider,
        comparisonMergeProvider;
import 'package:conduit_core/features/chat/services/chat_branch_service.dart'
    show ChatBranchSiblings;
import 'package:conduit_core/features/chat/services/chat_comparison_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:conduit/features/chat/widgets/assistant_message_widget.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/conversation_parsing.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

class _SilentTextToSpeechController extends TextToSpeechController {
  @override
  TextToSpeechState build() => const TextToSpeechState();
}

/// The message the transcript shows for a golden blob, parsed the way the app
/// parses a chat once the database has rebuilt it.
ChatMessage _displayedAnswer(
  String fixture, {
  bool Function(ChatMessage)? where,
}) {
  final raw = jsonDecode(
    File('packages/conduit_core/test/fixtures/chat_blobs/$fixture.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;
  final conversation = parseFullConversationModel(<String, dynamic>{
    ...(raw['envelope'] as Map<String, dynamic>),
    'chat': raw['chat'],
  });
  return conversation.messages.lastWhere(
    (m) => m.role == 'assistant' && (where?.call(m) ?? true),
  );
}

Widget _harness(
  ChatMessage message, {
  Set<String>? continuableIds,
  bool readOnly = false,
  List<Override> overrides = const <Override>[],
}) {
  return ProviderScope(
    overrides: [
      ...overrides,
      textToSpeechControllerProvider.overrideWith(
        _SilentTextToSpeechController.new,
      ),
      streamingHapticsEnabledProvider.overrideWithValue(false),
      if (continuableIds != null) ...[
        // The transcript notifier would clear a chat it cannot certify.
        chatMessagesProvider.overrideWith(_EmptyMessages.new),
        chatForkAvailabilityProvider.overrideWithValue(
          ChatForkAvailability.hidden,
        ),
        activeConversationProvider.overrideWith(
          () => _SeededActive(
            Conversation(
              id: 'chat-1',
              title: 'Chat',
              createdAt: DateTime.utc(2026, 7, 13),
              updatedAt: DateTime.utc(2026, 7, 13),
            ),
          ),
        ),
        // The stored graph is the branch controller's business and has its own
        // tests; here the widget is only asked what it offers for an answer.
        chatBranchSiblingsProvider.overrideWith(
          (ref, key) async => ChatBranchSiblings(
            messageId: key.messageId,
            ids: continuableIds.toList(growable: false),
          ),
        ),
      ],
    ],
    child: MaterialApp(
      theme: AppTheme.light(TweakcnThemes.t3Chat),
      localizationsDelegates: conduitLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AssistantMessageWidget(
            message: message,
            isStreaming: false,
            readOnly: readOnly,
            animateOnMount: false,
            modelName: message.model,
            onCopy: () {},
            onRegenerate: () {},
            onDelete: () {},
          ),
        ),
      ),
    ),
  );
}

class _SeededActive extends ActiveConversationNotifier {
  _SeededActive(this.initial);

  final Conversation? initial;

  @override
  Conversation? build() => initial;
}

class _RecordingMerge extends ComparisonMergeController {
  _RecordingMerge({this.running});

  /// The answer a merge is already writing into, if any.
  final String? running;
  final List<Map<String, Object?>> calls = [];
  int cancels = 0;

  @override
  String? build() => running;

  @override
  Future<void> merge({
    required String targetMessageId,
    required String displayedMessageId,
    required String parentMessageId,
    required String model,
    required List<String> responses,
  }) async {
    calls.add({
      'target': targetMessageId,
      'displayed': displayedMessageId,
      'parent': parentMessageId,
      'model': model,
      'responses': responses,
    });
  }

  @override
  Future<void> cancel() async => cancels++;
}

class _EmptyMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => const <ChatMessage>[];
}

class _FixedPersonalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

/// The providers a model list reads, with nothing behind them.
List<dynamic> _pickerOverrides(AppDatabase db) => [
  apiServiceProvider.overrideWithValue(
    ApiService(
      serverConfig: const ServerConfig(
        id: 'compare',
        name: 'compare',
        url: 'https://compare.example.test',
      ),
      workerManager: WorkerManager(),
    ),
  ),
  reviewerModeProvider.overrideWithValue(false),
  personalizationSettingsProvider.overrideWith(_FixedPersonalization.new),
  directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
  currentUserProvider2.overrideWithValue(
    const User(
      id: 'me',
      username: 'me',
      email: 'me@example.test',
      role: 'user',
    ),
  ),
];

Finder _tab(String label) => find.bySemanticsLabel(label);

const _admin = User(
  id: 'admin',
  username: 'admin',
  email: 'admin@example.test',
  role: 'admin',
);
const _regular = User(
  id: 'regular',
  username: 'regular',
  email: 'regular@example.test',
  role: 'user',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('every saved slot is reachable and equal models stay distinct', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _harness(_displayedAnswer('13_duplicate_model_comparison')),
    );
    await tester.pumpAndSettle();

    // Two runs of one model: told apart by position, not merged into one tab.
    check(_tab('GPT-4o · 1').evaluate()).isNotEmpty();
    check(_tab('GPT-4o · 2').evaluate()).isNotEmpty();
    expect(
      tester.getSemantics(_tab('GPT-4o · 2')),
      isSemantics(isSelected: true, hasSelectedState: true),
    );
    expect(
      tester.getSemantics(_tab('GPT-4o · 1')),
      isSemantics(isSelected: false, hasSelectedState: true),
    );

    // The transcript opens on the slot the active branch ends in.
    check(find.text('17 is prime.').evaluate()).isNotEmpty();
    check(find.text('13 is a prime number.').evaluate()).isEmpty();

    await tester.tap(_tab('GPT-4o · 1'));
    await tester.pumpAndSettle();
    check(find.text('13 is a prime number.').evaluate()).isNotEmpty();
    check(find.text('17 is prime.').evaluate()).isEmpty();
    semantics.dispose();
  });

  testWidgets('choosing another answer is how the next turn continues from '
      'it', (tester) async {
    final shown = _displayedAnswer('13_duplicate_model_comparison');
    await tester.pumpWidget(
      _harness(
        shown,
        // The stored graph lists every answer of the turn as an alternative.
        continuableIds: {
          'b1b1b1b1-0000-4000-8000-000000000001',
          'b1b1b1b1-0000-4000-8000-000000000002',
          'b1b1b1b1-0000-4000-8000-000000000003',
        },
      ),
    );
    await tester.pumpAndSettle();
    final continueLabel = AppLocalizationsEn().chatBranchContinueFromResponse;

    // The answer the branch already ends on offers nothing to switch to.
    expect(find.byTooltip(continueLabel), findsNothing);

    await tester.tap(find.bySemanticsLabel('GPT-4o · 1'));
    await tester.pumpAndSettle();
    // Another slot's answer, previewed, can become the branch's continuation.
    expect(find.byTooltip(continueLabel), findsOneWidget);
  });

  testWidgets('a slot with one run has no pager and the merge sits beside, '
      'not instead of, the answer', (tester) async {
    await tester.pumpWidget(
      _harness(_displayedAnswer('13_duplicate_model_comparison')),
    );
    await tester.pumpAndSettle();

    // Slot 1 holds two runs: its pager counts only those.
    final pager = find.byKey(const ValueKey<String>('assistant-version-pager'));
    check(pager.evaluate()).isNotEmpty();
    check(find.descendant(of: pager, matching: find.text('2/2')).evaluate())
        .isNotEmpty();

    await tester.tap(find.bySemanticsLabel('GPT-4o · 1'));
    await tester.pumpAndSettle();
    check(pager.evaluate()).isEmpty();
    // Slot 0's saved merge appears with its heading while the original text
    // is still shown.
    check(find.text('Merged response').evaluate()).isNotEmpty();
    check(find.textContaining('Both runs agree').evaluate()).isNotEmpty();
    check(find.text('13 is a prime number.').evaluate()).isNotEmpty();
  });

  testWidgets('a plain regeneration history keeps the ordinary pager and no '
      'tabs', (tester) async {
    final message = _displayedAnswer(
      '03_branched_regeneration',
      where: (m) => m.versions.isNotEmpty,
    );
    await tester.pumpWidget(_harness(message));
    await tester.pumpAndSettle();

    check(message.versions).isNotEmpty();
    check(find.bySemanticsLabel('Model answers').evaluate()).isEmpty();
    check(
      find.byKey(const ValueKey<String>('assistant-version-pager')).evaluate(),
    ).isNotEmpty();
  });

  group('Compare models setup', () {
    const alpha = Model(id: 'alpha', name: 'Alpha');
    const beta = Model(id: 'beta', name: 'Beta');
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => Directory.systemTemp.path,
          );
    });
    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      await db.close();
    });

    Future<ProviderContainer> pumpHost(
      WidgetTester tester,
      Widget sheet, {
      Model? selected,
      bool overrideSelected = true,
    }) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => db),
          if (overrideSelected)
            selectedModelProvider.overrideWithValue(selected),
          activeConversationProvider.overrideWith(() => _SeededActive(null)),
          ..._pickerOverrides(db).cast(),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: sheet),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      return container;
    }

    // Sheets keep a running animation, so the page never "settles": give the
    // route transition time to finish instead.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 400));
      }
    }

    testWidgets('two slots, duplicates allowed, and Compare waits for both', (
      tester,
    ) async {
      List<Model>? result;
      await pumpHost(
        tester,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showModalBottomSheet<List<Model>>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const ComparisonSetupSheet(
                    models: [alpha, beta],
                    initialFirst: alpha,
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
        selected: alpha,
      );
      await tester.tap(find.text('open'));
      await settle(tester);

      final l10n = AppLocalizationsEn();
      // The chat's model fills the first slot; the second is still open.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text(l10n.chatCompareChooseModel), findsOneWidget);
      final compare = find.widgetWithText(ConduitButton, l10n.chatCompareStart);
      expect(tester.widget<ConduitButton>(compare).onPressed, isNull);

      // Choose the SAME model for the second slot: a valid comparison.
      await tester.tap(find.byKey(const ValueKey<String>('comparison-slot-1')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(ModelSelectorSheet),
          matching: find.text('Alpha'),
        ),
      );
      await settle(tester);
      // Both slots now read Alpha: the same model twice is a valid pair.
      expect(find.text('Alpha'), findsNWidgets(2));
      expect(tester.widget<ConduitButton>(compare).onPressed, isNotNull);

      await tester.tap(compare);
      await settle(tester);
      expect(result!.map((model) => model.id), ['alpha', 'alpha']);
    });

    testWidgets('the ordinary picker still selects in one tap, and pick mode '
        'hands the model over without selecting it', (tester) async {
      Model? picked;
      final container = await pumpHost(
        tester,
        Builder(
          builder: (context) => Center(
            child: Column(
              children: [
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) =>
                        const ModelSelectorSheet(models: [alpha, beta]),
                  ),
                  child: const Text('open ordinary'),
                ),
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => ModelSelectorSheet(
                      models: const [alpha, beta],
                      onPick: (model) => picked = model,
                    ),
                  ),
                  child: const Text('open pick'),
                ),
              ],
            ),
          ),
        ),
        selected: null,
        overrideSelected: false,
      );

      await tester.tap(find.text('open pick'));
      await settle(tester);
      await tester.tap(find.text('Beta'));
      await settle(tester);
      expect(picked?.id, 'beta');
      expect(container.read(selectedModelProvider)?.id, isNot('beta'));
      // The sheet closed on that one tap.
      expect(find.byType(ModelSelectorSheet), findsNothing);

      await tester.tap(find.text('open ordinary'));
      await settle(tester);
      await tester.tap(find.text('Alpha'));
      await settle(tester);
      expect(container.read(selectedModelProvider)?.id, 'alpha');
      expect(find.byType(ModelSelectorSheet), findsNothing);
    });
  });

  group('refused comparisons are explained', () {
    final l10n = AppLocalizationsEn();

    test('each reason has words, and a settings conflict names its cause', () {
      for (final reason in ComparisonAdmissionFailure.values) {
        final text = comparisonAdmissionMessage(
          l10n,
          ComparisonAdmissionException(
            reason,
            modelIds: const ['gpt-4o'],
            conflict: reason == ComparisonAdmissionFailure.settingsConflict
                ? const ComparisonSettingsConflict(
                    parameter: 'reasoning_effort',
                    source: ComparisonConflictSource.chatOverride,
                    modelIds: ['gpt-4o'],
                  )
                : null,
          ),
        );
        expect(text, isNotEmpty);
      }
      expect(
        comparisonAdmissionMessage(
          l10n,
          const ComparisonAdmissionException(
            ComparisonAdmissionFailure.settingsConflict,
            modelIds: ['gpt-4o'],
            conflict: ComparisonSettingsConflict(
              parameter: 'reasoning_effort',
              source: ComparisonConflictSource.chatOverride,
              modelIds: ['gpt-4o'],
            ),
          ),
        ),
        contains('Remove it in chat settings'),
      );
      expect(
        comparisonAdmissionMessage(
          l10n,
          const ComparisonAdmissionException(
            ComparisonAdmissionFailure.settingsConflict,
            conflict: ComparisonSettingsConflict(
              parameter: 'reasoning_effort',
              source: ComparisonConflictSource.modelPicker,
              modelIds: ['a', 'b'],
            ),
          ),
        ),
        contains('different reasoning efforts'),
      );
    });
  });

  group('Merge responses', () {
    final l10n = AppLocalizationsEn();
    const shownId = 'b1b1b1b1-0000-4000-8000-000000000003';

    testWidgets('is offered with Advanced on and merges each slot\'s answer '
        'into the answer being shown', (tester) async {
      final merge = _RecordingMerge();
      await tester.pumpWidget(
        _harness(
          _displayedAnswer('13_duplicate_model_comparison'),
          overrides: [
            comparisonMergeCommandAvailableProvider.overrideWithValue(true),
            comparisonMergeProvider.overrideWith(() => merge),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The command lives in the footer's overflow menu.
      expect(find.text(l10n.chatMergeResponsesAction), findsNothing);
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatMergeResponsesAction), findsOneWidget);
      await tester.tap(find.text(l10n.chatMergeResponsesAction));
      await tester.pumpAndSettle();

      expect(merge.calls, hasLength(1));
      final call = merge.calls.single;
      expect(call['target'], shownId);
      expect(call['displayed'], shownId);
      expect(call['parent'], 'c0c0c0c0-0000-4000-8000-000000000001');
      expect(call['model'], 'gpt-4o');
      // Slot order: the first slot's answer, then the shown one.
      expect(call['responses'], ['13 is a prime number.', '17 is prime.']);
    });

    testWidgets('is not offered with Advanced off, yet the saved merge stays '
        'readable beside its answer', (tester) async {
      await tester.pumpWidget(
        _harness(
          _displayedAnswer('13_duplicate_model_comparison'),
          overrides: [
            comparisonMergeCommandAvailableProvider.overrideWithValue(false),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatMergeResponsesAction), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('GPT-4o · 1'));
      await tester.pumpAndSettle();
      // The answer and its merge are both on screen: neither replaces the other.
      expect(find.text('13 is a prime number.'), findsOneWidget);
      expect(find.text(l10n.chatMergedResponseTitle), findsOneWidget);
      expect(find.textContaining('Both runs agree'), findsOneWidget);
    });

    testWidgets('is not offered to a reader of another account\'s comparison, '
        'whose saved merge stays readable', (tester) async {
      final merge = _RecordingMerge();
      await tester.pumpWidget(
        _harness(
          _displayedAnswer('13_duplicate_model_comparison'),
          readOnly: true,
          overrides: [
            comparisonMergeCommandAvailableProvider.overrideWithValue(true),
            comparisonMergeProvider.overrideWith(() => merge),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // A reader's footer is shorter, so merge would sit inline (a tooltip
      // button) rather than in the overflow menu; it is in neither.
      expect(find.byTooltip(l10n.chatMergeResponsesAction), findsNothing);
      final overflow = find.byIcon(Icons.more_horiz_rounded);
      if (overflow.evaluate().isNotEmpty) {
        await tester.tap(overflow);
        await tester.pumpAndSettle();
      }
      expect(find.text(l10n.chatMergeResponsesAction), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('GPT-4o · 1'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatMergedResponseTitle), findsOneWidget);
      expect(find.textContaining('Both runs agree'), findsOneWidget);
      expect(merge.calls, isEmpty);
    });

    testWidgets('a merge in progress can be stopped from the answer it is '
        'writing into', (tester) async {
      final merge = _RecordingMerge(running: shownId);
      await tester.pumpWidget(
        _harness(
          _displayedAnswer('13_duplicate_model_comparison'),
          overrides: [
            comparisonMergeCommandAvailableProvider.overrideWithValue(false),
            comparisonMergeProvider.overrideWith(() => merge),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatMergeResponsesAction), findsNothing);
      await tester.tap(find.text(l10n.chatMergeStopAction));
      await tester.pumpAndSettle();
      expect(merge.cancels, 1);
    });

    /// A four-slot turn the way a chat stored by Open WebUI holds it: three
    /// slots finished, one failed, and slot [shownSlot] on screen.
    ChatMessage turn({
      int shownSlot = 2,
      Set<int> failed = const {3},
      Set<int> streaming = const {},
      // Stored copies the server still reports not done: they hold text, but
      // only what was written so far.
      Set<int> partial = const {},
    }) {
      const names = ['Alpha', 'Beta', 'Gamma', 'Delta'];
      ChatMessageError? errorOf(int slot) => failed.contains(slot)
          ? const ChatMessageError(content: 'boom')
          : null;
      return ChatMessage(
        id: 'answer-$shownSlot',
        role: 'assistant',
        content: failed.contains(shownSlot)
            ? ''
            : 'text of ${names[shownSlot]}',
        timestamp: DateTime.utc(2026, 7, 13),
        model: 'model-${names[shownSlot]}',
        isStreaming: streaming.contains(shownSlot),
        error: errorOf(shownSlot),
        metadata: {
          'parentId': 'prompt-1',
          'modelName': names[shownSlot],
          'modelIdx': shownSlot,
          'responseDone': !streaming.contains(shownSlot),
          if (partial.isNotEmpty)
            'unfinishedAnswerIds': [for (final slot in partial) 'answer-$slot'],
        },
        versions: [
          for (var slot = 0; slot < names.length; slot++)
            if (slot != shownSlot)
              ChatMessageVersion(
                id: 'answer-$slot',
                content: failed.contains(slot) || streaming.contains(slot)
                    ? ''
                    : 'text of ${names[slot]}',
                timestamp: DateTime.utc(2026, 7, 13),
                model: 'model-${names[slot]}',
                modelName: names[slot],
                modelIdx: slot,
                error: errorOf(slot),
              ),
        ],
      );
    }

    Future<_RecordingMerge> pumpMerge(
      WidgetTester tester,
      ChatMessage message,
    ) async {
      final merge = _RecordingMerge();
      await tester.pumpWidget(
        _harness(
          message,
          overrides: [
            comparisonMergeCommandAvailableProvider.overrideWithValue(true),
            comparisonMergeProvider.overrideWith(() => merge),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return merge;
    }

    Future<void> openMergeCommand(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.chatMergeResponsesAction));
      await tester.pumpAndSettle();
    }

    testWidgets('with more than two finished answers the user chooses, and '
        'only the chosen answers\' own texts are sent', (tester) async {
      final merge = await pumpMerge(tester, turn());
      await openMergeCommand(tester);

      // Three finished answers are offered; the failed slot is not.
      for (final id in ['answer-0', 'answer-1', 'answer-2']) {
        expect(
          find.byKey(ValueKey<String>('merge-source-$id')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey<String>('merge-source-answer-3')),
        findsNothing,
      );
      expect(merge.calls, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey<String>('merge-source-answer-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ChatMergeSourcesSheet),
          matching: find.widgetWithText(
            ConduitButton,
            l10n.chatMergeResponsesAction,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final call = merge.calls.single;
      expect(call['responses'], ['text of Alpha', 'text of Gamma']);
      expect(call['target'], 'answer-2');
      expect(call['parent'], 'prompt-1');
    });

    testWidgets('the sheet will not merge fewer than two answers', (
      tester,
    ) async {
      final merge = await pumpMerge(tester, turn());
      await openMergeCommand(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('merge-source-answer-0')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('merge-source-answer-1')),
      );
      await tester.pumpAndSettle();

      final button = find.descendant(
        of: find.byType(ChatMergeSourcesSheet),
        matching: find.widgetWithText(
          ConduitButton,
          l10n.chatMergeResponsesAction,
        ),
      );
      expect(tester.widget<ConduitButton>(button).onPressed, isNull);
      expect(merge.calls, isEmpty);
    });

    testWidgets('two finished answers merge straight away even though a third '
        'slot failed or is still responding', (tester) async {
      final merge = await pumpMerge(
        tester,
        turn(failed: const {3}, streaming: const {1}),
      );
      await openMergeCommand(tester);

      // Alpha and Gamma are the only finished answers: nothing to choose.
      expect(find.byType(ChatMergeSourcesSheet), findsNothing);
      expect(merge.calls.single['responses'], [
        'text of Alpha',
        'text of Gamma',
      ]);
    });

    testWidgets('a stored sibling the server still reports unfinished is not a '
        'source, though it holds partial text', (tester) async {
      final merge = await pumpMerge(
        tester,
        turn(failed: const {3}, partial: const {1}),
      );
      await openMergeCommand(tester);

      // Beta's partial text is left out, so Alpha and Gamma merge directly.
      expect(find.byType(ChatMergeSourcesSheet), findsNothing);
      expect(merge.calls.single['responses'], [
        'text of Alpha',
        'text of Gamma',
      ]);
    });

    testWidgets('is not offered while the shown answer is unfinished, and not '
        'with a single finished answer', (tester) async {
      await pumpMerge(tester, turn(shownSlot: 3, failed: const {3}));
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatMergeResponsesAction), findsNothing);

      await pumpMerge(tester, turn(failed: const {0, 1, 3}));
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatMergeResponsesAction), findsNothing);
    });
  });

  group('Stopping one answer', () {
    final l10n = AppLocalizationsEn();

    ChatMessage answer(
      String id,
      int slot, {
      String? taskId,
      bool streaming = true,
      bool comparison = true,
    }) => ChatMessage(
      id: id,
      role: 'assistant',
      content: 'partial $id',
      timestamp: DateTime.utc(2026, 7, 13),
      model: 'gpt-4o',
      isStreaming: streaming,
      metadata: {
        'parentId': 'prompt-1',
        if (comparison) 'modelIdx': slot,
        'taskId': ?taskId,
      },
    );

    // The pinned server routes a per-task stop through its admin check.
    Future<({_StopRecordingApi api, ProviderContainer container})> pumpAnswers(
      WidgetTester tester,
      List<ChatMessage> messages, {
      bool advanced = false,
      User user = _admin,
    }) async {
      final api = _StopRecordingApi();
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(api),
          currentUserProvider2.overrideWithValue(user),
          chatMessagesProvider.overrideWith(() => _SeededMessages(messages)),
          textToSpeechControllerProvider.overrideWith(
            _SilentTextToSpeechController.new,
          ),
          streamingHapticsEnabledProvider.overrideWithValue(false),
          if (advanced) appSettingsProvider.overrideWith(_AdvancedOn.new),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(
                child: Consumer(
                  builder: (context, ref, _) => Column(
                    children: [
                      for (final message in ref.watch(chatMessagesProvider))
                        AssistantMessageWidget(
                          key: ValueKey<String>('answer-${message.id}'),
                          message: message,
                          isStreaming: message.isStreaming,
                          animateOnMount: false,
                          modelName: message.model,
                          onCopy: () {},
                          onRegenerate: () {},
                          onDelete: () {},
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      return (api: api, container: container);
    }

    // Semantics must be on before this finder is built, so it is built per use.
    Finder stop() => find.bySemanticsLabel(
      AppLocalizationsEn().chatComparisonStopAnswerAction,
    );

    testWidgets('stops that answer\'s task and leaves its sibling streaming, '
        'with Advanced off', (tester) async {
      final semantics = tester.ensureSemantics();
      final (:api, :container) = await pumpAnswers(tester, [
        answer('a', 0, taskId: 'task-a'),
        answer('b', 1, taskId: 'task-b'),
      ]);
      expect(stop(), findsNWidgets(2));

      await tester.tap(stop().first);
      await tester.pump(const Duration(milliseconds: 100));

      expect(api.stoppedTasks, ['task-a']);
      final messages = container.read(chatMessagesProvider);
      expect(messages.firstWhere((m) => m.id == 'a').isStreaming, isFalse);
      // What it had streamed stays.
      expect(messages.firstWhere((m) => m.id == 'a').content, 'partial a');
      expect(messages.firstWhere((m) => m.id == 'b').isStreaming, isTrue);
      expect(api.stoppedTasks, isNot(contains('task-b')));
      // The sibling keeps its own control; the stopped answer lost it.
      expect(stop(), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('is offered to an admin with Advanced on as well', (
      tester,
    ) async {
      await pumpAnswers(tester, [
        answer('a', 0, taskId: 'task-a'),
        answer('b', 1, taskId: 'task-b'),
      ], advanced: true);
      expect(find.text(l10n.chatComparisonStopAnswerAction), findsNWidgets(2));
    });

    for (final advanced in [false, true]) {
      testWidgets('is never offered to a regular user, with Advanced '
          '${advanced ? 'on' : 'off'}', (tester) async {
        await pumpAnswers(
          tester,
          [answer('a', 0, taskId: 'task-a'), answer('b', 1, taskId: 'task-b')],
          advanced: advanced,
          user: _regular,
        );
        expect(find.text(l10n.chatComparisonStopAnswerAction), findsNothing);
      });
    }

    testWidgets('waits for the server before settling the answer', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (:api, :container) = await pumpAnswers(tester, [
        answer('a', 0, taskId: 'task-a'),
        answer('b', 1, taskId: 'task-b'),
      ]);
      final acknowledge = Completer<void>();
      api.hold = acknowledge;

      await tester.tap(stop().first);
      await tester.pump(const Duration(milliseconds: 100));
      expect(api.stoppedTasks, ['task-a']);
      expect(
        container.read(chatMessagesProvider).first.isStreaming,
        isTrue,
        reason: 'the server has not said the task stopped',
      );
      expect(stop(), findsNWidgets(2));

      acknowledge.complete();
      await tester.pump(const Duration(milliseconds: 100));
      expect(container.read(chatMessagesProvider).first.isStreaming, isFalse);
      expect(stop(), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a refused stop keeps the answer live and says so', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final (:api, :container) = await pumpAnswers(tester, [
        answer('a', 0, taskId: 'task-a'),
        answer('b', 1, taskId: 'task-b'),
      ]);
      api.failure = StateError('the server refused');

      await tester.tap(stop().first);
      await tester.pump(const Duration(milliseconds: 100));

      expect(api.stoppedTasks, ['task-a']);
      final messages = container.read(chatMessagesProvider);
      final a = messages.firstWhere((m) => m.id == 'a');
      expect(a.isStreaming, isTrue);
      expect(a.content, 'partial a');
      expect(a.metadata?['taskId'], 'task-a');
      expect(messages.firstWhere((m) => m.id == 'b').isStreaming, isTrue);
      expect(stop(), findsNWidgets(2));
      expect(find.text(l10n.errorMessage), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a refusal that arrives after the answer finished on its own '
        'says nothing', (tester) async {
      final semantics = tester.ensureSemantics();
      final (:api, :container) = await pumpAnswers(tester, [
        answer('a', 0, taskId: 'task-a'),
        answer('b', 1, taskId: 'task-b'),
      ]);
      final acknowledge = Completer<void>();
      api.hold = acknowledge;

      await tester.tap(stop().first);
      await tester.pump(const Duration(milliseconds: 100));
      container.read(chatMessagesProvider.notifier).finishSlotMessage('a');
      acknowledge.completeError(StateError('task is already gone'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(l10n.errorMessage), findsNothing);
      expect(container.read(chatMessagesProvider).first.isStreaming, isFalse);
      semantics.dispose();
    });

    testWidgets('is not offered before the server task is known, once the '
        'answer finished, or for an ordinary single answer', (tester) async {
      await pumpAnswers(tester, [
        answer('unbound', 0),
        answer('done', 1, taskId: 'task-done', streaming: false),
        answer('single', 0, taskId: 'task-single', comparison: false),
      ]);
      expect(find.text(l10n.chatComparisonStopAnswerAction), findsNothing);
    });
  });
}

class _AdvancedOn extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings(advancedFeaturesEnabled: true);
}

class _SeededMessages extends ChatMessagesNotifier {
  _SeededMessages(this.initial);

  final List<ChatMessage> initial;

  @override
  List<ChatMessage> build() => initial;
}

class _StopRecordingApi extends ApiService {
  _StopRecordingApi()
    : super(
        serverConfig: const ServerConfig(
          id: 'stop',
          name: 'stop',
          url: 'https://stop.example.test',
        ),
        workerManager: WorkerManager(),
      );

  final List<String> stoppedTasks = [];

  /// When set, the server acknowledges a stop only once this completes.
  Completer<void>? hold;

  /// When set, the server refuses every stop with this.
  Object? failure;

  @override
  Future<void> stopTask(String taskId) async {
    stoppedTasks.add(taskId);
    await hold?.future;
    final refusal = failure;
    if (refusal != null) throw refusal;
  }
}
