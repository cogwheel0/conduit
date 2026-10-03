import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat/services/native_image_viewer_bridge.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/features/chat/widgets/user_message_bubble.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

const _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';
const _first = 'data:image/png;base64,$_pngBase64';
const _second = 'data:image/png;name=second;base64,$_pngBase64';
// 2×1 pixels, so the fitted image is shorter than the screen.
const _widePngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAADUlEQVR4nGP4z8AARAAI/gH/xp559wAAAABJRU5ErkJggg==';
const _wide = 'data:image/png;name=wide;base64,$_widePngBase64';
const _broken = 'data:image/png;name=broken;base64,!!!';

class _MockViewerApi extends Mock implements NativeImageViewerHostApi {}

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

  group('on iOS', () {
    late _MockViewerApi viewerApi;
    late NativeImageViewerBridge originalBridge;

    setUpAll(() {
      registerFallbackValue(
        PlatformImageViewerRequest(items: const [], initialIndex: 0),
      );
    });

    setUp(() {
      viewerApi = _MockViewerApi();
      when(() => viewerApi.present(any())).thenAnswer((_) async {});
      originalBridge = NativeImageViewerBridge.instance;
      NativeImageViewerBridge.instance = NativeImageViewerBridge.forTesting(
        viewerApi: viewerApi,
        isIOS: true,
      );
    });
    tearDown(() => NativeImageViewerBridge.instance = originalBridge);

    /// Serves a real temporary directory to path_provider.
    void mockTemporaryDirectory(WidgetTester tester) {
      final temp = Directory.systemTemp.createTempSync('viewer_test');
      addTearDown(() => temp.deleteSync(recursive: true));
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => temp.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
    }

    /// Taps a thumbnail and lets the real file writes finish.
    Future<void> tapAndPrepare(WidgetTester tester, Finder thumbnail) async {
      await tester.tap(thumbnail);
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await settle(tester);
    }

    testWidgets('opens Quick Look when every page is ready', (tester) async {
      mockTemporaryDirectory(tester);
      await pumpBubble(tester);
      await tapAndPrepare(tester, find.byType(EnhancedImageAttachment).at(1));

      final request =
          verify(() => viewerApi.present(captureAny())).captured.single
              as PlatformImageViewerRequest;
      expect(request.items.length, 2);
      expect(request.initialIndex, 1);
      expect(find.byType(FullScreenImageViewer), findsNothing);
    });

    testWidgets('prepares a gallery larger than the batch size', (
      tester,
    ) async {
      mockTemporaryDirectory(tester);
      final urls = [
        for (var i = 0; i < 5; i++)
          'data:image/png;name=p$i;base64,$_pngBase64',
      ];
      for (final url in urls) {
        preCacheImageBytes(url, base64.decode(_pngBase64));
      }
      await pumpBubble(tester, urls: urls);
      await tapAndPrepare(tester, find.byType(EnhancedImageAttachment).at(3));

      final request =
          verify(() => viewerApi.present(captureAny())).captured.single
              as PlatformImageViewerRequest;
      expect(request.items.length, 5);
      expect(request.initialIndex, 3);
    });

    testWidgets('falls back to the Flutter viewer when files cannot be '
        'written', (tester) async {
      // No path_provider handler, so creating the session directory throws.
      await pumpBubble(tester);
      await tapAndPrepare(tester, find.byType(EnhancedImageAttachment).at(1));

      verifyNever(() => viewerApi.present(any()));
      expect(find.byType(FullScreenImageViewer), findsOneWidget);
      expect(find.text('2 of 2'), findsOneWidget);
    });

    testWidgets('keeps a failed sibling as a page in the Flutter viewer', (
      tester,
    ) async {
      mockTemporaryDirectory(tester);
      await pumpBubble(tester, urls: const [_first, _broken]);
      await tapAndPrepare(tester, find.byType(EnhancedImageAttachment).first);

      verifyNever(() => viewerApi.present(any()));
      expect(find.text('1 of 2'), findsOneWidget);
    });
  });
}
