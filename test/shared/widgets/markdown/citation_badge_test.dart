import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/markdown/citation_badge.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Settings extends AppSettingsNotifier {
  @override
  AppSettings build() => const AppSettings();

  void transparent() => state = state.copyWith(citationBackground: false);
}

const _sources = [
  ChatSourceReference(title: 'Brass guide', url: 'https://brass.example/guide'),
  ChatSourceReference(
    title: 'Joint guide',
    url: 'https://joints.example/guide',
  ),
];

void main() {
  for (final dark in [false, true]) {
    testWidgets('single and grouped citations react to background preference '
        'in ${dark ? 'dark' : 'light'} mode without moving text', (
      tester,
    ) async {
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(_Settings.new)],
      );
      addTearDown(container.dispose);
      var tapped = false;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: dark
                ? AppTheme.dark(TweakcnThemes.conduit)
                : AppTheme.light(TweakcnThemes.conduit),
            home: Scaffold(
              body: Column(
                children: [
                  CitationBadge(
                    sourceIndex: 0,
                    sources: _sources,
                    onTap: () => tapped = true,
                  ),
                  const CitationBadgeGroup(
                    sourceIndices: [0, 1],
                    sources: _sources,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final label = find.text('brass.example').first;
      final theme = tester.element(label).conduitTheme;
      List<BoxDecoration> decorations() => tester
          .widgetList<Container>(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.decoration is BoxDecoration,
            ),
          )
          .map((widget) => widget.decoration! as BoxDecoration)
          .toList();
      expect(
        decorations().where(
          (box) =>
              box.color ==
              theme.surfaceContainerHighest.withValues(alpha: 0.95),
        ),
        hasLength(2),
      );
      expect(
        tester.widget<Text>(label).style?.fontSize,
        AppTypography.labelSmall,
      );
      final position = tester.getRect(label);

      (container.read(appSettingsProvider.notifier) as _Settings).transparent();
      await tester.pump();
      expect(
        decorations().every((box) => box.color == Colors.transparent),
        isTrue,
      );
      expect(tester.getRect(label), position);
      await tester.tap(label);
      expect(tapped, isTrue);
      await tester.tap(find.text('+1'));
      await tester.pumpAndSettle();
      expect(find.text('joints.example'), findsOneWidget);
    });
  }
}
