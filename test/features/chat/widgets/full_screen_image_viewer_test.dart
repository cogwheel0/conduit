import 'dart:convert';

import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
const _first = 'data:image/png;base64,$_pngBase64';
const _second = 'data:image/png;name=second;base64,$_pngBase64';
// 2×1 pixels, so the fitted image is shorter than the screen.
const _widePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4z8AARAAI/gH/xp559wAAAABJRU5ErkJggg==';
const _wide = 'data:image/png;name=wide;base64,$_widePngBase64';

void main() {
  setUp(() {
    debugResetImageAttachmentCaches();
    final bytes = base64.decode(_pngBase64);
    preCacheImageBytes(_first, bytes);
    preCacheImageBytes(_second, bytes);
    preCacheImageBytes(_wide, base64.decode(_widePngBase64));
  });
  tearDown(debugResetImageAttachmentCaches);

  Future<void> pumpBubble(
    WidgetTester tester, {
    List<String> urls = const [_first, _second],
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final message = ChatMessage(
      id: 'user-images',
      role: 'user',
      content: '',
      timestamp: DateTime.utc(2026, 10, 2),
      files: [
        for (final url in urls) <String, dynamic>{'type': 'image', 'url': url},
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: UserMessageBubble(
                message: message,
                isUser: true,
                onDelete: () {},
              ),
            ),
          ),
        ),
      ),
    );
    // Thumbnails load from the seeded cache after the first frames.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a message thumbnail opens a pager over its sibling images', (
    tester,
  ) async {
    await pumpBubble(tester);
    final thumbnails = find.byType(EnhancedImageAttachment);
    expect(thumbnails, findsNWidgets(2));

    await tester.tap(thumbnails.at(1));
    await settle(tester);

    expect(find.byType(FullScreenImageViewer), findsOneWidget);
    expect(find.text('2 of 2'), findsOneWidget);

    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await settle(tester);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging an unzoomed image down dismisses the viewer', (
    tester,
  ) async {
    await pumpBubble(tester);
    await tester.tap(find.byType(EnhancedImageAttachment).first);
    await settle(tester);
    expect(find.byType(FullScreenImageViewer), findsOneWidget);

    await tester.drag(
      find.byType(InteractiveViewer).first,
      const Offset(0, 60),
    );
    await settle(tester);
    expect(
      find.byType(FullScreenImageViewer),
      findsOneWidget,
      reason: 'a short drag springs back',
    );

    await tester.drag(
      find.byType(InteractiveViewer).first,
      const Offset(0, 300),
    );
    await settle(tester);
    expect(find.byType(FullScreenImageViewer), findsNothing);
  });

  testWidgets('the opening flight ends on the fitted image, fully opaque', (
    tester,
  ) async {
    await pumpBubble(tester, urls: const [_wide]);
    // Let the thumbnail decode so the viewer knows the image's aspect ratio.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    await tester.tap(find.byType(EnhancedImageAttachment));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 240));

    // Near the end of the flight the thumbnail keeps the image's 2:1 shape
    // instead of stretching toward the full screen, and is not faded.
    final shuttle = find
        .descendant(of: find.byType(Overlay), matching: find.byType(ClipRRect))
        .last;
    final flying = tester.getSize(shuttle);
    expect(flying.width, greaterThan(300));
    expect(flying.width / flying.height, closeTo(2, 0.05));
    final fades = find
        .ancestor(of: shuttle, matching: find.byType(FadeTransition))
        .evaluate()
        .map((e) => (e.widget as FadeTransition).opacity.value);
    expect(fades.where((opacity) => opacity < 0.99), isEmpty);

    await settle(tester);
    final viewerHero = find.descendant(
      of: find.byType(FullScreenImageViewer),
      matching: find.byType(Hero),
    );
    expect(tester.getSize(viewerHero), const Size(400, 200));
    expect(tester.takeException(), isNull);
  });
}
