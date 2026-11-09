import 'package:conduit/features/chat/services/voice_input_service.dart';
import 'package:conduit/features/chat/widgets/modern_chat_input.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit_core/features/prompts/providers/prompts_providers.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart';

void main() {
  const mobilePlatforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });
  Future<void> pumpComposer(
    WidgetTester tester, {
    Size size = const Size(402, 874),
    double textScale = 1,
    double keyboardHeight = 0,
    required List<String> sent,
  }) async {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          voiceInputAvailableProvider.overrideWith((ref) async => false),
          notesFeatureEnabledProvider.overrideWith(_NotesEnabled.new),
          promptsListProvider.overrideWith(
            (ref) async => [
              for (var i = 0; i < 20; i++)
                Prompt(
                  command: '/paper-$i',
                  title: 'Paper pattern $i',
                  content: 'Fold a card.',
                ),
            ],
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            resizeToAvoidBottomInset: !isAndroid,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ModernChatInput(
                bottomPadding: 0,
                managesSystemKeyboardInset: isAndroid,
                onSendMessage: sent.add,
                onFileAttachment: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byType(CupertinoTextField),
      defaultTargetPlatform == TargetPlatform.iOS
          ? findsOneWidget
          : findsNothing,
    );
    expect(
      find.byType(TextField),
      defaultTargetPlatform == TargetPlatform.iOS
          ? findsNothing
          : findsOneWidget,
    );
  }

  String draft(int lines) =>
      List.generate(lines, (i) => 'Paper sail marker ${i + 1}.').join('\n');

  Future<void> enterDraft(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(EditableText), text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('long drafts stop growing at eight visible text lines', (
    tester,
  ) async {
    await pumpComposer(tester, sent: []);
    await enterDraft(tester, draft(8));
    final eightLineSize = tester.getSize(find.byType(EditableText));
    await enterDraft(tester, draft(40));
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    expect(editable.size, eightLineSize);
    expect(
      editable.size.height,
      lessThanOrEqualTo(editable.preferredLineHeight * 8),
    );
    expect((editable.offset as ScrollPosition).maxScrollExtent, greaterThan(0));
    expect(tester.takeException(), isNull);
  }, variant: mobilePlatforms);

  testWidgets('suggestions yield height beside large text and a keyboard', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      size: const Size(320, 800),
      textScale: 2,
      keyboardHeight: 300,
      sent: [],
    );
    await enterDraft(tester, '/');
    expect(find.byKey(const ValueKey('prompt-overlay')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('primary-btn-send')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.text('Paper pattern 0'));
    await tester.pump();
    expect(find.byKey(const ValueKey('prompt-overlay')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: mobilePlatforms);

  testWidgets('landscape suggestions retain a full scaled editor line', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      size: const Size(874, 402),
      textScale: 2,
      keyboardHeight: 180,
      sent: [],
    );
    await enterDraft(tester, '/');
    final editable = tester
        .state<EditableTextState>(find.byType(EditableText))
        .renderEditable;
    expect(
      editable.size.height,
      greaterThanOrEqualTo(editable.preferredLineHeight),
    );
    expect(
      find.byKey(const ValueKey('primary-btn-send')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  }, variant: mobilePlatforms);

  for (final scenario in [
    (name: 'portrait', size: const Size(402, 874), scale: 1.0, keyboard: 0.0),
    (
      name: 'keyboard open',
      size: const Size(402, 874),
      scale: 1.0,
      keyboard: 340.0,
    ),
    (
      name: 'landscape',
      size: const Size(874, 402),
      scale: 1.0,
      keyboard: 180.0,
    ),
    (
      name: 'large text',
      size: const Size(320, 800),
      scale: 2.0,
      keyboard: 300.0,
    ),
  ]) {
    testWidgets(
      'scrolling a long draft keeps actions usable: ${scenario.name}',
      (tester) async {
        final sent = <String>[];
        await pumpComposer(
          tester,
          size: scenario.size,
          textScale: scenario.scale,
          keyboardHeight: scenario.keyboard,
          sent: sent,
        );
        final text = draft(40);
        await enterDraft(tester, text);
        final actions = find.byKey(const ValueKey('composer-expanded-buttons'));
        final initialRect = tester.getRect(actions);
        expect(
          initialRect.bottom,
          lessThanOrEqualTo(scenario.size.height - scenario.keyboard),
        );
        expect(
          find.byKey(const ValueKey('primary-btn-send')).hitTestable(),
          findsOneWidget,
        );
        final editable = tester
            .state<EditableTextState>(find.byType(EditableText))
            .renderEditable;
        final initialOffset = editable.offset.pixels;
        await tester.drag(find.byType(EditableText), const Offset(0, -120));
        await tester.pumpAndSettle();
        expect(editable.offset.pixels, greaterThan(initialOffset));
        final scrolledOffset = editable.offset.pixels;
        expect(tester.getRect(actions), initialRect);
        for (final key in [
          'composer-overflow-button',
          'create-draft-note-button',
          'primary-btn-send',
        ]) {
          expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
        }
        await tester.drag(find.byType(EditableText), const Offset(0, 120));
        await tester.pumpAndSettle();
        expect(editable.offset.pixels, lessThan(scrolledOffset));
        expect(tester.getRect(actions), initialRect);
        final position = editable.offset as ScrollPosition;
        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        final finalLine = editable.getBoxesForSelection(
          TextSelection(
            baseOffset: text.lastIndexOf('\n') + 1,
            extentOffset: text.length,
          ),
        );
        expect(finalLine, isNotEmpty);
        for (final box in finalLine) {
          expect(box.top, greaterThanOrEqualTo(0));
          expect(box.bottom, lessThanOrEqualTo(editable.size.height));
        }
        expect(tester.getRect(actions), initialRect);
        await tester.tap(find.byKey(const ValueKey('primary-btn-send')));
        await tester.pump();
        expect(sent, [text]);
        expect(tester.takeException(), isNull);
      },
      variant: mobilePlatforms,
    );
  }
}

class _NotesEnabled extends NotesFeatureEnabledNotifier {
  @override
  bool build() => true;
}
