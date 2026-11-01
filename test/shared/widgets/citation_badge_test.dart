import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:conduit/shared/widgets/markdown/citation_badge.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<void> host(WidgetTester tester, ValueChanged<int> onSelected) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsProvider.overrideWith(_Settings.new)],
          child: MaterialApp(
            home: Scaffold(
              body: CitationBadgeGroup(
                sourceIndices: const [2, -1, 0],
                sources: const [
                  ChatSourceReference(
                    title: 'Paper shapes',
                    url: 'https://paper.example',
                  ),
                  ChatSourceReference(
                    title: 'Color study',
                    url: 'https://color.example',
                  ),
                  ChatSourceReference(
                    title: 'Fold guide',
                    url: 'https://fold.example',
                  ),
                ],
                onSourceTap: onSelected,
              ),
            ),
          ),
        ),
      );

  testWidgets(
    'iOS citation choices preserve source values with no false selection',
    (tester) async {
      PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
      int? selected;
      await host(tester, (value) => selected = value);
      final trigger = tester.widget<AdaptiveSingleChoiceTrigger<int>>(
        find.byType(AdaptiveSingleChoiceTrigger<int>),
      );
      expect(trigger.value, isNull);
      expect(trigger.options.map((option) => option.value), [2, 0]);
      expect(
        adaptiveSingleChoiceResultForId(
          selectedId: '0',
          options: trigger.options,
        )?.value,
        2,
      );
      expect(
        adaptiveSingleChoiceResultForId(
          selectedId: '1',
          options: trigger.options,
        )?.value,
        0,
      );
      expect(find.byType(PopupMenuButton<int>), findsNothing);
      expect(find.text('+2'), findsOneWidget);
      trigger.onChanged(0);
      expect(selected, 0);
    },
  );

  testWidgets('Android citations retain their popup, ordering and callback', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    int? selected;
    await host(tester, (value) => selected = value);
    final popup = tester.widget<PopupMenuButton<int>>(
      find.byType(PopupMenuButton<int>),
    );
    final entries = popup
        .itemBuilder(tester.element(find.byType(PopupMenuButton<int>)))
        .cast<PopupMenuItem<int>>();
    expect(entries.map((entry) => entry.value), [2, 0]);
    popup.onSelected!(2);
    expect(selected, 2);
    expect(find.byType(AdaptiveSingleChoiceTrigger<int>), findsNothing);
  });
}
