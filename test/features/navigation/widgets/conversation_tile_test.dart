import 'package:conduit/features/navigation/widgets/conversation_tile.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unread conversations show the dot and a semibold title', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Unread chat',
          pinned: false,
          selected: false,
          unread: true,
          isLoading: false,
          onTap: null,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('conversation-unread-indicator')),
      findsOneWidget,
    );
    // In one ink the dot alone is easy to miss, so weight marks unread too.
    final title = tester.widget<Text>(find.text('Unread chat'));
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(title.semanticsLabel, 'Unread chat\nUnread');
  });

  testWidgets('read or selected conversations do not show unread indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Read chat',
          pinned: false,
          selected: true,
          unread: false,
          isLoading: false,
          onTap: null,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('conversation-unread-indicator')),
      findsNothing,
    );
    // Selection is carried by the row fill; read titles stay regular.
    final title = tester.widget<Text>(find.text('Read chat'));
    expect(title.style?.fontWeight, FontWeight.w400);
  });

  testWidgets(
    'unselected conversations paint a neutral surface while pressed',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          ConversationTile(
            title: 'Press me',
            pinned: false,
            selected: false,
            isLoading: false,
            onTap: () {},
          ),
        ),
      );

      const pressedKey = ValueKey<String>('conversation-tile-pressed-tint');
      expect(find.byKey(pressedKey), findsNothing);

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Press me')),
      );
      await tester.pump(kSidebarRowPressDelay);

      final pressedSurface = tester.widget<DecoratedBox>(
        find.byKey(pressedKey),
      );
      final decoration = pressedSurface.decoration as BoxDecoration;
      final theme = tester.element(find.text('Press me')).conduitTheme;
      expect(
        decoration.color,
        sidebarRowHighlightColor(theme, selected: false, pressed: true),
      );

      await gesture.up();
      await tester.pump();
      expect(find.byKey(pressedKey), findsNothing);
    },
  );

  testWidgets('selected tint takes precedence over pressed feedback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        ConversationTile(
          title: 'Selected chat',
          pinned: false,
          selected: true,
          isLoading: false,
          onTap: () {},
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Selected chat')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('conversation-tile-active-tint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('conversation-tile-pressed-tint')),
      findsNothing,
    );

    await gesture.cancel();
  });

  testWidgets('chat-style sidebar rows stay flat until pressed', (
    tester,
  ) async {
    const pressedKey = ValueKey<String>('shared-row-pressed');
    await tester.pumpWidget(
      _harness(
        ChatStyleSidebarTile(
          selected: false,
          onTap: () {},
          pressedKey: pressedKey,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Flat row'),
          ),
        ),
      ),
    );

    expect(find.byType(DecoratedBox), findsNothing);
    final outer = tester.widget<Container>(
      find
          .ancestor(of: find.text('Flat row'), matching: find.byType(Container))
          .first,
    );
    expect(outer.margin, kConversationTileMargin);

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Flat row')),
    );
    await tester.pump();
    // Like a UIKit list, a resting finger highlights after a beat, so a row
    // a scroll starts from never flashes.
    expect(find.byKey(pressedKey), findsNothing);
    await tester.pump(kSidebarRowPressDelay);
    expect(find.byKey(pressedKey), findsOneWidget);

    await gesture.cancel();
    await tester.pump();
    expect(find.byKey(pressedKey), findsNothing);
  });

  testWidgets('a quick tap still flashes the row highlight', (tester) async {
    const pressedKey = ValueKey<String>('tap-row-pressed');
    var taps = 0;
    await tester.pumpWidget(
      _harness(
        ChatStyleSidebarTile(
          selected: false,
          onTap: () => taps++,
          pressedKey: pressedKey,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Tap row'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Tap row'));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(pressedKey), findsOneWidget);

    await tester.pump(kSidebarRowTapFlash);
    expect(find.byKey(pressedKey), findsNothing);
  });

  testWidgets('a row the finger scrolls from never highlights', (tester) async {
    const pressedKey = ValueKey<String>('scroll-row-pressed');
    await tester.pumpWidget(
      _harness(
        ChatStyleSidebarTile(
          selected: false,
          onTap: () {},
          pressedKey: pressedKey,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Scroll row'),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Scroll row')),
    );
    await gesture.moveBy(const Offset(0, kTouchSlop + 4));
    await tester.pump(kSidebarRowPressDelay * 2);
    expect(find.byKey(pressedKey), findsNothing);

    await gesture.up();
    await tester.pump(kSidebarRowTapFlash);
    expect(find.byKey(pressedKey), findsNothing);
  });

  test('row highlights are neutral and a press reads stronger', () {
    for (final theme in [
      AppTheme.light(TweakcnThemes.t3Chat).extension<ConduitThemeExtension>()!,
      AppTheme.dark(TweakcnThemes.t3Chat).extension<ConduitThemeExtension>()!,
    ]) {
      final selected = sidebarRowHighlightColor(theme, selected: true);
      final pressed = sidebarRowHighlightColor(
        theme,
        selected: false,
        pressed: true,
      );
      // A wash of the text colour over the surface, not an accent.
      expect(
        selected,
        Color.alphaBlend(
          theme.textPrimary.withValues(alpha: theme.isDark ? 0.13 : 0.08),
          theme.surfaceBackground,
        ),
      );
      double contrast(Color color) =>
          (color.computeLuminance() -
                  theme.surfaceBackground.computeLuminance())
              .abs();
      expect(contrast(pressed), greaterThan(contrast(selected)));
      expect(contrast(selected), greaterThan(0));
    }
  });

  testWidgets('the unread dot leads its title on the content edge and '
      'pushes the title in', (tester) async {
    await tester.pumpWidget(
      _harness(
        const Column(
          children: [
            ConversationTile(
              title: 'Unread chat',
              pinned: false,
              selected: false,
              unread: true,
              isLoading: false,
              onTap: null,
            ),
            ConversationTile(
              title: 'Read chat',
              pinned: false,
              selected: false,
              isLoading: false,
              onTap: null,
            ),
          ],
        ),
      ),
    );

    expect(
      tester.getTopLeft(find.text('Read chat')).dx,
      kSidebarRowContentInset,
    );
    final dot = tester.getRect(
      find.byKey(const ValueKey<String>('conversation-unread-indicator')),
    );
    expect(dot.left, kSidebarRowContentInset);
    expect(
      tester.getTopLeft(find.text('Unread chat')).dx,
      dot.right + Spacing.sm,
    );
    final titleCenter = tester.getCenter(find.text('Unread chat')).dy;
    expect(dot.center.dy, closeTo(titleCenter, 0.5));
  });

  testWidgets('chat-style sidebar rows highlight under a mouse pointer', (
    tester,
  ) async {
    final previousStrategy = FocusManager.instance.highlightStrategy;
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy = previousStrategy,
    );
    const pressedKey = ValueKey<String>('shared-row-hover');
    await tester.pumpWidget(
      _harness(
        ChatStyleSidebarTile(
          selected: false,
          onTap: () {},
          pressedKey: pressedKey,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Hover row'),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Hover row')));
    await tester.pump();
    expect(find.byKey(pressedKey), findsOneWidget);

    await mouse.moveTo(const Offset(799, 599));
    await tester.pump();
    expect(find.byKey(pressedKey), findsNothing);
    await mouse.removePointer();
  });

  testWidgets('focused sidebar rows activate with Enter and Space', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      _harness(
        ChatStyleSidebarTile(
          selected: false,
          onTap: () => activations++,
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Keyboard row'),
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);

    expect(activations, 2);
  });

  testWidgets('selected sidebar rows keep the 4.0.3 Hermes edge gutter', (
    tester,
  ) async {
    const hostKey = ValueKey<String>('sidebar-row-host');
    const tintKey = ValueKey<String>('sidebar-row-tint');
    await tester.pumpWidget(
      _harness(
        SizedBox(
          key: hostKey,
          width: 320,
          child: ChatStyleSidebarTile(
            selected: true,
            onTap: () {},
            tintKey: tintKey,
            child: const SizedBox(height: TouchTarget.listItem),
          ),
        ),
      ),
    );

    final hostRect = tester.getRect(find.byKey(hostKey));
    final tintRect = tester.getRect(find.byKey(tintKey));
    expect(tintRect.left - hostRect.left, Spacing.sm);
    expect(hostRect.right - tintRect.right, Spacing.sm);
  });

  testWidgets('inactive sidebar rows keep the 4.0.3 Hermes edge gutter', (
    tester,
  ) async {
    const hostKey = ValueKey<String>('inactive-sidebar-row-host');
    const contentKey = ValueKey<String>('inactive-sidebar-row-content');
    await tester.pumpWidget(
      _harness(
        SizedBox(
          key: hostKey,
          width: 320,
          child: ChatStyleSidebarTile(
            selected: false,
            onTap: () {},
            child: const SizedBox(
              key: contentKey,
              height: TouchTarget.listItem,
              width: double.infinity,
            ),
          ),
        ),
      ),
    );

    final hostRect = tester.getRect(find.byKey(hostKey));
    final contentRect = tester.getRect(find.byKey(contentKey));
    expect(contentRect.left - hostRect.left, Spacing.sm);
    expect(hostRect.right - contentRect.right, Spacing.sm);
  });

  testWidgets('generating conversations show a spinner', (tester) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Generating chat',
          pinned: false,
          selected: false,
          unread: false,
          isLoading: false,
          isGenerating: true,
          onTap: null,
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('conversation-generating-indicator')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a chat waiting for approval shows a hand, not a spinner', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _localizedHarness(
        const ConversationTile(
          title: 'Paused chat',
          pinned: false,
          selected: false,
          unread: false,
          isLoading: false,
          isGenerating: true,
          isAwaitingApproval: true,
          onTap: null,
        ),
      ),
    );

    final indicator = find.byKey(
      const ValueKey<String>('conversation-approval-indicator'),
    );
    expect(indicator, findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(of: indicator, matching: find.byType(Tooltip)),
    );
    expect(tooltip.message, 'Waiting for approval');
    // The row reads its title and that it waits.
    expect(
      find.bySemanticsLabel(
        RegExp('Paused chat.*Waiting for approval', dotAll: true),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('tap-load spinner takes precedence over generating spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Loading chat',
          pinned: false,
          selected: false,
          unread: false,
          isLoading: true,
          isGenerating: true,
          onTap: null,
        ),
      ),
    );

    // Only one spinner, and it is not keyed as the generating indicator.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('conversation-generating-indicator')),
      findsNothing,
    );
  });

  testWidgets('long provenance badges stay compact and truncate', (
    tester,
  ) async {
    const badge = 'A very long direct connection profile name';

    await tester.pumpWidget(
      _harness(
        const ConversationTile(
          title: 'Direct chat',
          pinned: false,
          selected: false,
          isLoading: false,
          badge: badge,
          onTap: null,
        ),
      ),
    );

    final badgeText = tester.widget<Text>(find.text(badge));
    expect(badgeText.maxLines, 1);
    expect(badgeText.overflow, TextOverflow.ellipsis);
    expect(tester.getSize(find.text(badge)).width, lessThanOrEqualTo(104));
    expect(tester.takeException(), isNull);
  });
  group('when a chat last changed', () {
    const stampKey = ValueKey<String>('conversation-updated-stamp');
    final now = DateTime.now();
    // Always today, whenever the test runs.
    final earlyToday = DateTime(now.year, now.month, now.day, 0, 1);

    final stampText = find.descendant(
      of: find.byKey(stampKey),
      matching: find.byType(Text),
    );

    testWidgets('ends the row on the title baseline, after a cut title', (
      tester,
    ) async {
      const title =
          'A chat title long enough that it has to stop before the time';
      await tester.pumpWidget(
        _harness(
          SizedBox(
            width: 360,
            child: ConversationTile(
              title: title,
              pinned: false,
              selected: false,
              unread: true,
              isLoading: false,
              timestamp: earlyToday,
              onTap: null,
            ),
          ),
        ),
      );

      final stamp = stampText;
      expect(tester.widget<Text>(stamp).data, matches(RegExp(r'^12:01\sAM$')));
      final titleFinder = find.text(title);
      expect(tester.widget<Text>(titleFinder).overflow, TextOverflow.ellipsis);
      final theme = tester.element(stamp).conduitTheme;
      expect(tester.widget<Text>(stamp).style?.color, theme.textSecondary);
      // The title stops a gap short of the date, which keeps the trailing
      // edge every row's content ends on.
      final titleRect = tester.getRect(titleFinder);
      final stampRect = tester.getRect(stamp);
      expect(stampRect.left - titleRect.right, closeTo(Spacing.sm, 0.01));
      final row = tester.getRect(find.byType(ConversationTile));
      expect(
        row.right - stampRect.right,
        closeTo(kSidebarRowContentInset, 0.01),
      );
      // The smaller date takes the title's line as its strut, so in the
      // centred row both have one line box, and so one baseline.
      final strut = tester.widget<Text>(stamp).strutStyle!;
      final titleStyle = tester.widget<Text>(titleFinder).style!;
      expect(strut.forceStrutHeight, isTrue);
      expect(strut.fontSize, titleStyle.fontSize);
      expect(strut.height, titleStyle.height);
      expect(stampRect.height, closeTo(titleRect.height, 0.01));
      expect(stampRect.center.dy, closeTo(titleRect.center.dy, 0.01));
    });

    testWidgets('follows the device 24-hour setting', (tester) async {
      await tester.pumpWidget(
        _harness(
          MediaQuery(
            data: const MediaQueryData(alwaysUse24HourFormat: true),
            child: ConversationTile(
              title: 'Night owl',
              pinned: false,
              selected: false,
              isLoading: false,
              timestamp: earlyToday,
              onTap: null,
            ),
          ),
        ),
      );
      expect(tester.widget<Text>(stampText).data, '00:01');
    });

    testWidgets('VoiceOver reads the title, its state, then the date', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          _harness(
            ConversationTile(
              title: 'Old chat',
              pinned: false,
              selected: false,
              unread: true,
              isLoading: false,
              timestamp: DateTime(2020, 1, 15, 10),
              onTap: () {},
            ),
          ),
        );

        expect(tester.widget<Text>(stampText).data, '1/15/20');
        expect(
          find.bySemanticsLabel('Old chat\nUnread\nJanuary 15, 2020'),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('gives way to the spinner while the chat works', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          ConversationTile(
            title: 'Busy chat',
            pinned: false,
            selected: false,
            isLoading: false,
            isGenerating: true,
            timestamp: earlyToday,
            onTap: null,
          ),
        ),
      );
      expect(find.byKey(stampKey), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('drops under the title at the accessibility text sizes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SizedBox(
              width: 360,
              child: ConversationTile(
                title: 'Large type',
                pinned: false,
                selected: false,
                unread: true,
                isLoading: false,
                timestamp: earlyToday,
                onTap: null,
              ),
            ),
          ),
        ),
      );

      final titleRect = tester.getRect(find.text('Large type'));
      final stampRect = tester.getRect(find.byKey(stampKey));
      expect(stampRect.top, greaterThanOrEqualTo(titleRect.bottom - 0.01));
      expect(stampRect.left, closeTo(titleRect.left, 0.01));
      // The unread dot stays on the title's line, not between the two.
      final dot = tester.getRect(
        find.byKey(const ValueKey<String>('conversation-unread-indicator')),
      );
      expect(dot.center.dy, closeTo(titleRect.center.dy, 0.5));
      expect(tester.takeException(), isNull);
    });
  });
}

Widget _localizedHarness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}

Widget _harness(Widget child) {
  return MaterialApp(
    theme: AppTheme.light(TweakcnThemes.t3Chat),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}
