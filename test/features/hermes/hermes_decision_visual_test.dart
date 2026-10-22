// Optional captures of the shipped Flutter controls, using synthetic requests.
// flutter test --update-goldens --dart-define=CAPTURE_HERMES_DECISIONS=true ...
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/features/hermes/widgets/hermes_approval_card.dart';
import 'package:conduit/features/hermes/widgets/hermes_approval_sheet.dart';
import 'package:conduit/features/hermes/widgets/hermes_decision_card.dart';
import 'package:conduit_core/features/hermes/models/hermes_run_event.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';

void main() {
  const capture = bool.fromEnvironment('CAPTURE_HERMES_DECISIONS');
  final command = List.generate(
    35,
    (i) => 'echo "Install dependencies and verify step $i"',
  ).join('\n');
  for (final dark in [false, true]) {
    for (final flow in ['approval', 'question']) {
      testWidgets('capture $flow ${dark ? 'dark' : 'light'}', (tester) async {
        final fonts = [
          ('Roboto', '/System/Library/Fonts/Supplemental/Arial.ttf'),
          ('monospace', '/System/Library/Fonts/Supplemental/Courier New.ttf'),
          (
            'MaterialIcons',
            '/Users/stephenbiele/.local/share/conduit-tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ];
        for (final font in fonts) {
          final loader = FontLoader(font.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(font.$2).readAsBytesSync()),
              ),
            );
          await loader.load();
        }
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const boundary = ValueKey('decision-capture');
        final theme = dark
            ? AppTheme.dark(TweakcnThemes.conduit)
            : AppTheme.light(TweakcnThemes.conduit);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: theme,
              debugShowCheckedModeBanner: false,
              localizationsDelegates: conduitLocalizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                appBar: AppBar(
                  title: const Text(
                    'Website refresh',
                    style: TextStyle(fontFamily: 'Roboto'),
                  ),
                ),
                body: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Align(
                      alignment: Alignment.centerRight,
                      child: Text('Install the website and check it.'),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'I’ll install dependencies and verify the build.',
                    ),
                    const SizedBox(height: 16),
                    if (flow == 'approval')
                      HermesApprovalSheetLauncher(
                        builder: (context) => HermesApprovalCard(
                          state: HermesApprovalState.pending,
                          summary: command,
                          choices: const ['once', 'session', 'always', 'deny'],
                          onChoice: (_) {},
                          onDecision: (_) {},
                          onDismiss: () => Navigator.of(context).pop(),
                        ),
                      )
                    else
                      HermesDecisionCard(
                        kind: HermesDecisionKind.clarification,
                        prompt: 'What should the homepage emphasize?',
                        onSubmit: (_) async => true,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(boundary),
          matchesGoldenFile(
            '../../../.impeccable/review/$flow-${dark ? 'dark' : 'light'}-flutter.png',
          ),
        );
      }, skip: !capture);
    }
  }
}
