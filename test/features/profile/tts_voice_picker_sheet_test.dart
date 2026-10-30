import 'package:conduit/core/utils/tts_voice_utils.dart';
import 'package:conduit/features/profile/widgets/tts_voice_picker_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:conduit/shared/widgets/adaptive_selection_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

const voices = <Map<String, dynamic>>[
  {
    'id': 'maple',
    'name': 'Maple',
    'locale': 'en-US',
    'languageName': 'English',
  },
  {'id': 'iris', 'name': 'Iris', 'locale': 'fr-FR', 'languageName': 'French'},
  {'id': 'reed', 'name': 'Reed', 'locale': 'fr-FR', 'languageName': 'French'},
];

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'language pill filters voices and combines with search on ${platform.name}',
      (tester) async {
        PlatformUiCapabilities.debugPlatformOverride = platform;
        PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
        addTearDown(PlatformUiCapabilities.resetDebugOverrides);
        String? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            localizationsDelegates: conduitLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Choose voice'),
                  onPressed: () async {
                    result = await showAdaptiveSelectionSheet<String>(
                      context: context,
                      builder: (context) => TtsVoicePickerSheet(
                        voices: buildTtsVoiceOptions(
                          AppLocalizations.of(context)!,
                          TtsEngine.server,
                          voices,
                        ),
                        selectedId: 'maple',
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Choose voice'));
        await tester.pumpAndSettle();
        final pill = find.byKey(const Key('tts-voice-language-filter'));
        final search = find.byKey(const Key('tts-voice-search'));
        expect(find.text('All languages'), findsOneWidget);
        expect(find.text('Maple'), findsOneWidget);
        expect(find.text('Iris'), findsOneWidget);
        expect(
          tester.getBottomLeft(pill).dy,
          lessThanOrEqualTo(tester.getTopLeft(search).dy),
        );
        expect(tester.getTopLeft(search).dy, greaterThan(400));
        await tester.tap(pill);
        await tester.pumpAndSettle();
        await tester.tap(find.text('French').last);
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(find.text('Maple'), findsNothing);
        expect(find.text('Iris'), findsOneWidget);
        expect(find.text('Reed'), findsOneWidget);
        expect(find.text('System default'), findsOneWidget);
        await tester.enterText(
          find.descendant(of: search, matching: find.byType(EditableText)),
          'IRIS',
        );
        await tester.pumpAndSettle();
        expect(find.text('Iris'), findsOneWidget);
        expect(find.text('Reed'), findsNothing);
        expect(find.text('System default'), findsNothing);
        await tester.tap(pill);
        await tester.pumpAndSettle();
        await tester.tap(find.text('All languages').last);
        await tester.pumpAndSettle();
        expect(find.text('Iris'), findsOneWidget);
        expect(
          find.text('Maple'),
          findsNothing,
        ); // The search query stays active.
        await tester.enterText(
          find.descendant(of: search, matching: find.byType(EditableText)),
          '',
        );
        await tester.pumpAndSettle();
        expect(find.text('Maple'), findsOneWidget);
        await tester.tap(find.text('Iris'));
        await tester.pumpAndSettle();
        expect(result, 'iris');
        await tester.tap(find.text('Choose voice'));
        await tester.pumpAndSettle();
        expect(find.text('All languages'), findsOneWidget);
        expect(find.text('Maple'), findsOneWidget);
      },
    );
  }
}
