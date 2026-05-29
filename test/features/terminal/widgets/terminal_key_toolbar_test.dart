import 'package:conduit/features/terminal/widgets/terminal_key_toolbar.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('TerminalKeyToolbar', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      // Keep paste's clipboard read deterministic for the "enabled" checks.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, dynamic>{'text': ''};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('key taps route control codes to the terminal when connected', (
      tester,
    ) async {
      final outputs = <String>[];
      final terminal = Terminal(onOutput: outputs.add);
      await _pumpToolbar(tester, terminal: terminal, connected: true);

      const tab = '\t';
      final etx = String.fromCharCode(3); // Ctrl-C

      await tester.tap(find.text('Tab'));
      await tester.pump();
      expect(outputs, contains(tab));

      outputs.clear();
      await tester.tap(find.byIcon(Icons.block_rounded));
      await tester.pump();
      expect(outputs, contains(etx));
    });

    testWidgets('key taps are inert while disconnected', (tester) async {
      final outputs = <String>[];
      final terminal = Terminal(onOutput: outputs.add);
      await _pumpToolbar(tester, terminal: terminal, connected: false);

      await tester.tap(find.text('Tab'));
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
      await tester.tap(find.byIcon(Icons.block_rounded));
      await tester.pump();

      expect(outputs, isEmpty);
    });

    testWidgets('copy stays enabled while disconnected', (tester) async {
      final terminal = Terminal();
      await _pumpToolbar(tester, terminal: terminal, connected: false);

      // Copy is not gated on the connection; with no selection it surfaces the
      // "nothing to copy" snackbar, proving the button is still interactive.
      await tester.tap(find.byIcon(Icons.copy_rounded));
      await tester.pump();

      expect(find.text('Nothing selected to copy'), findsOneWidget);
    });
  });
}

Future<void> _pumpToolbar(
  WidgetTester tester, {
  required Terminal terminal,
  required bool connected,
}) async {
  final controller = TerminalController();
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: TerminalKeyToolbar(
          terminal: terminal,
          controller: controller,
          connected: connected,
        ),
      ),
    ),
  );
}
