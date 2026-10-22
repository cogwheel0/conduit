import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('search fields announce their name once after typing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(TweakcnThemes.conduit),
          home: Scaffold(
            body: CompactSearchField(hint: 'Search files', onChanged: (_) {}),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'report');
      await tester.pump();
      expect(
        tester.getSemantics(find.byType(EditableText)),
        isSemantics(label: 'Search files', isTextField: true, value: 'report'),
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('compact actions expose names and Android touch targets', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(TweakcnThemes.conduit),
        home: Scaffold(
          body: Column(
            children: [
              CompactIconAction(
                icon: const Icon(Icons.add),
                tooltip: 'New chat',
                extent: 40,
                onPressed: () {},
              ),
              CompactActionBubble(
                label: 'Copy answer',
                icon: Icons.copy,
                onPressed: () {},
              ),
              CompactActionBubble(label: 'Change Reasoning', onPressed: () {}),
              CompactDisclosureSection(
                title: 'Skills',
                icon: Icons.category,
                child: const Text('Details'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byType(CompactActionBubble).first),
      isSemantics(
        label: 'Copy answer',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.text('Skills')),
      isSemantics(
        label: 'Skills',
        isButton: true,
        hasExpandedState: true,
        isExpanded: false,
      ),
    );
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    semantics.dispose();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'selection grid supports ${brightness.name} with text scale $scale',
        (tester) async {
          final semantics = tester.ensureSemantics();

          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark
                  ? AppTheme.dark(TweakcnThemes.conduit)
                  : AppTheme.light(TweakcnThemes.conduit),
              home: Scaffold(
                body: MediaQuery(
                  data: MediaQueryData(
                    size: const Size(390, 844),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: CompactSelectionGrid<String>(
                    title: 'Choose your provider',
                    choices: const [
                      CompactMenuChoice(
                        'openrouter',
                        'OpenRouter',
                        selected: true,
                      ),
                      CompactMenuChoice('anthropic', 'Anthropic'),
                      CompactMenuChoice('custom', 'Custom endpoint'),
                    ],
                    onSelected: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            tester.getSemantics(find.text('OpenRouter')),
            isSemantics(isSelected: true, isButton: true),
          );
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          semantics.dispose();
        },
      );
    }
  }
}
