import 'dart:async';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/utils/ask_conduit_context_menu.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Exercises native Copy and Ask Conduit through a real SelectionArea.
void main() {
  const channel = MethodChannel('app.cogwheel.conduit/text_selection_menu');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

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
