import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/ask_conduit_context_menu.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Exercises native Copy and Ask Conduit through a real SelectionArea.
void main() {
  const channel = MethodChannel('app.cogwheel.conduit/text_selection_menu');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pointer anchors do not require selection endpoint glyphs', (
    tester,
  ) async {
    Widget? menu;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () {
                  menu = buildAskConduitSelectionAreaContextMenu(
                    selectableRegionState: _PointerRegion(context),
                    ref: ref,
                    selectedText: null,
                    composerTargetId: null,
                  );
                },
                child: const Text('Open pointer menu'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open pointer menu'));
    expect(tester.takeException(), isNull);
    final native = menu! as AdaptiveTextSelectionMenu;
    expect(native.selectionRect.contains(const Offset(100, 100)), isTrue);
    expect(native.selectionRect.isEmpty, isFalse);
    expect(native.buttonItems.single.type, ContextMenuButtonType.selectAll);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  for (final action in ['Copy', 'Ask Conduit']) {
    testWidgets('iOS response selection keeps the native $action action', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      final result = Completer<int?>();
      String? clipboard;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'show' ? result.future : null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      String? selected;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(supportsShowingSystemContextMenu: true),
              child: child!,
            ),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => SelectionArea(
                  onSelectionChanged: (content) =>
                      selected = content?.plainText,
                  contextMenuBuilder: (_, region) =>
                      buildAskConduitSelectionAreaContextMenu(
                        selectableRegionState: region,
                        ref: ref,
                        selectedText: selected,
                        composerTargetId: 'synthetic-composer',
                      ),
                  child: const Text('A paper bridge spans a narrow stream.'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(
        find.text('A paper bridge spans a narrow stream.'),
      );
      await tester.pump();
      final show = calls.where((call) => call.method == 'show');
      expect(show, hasLength(1));
      expect(selected, isNotEmpty);
      final labels = (show.single.arguments as Map)['labels'] as List;
      expect(labels, contains('Copy'));
      expect(labels, contains('Select All'));
      expect(labels, contains('Ask Conduit'));
      result.complete(labels.indexOf(action));
      await tester.pump();
      if (action == 'Copy') {
        expect(clipboard, selected);
      } else {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(SelectionArea)),
        );
        final insertion = container.read(composerTextInsertionProvider);
        expect(insertion?.targetId, 'synthetic-composer');
        expect(insertion?.text, selected);
      }
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
  }
}

/// A pointer menu can have a tap anchor before both selection endpoints exist.
class _PointerRegion extends Fake
    with Diagnosticable
    implements SelectableRegionState {
  _PointerRegion(this.context);

  @override
  final BuildContext context;

  @override
  TextSelectionToolbarAnchors get contextMenuAnchors =>
      const TextSelectionToolbarAnchors(primaryAnchor: Offset(100, 100));

  @override
  List<ContextMenuButtonItem> get contextMenuButtonItems => [
    ContextMenuButtonItem(
      type: ContextMenuButtonType.selectAll,
      onPressed: () {},
    ),
  ];

  @override
  double get startGlyphHeight => throw StateError('No start endpoint');

  @override
  double get endGlyphHeight => throw StateError('No end endpoint');
}
