import 'dart:ui' show Tristate;

import 'package:conduit/features/chat/widgets/composer_overflow_menu.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Widget _harness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    home: Scaffold(
      body: Center(child: SizedBox(width: 72, child: child)),
    ),
  );
}

void main() {
  group('ComposerAttachmentKey', () {
    testWidgets('names the key beneath it, never inside it', (tester) async {
      await tester.pumpWidget(
        _harness(
          ComposerAttachmentKey(
            icon: Icons.folder,
            label: 'Server Files',
            onTap: () {},
          ),
        ),
      );

      final key = find.byKey(
        const ValueKey<String>('composer-attachment-key-fill'),
      );
      final keyRect = tester.getRect(key);
      final labelRect = tester.getRect(find.text('Server Files'));
      expect(labelRect.top, greaterThanOrEqualTo(keyRect.bottom));
      expect(keyRect.height, greaterThanOrEqualTo(44));
      // The whole tile, key and name, is at least a 44 pt target.
      expect(
        tester.getSize(find.byType(ComposerAttachmentKey)).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('darkens on touch-down and eases back on release', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _harness(
          ComposerAttachmentKey(
            icon: Icons.photo,
            label: 'Photo',
            onTap: () => taps++,
          ),
        ),
      );

      final fillFinder = find.byKey(
        const ValueKey<String>('composer-attachment-key-fill'),
      );
      double fillAlpha() =>
          ((tester.widget<AnimatedContainer>(fillFinder).decoration!
                      as ShapeDecoration)
                  .color!)
              .a;
      final rest = fillAlpha();
      // Flat, but never invisible: the key reads as a key at rest.
      expect(rest, greaterThan(0));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ComposerAttachmentKey)),
      );
      await tester.pump();
      expect(fillAlpha(), greaterThan(rest));
      expect(
        tester.widget<AnimatedContainer>(fillFinder).duration,
        Duration.zero,
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(fillAlpha(), rest);
      expect(taps, 1);
    });

    testWidgets(
      'an unavailable key is announced as disabled and ignores taps',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          _harness(
            const ComposerAttachmentKey(icon: Icons.public, label: 'Web'),
          ),
        );

        final data = tester
            .getSemantics(find.bySemanticsLabel('Web'))
            .getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.flagsCollection.isEnabled, Tristate.isFalse);
        semantics.dispose();
      },
    );
  });

  group('ToggleTile', () {
    testWidgets('an option shows its state with a switch', (tester) async {
      Future<void> pump({required bool selected}) {
        return tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(TweakcnThemes.t3Chat),
            home: Scaffold(
              body: Builder(
                builder: (context) => ToggleTile(
                  glyph: const Icon(Icons.auto_awesome),
                  title: 'Image Generation',
                  subtitle: 'Create images from your prompts.',
                  selected: selected,
                  onToggle: () {},
                  theme: context.conduitTheme,
                ),
              ),
            ),
          ),
        );
      }

      await pump(selected: false);
      expect(
        tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch)).value,
        isFalse,
      );

      await pump(selected: true);
      expect(
        tester.widget<AdaptiveSwitch>(find.byType(AdaptiveSwitch)).value,
        isTrue,
      );
    });

    testWidgets('a command shows a chevron and no switch', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Scaffold(
            body: Builder(
              builder: (context) => ToggleTile(
                glyph: const Icon(Icons.build_outlined),
                title: 'Tool Settings',
                selected: false,
                isAction: true,
                onToggle: () {},
                theme: context.conduitTheme,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(AdaptiveSwitch), findsNothing);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('tapping the switch itself toggles the row once', (
      tester,
    ) async {
      var toggles = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Scaffold(
            body: Builder(
              builder: (context) => ToggleTile(
                glyph: const Icon(Icons.search),
                title: 'Web Search',
                selected: false,
                onToggle: () => toggles++,
                theme: context.conduitTheme,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AdaptiveSwitch));
      await tester.pump();
      expect(toggles, 1);
    });
  });
}
