import 'package:conduit/features/terminal/widgets/terminal_clipboard_actions.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('terminal clipboard actions', () {
    late List<MethodCall> platformCalls;
    String? clipboardText;

    setUp(() {
      platformCalls = <MethodCall>[];
      clipboardText = null;
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            platformCalls.add(call);
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': clipboardText};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets(
      'copy with no selection surfaces a snackbar and writes nothing',
      (tester) async {
        final terminal = Terminal();
        final controller = TerminalController();
        final context = await _pumpContext(tester);

        await copyTerminalSelection(context, terminal, controller);
        await tester.pump();

        expect(find.text('Nothing selected to copy'), findsOneWidget);
        expect(
          platformCalls.where((c) => c.method == 'Clipboard.setData'),
          isEmpty,
        );
      },
    );

    testWidgets('copy with a selection writes to the clipboard and clears it', (
      tester,
    ) async {
      final terminal = Terminal()..resize(80, 24);
      terminal.write('hello world');
      final controller = TerminalController();
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(5, 0),
      );
      final expected = terminal.buffer.getText(controller.selection!);

      final context = await _pumpContext(tester);
      await copyTerminalSelection(context, terminal, controller);
      await tester.pump();

      final setData = platformCalls.firstWhere(
        (c) => c.method == 'Clipboard.setData',
      );
      expect((setData.arguments as Map)['text'], expected);
      expect(controller.selection, isNull);
      expect(find.text('Copied to clipboard'), findsOneWidget);
    });

    testWidgets(
      'paste while disconnected surfaces a snackbar and does not paste',
      (tester) async {
        final outputs = <String>[];
        final terminal = Terminal(onOutput: outputs.add);
        clipboardText = 'echo hi';
        final context = await _pumpContext(tester);

        await pasteIntoTerminal(context, terminal, connected: false);
        await tester.pump();

        expect(find.text('Connect to paste'), findsOneWidget);
        expect(outputs, isEmpty);
      },
    );

    testWidgets('paste while connected sends clipboard text to the terminal', (
      tester,
    ) async {
      final outputs = <String>[];
      final terminal = Terminal(onOutput: outputs.add);
      clipboardText = 'echo hi';
      final context = await _pumpContext(tester);

      await pasteIntoTerminal(context, terminal, connected: true);
      await tester.pump();

      expect(outputs.join(), contains('echo hi'));
    });
  });
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return captured;
}
