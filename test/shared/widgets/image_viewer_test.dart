import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:conduit/core/network/self_signed_image_cache_manager.dart';
import 'package:conduit/features/chat/widgets/enhanced_image_attachment.dart';
import 'package:conduit/core/services/image_attachment_cache_service.dart';
import 'package:conduit/features/navigation/widgets/responsive_drawer_layout.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer_canvas.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_ui/material_ui.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

class _ImageCacheManager extends Mock
    implements BaseCacheManager, ImageCacheManager {}

Widget _host(
  List<ImageViewerItem> items, {
  int initialIndex = 0,
  ValueNotifier<bool>? active,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ImageViewer(
              items: items,
              initialIndex: initialIndex,
              active: active,
            ),
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  ),
);

// Loading indicators can keep scheduling frames while the engine decodes.
// These tests assert navigation and request ownership, independent of decoding.
Future<void> _render(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('tapped duplicate keeps its custom request headers', (
    tester,
  ) async {
    const url = 'https://example.test/private.png';
    const headers = {'X-Image-Key': 'fixture-key'};
    final cache = _ImageCacheManager();
    when(
      () => cache.getImageFile(
        any(),
        key: any(named: 'key'),
        headers: any(named: 'headers'),
        maxWidth: any(named: 'maxWidth'),
        maxHeight: any(named: 'maxHeight'),
        withProgress: any(named: 'withProgress'),
      ),
    ).thenAnswer((_) => const Stream<FileResponse>.empty());
    Map<String, String>? requestedHeaders;
    when(
      () => cache.getFileStream(
        any(),
        key: any(named: 'key'),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((call) {
      requestedHeaders = call.namedArguments[#headers] as Map<String, String>?;
      return const Stream<FileResponse>.empty();
    });
    addTearDown(debugResetImageAttachmentCaches);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          selfSignedImageCacheManagerProvider.overrideWithValue(cache),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ImageAttachmentGallery(
              images: () => const [
                ImageAttachmentReference(url, label: 'Markdown'),
                ImageAttachmentReference(url, headers: headers),
              ],
              child: const Center(
                child: EnhancedImageAttachment(
                  attachmentId: url,
                  httpHeaders: headers,
                  disableAnimation: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _render(tester);
    await _render(tester);
    await tester.tap(find.byType(EnhancedImageAttachment));
    await _render(tester);
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(requestedHeaders?['X-Image-Key'], 'fixture-key');
  });

  testWidgets('gallery swipes stay above the app drawer', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    final epoch = Object();
    final scope = ImageAttachmentCacheScope(api: null, authSessionEpoch: epoch);
    for (final id in ['first', 'second']) {
      imageAttachmentCacheStore.cacheBytes(id, _pixel, scope: scope);
    }
    addTearDown(debugResetImageAttachmentCaches);
    var drawerOpened = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ResponsiveDrawerLayout(
            edgeFraction: 1,
            maxFraction: 1,
            onOpenStart: () => drawerOpened = true,
            drawer: const Text('App drawer'),
            child: Navigator(
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  body: ImageAttachmentGallery(
                    images: () => const [
                      ImageAttachmentReference('first', label: 'First'),
                      ImageAttachmentReference('second', label: 'Second'),
                    ],
                    child: const Center(
                      child: EnhancedImageAttachment(
                        attachmentId: 'second',
                        disableAnimation: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _render(tester);
    await _render(tester);
    await tester.tap(find.byType(EnhancedImageAttachment));
    await _render(tester);
    expect(find.text('2 of 2'), findsOneWidget);
    await tester.dragFrom(const Offset(100, 437), const Offset(230, 0));
    await _render(tester);
    expect(drawerOpened, isFalse);
    expect(find.text('1 of 2'), findsOneWidget);
    await tester.dragFrom(const Offset(320, 437), const Offset(-230, 0));
    await _render(tester);
    expect(find.text('2 of 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.byType(EnhancedImageAttachment), findsOneWidget);
  });

  test('gallery parsing handles long tokens and uses displayed Markdown', () {
    final content =
        '${'A' * 12000}![first](https://example.test/one.png)\n\n![second][ref]\n\n[ref]: https://example.test/two.png';
    final timer = Stopwatch()..start();
    final images = ImageAttachmentGallery.markdownImages(content);
    expect(images.map((image) => image.id), ['https://example.test/one.png']);
    expect(timer.elapsed, lessThan(const Duration(seconds: 1)));
  });

  testWidgets('visible thumbnail opens after its shared cache is evicted', (
    tester,
  ) async {
    final epoch = Object();
    final scope = ImageAttachmentCacheScope(api: null, authSessionEpoch: epoch);
    imageAttachmentCacheStore.cacheBytes('offline-image', _pixel, scope: scope);
    addTearDown(debugResetImageAttachmentCaches);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          openWebUiAuthSessionEpochProvider.overrideWithValue(epoch),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Center(
              child: EnhancedImageAttachment(
                attachmentId: 'offline-image',
                disableAnimation: true,
              ),
            ),
          ),
        ),
      ),
    );
    await _render(tester);
    await _render(tester);
    // Simulate bounded-cache eviction without changing the mounted owner.
    for (var i = 0; i < 100; i++) {
      imageAttachmentCacheStore.cacheBytes('other-$i', _pixel, scope: scope);
    }
    expect(
      imageAttachmentCacheStore.read('offline-image', scope: scope),
      isNull,
    );
    await tester.tap(find.byType(EnhancedImageAttachment));
    await _render(tester);
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(ImageViewer),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  testWidgets('zoom reset releases the enlarged decode target', (tester) async {
    await tester.pumpWidget(
      _host([
        ImageViewerItem(load: () async => ImageViewerMedia.bytes(_pixel)),
      ]),
    );
    await tester.tap(find.text('Open'));
    await _render(tester);
    ResizeImage provider() =>
        tester
                .widget<Image>(
                  find.descendant(
                    of: find.byType(ImageViewer),
                    matching: find.byType(Image),
                  ),
                )
                .image
            as ResizeImage;
    final fitted = provider().width!;
    final canvas = find.byType(ImageViewerCanvas);
    Future<void> doubleTap() async {
      await tester.tap(canvas);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(canvas);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    }

    await doubleTap();
    expect(provider().width, greaterThan(fitted));
    await doubleTap();
    expect(provider().width, fitted);
  });

  testWidgets(
    'starts at tapped image and loads other pages only on navigation',
    (tester) async {
      final loads = [0, 0, 0];
      await tester.pumpWidget(
        _host([
          for (var i = 0; i < 3; i++)
            ImageViewerItem(
              label: 'Photo $i',
              load: () async {
                loads[i]++;
                return ImageViewerMedia.bytes(_pixel);
              },
            ),
        ], initialIndex: 1),
      );
      await tester.tap(find.text('Open'));
      await _render(tester);
      check(loads).deepEquals([0, 1, 0]);
      expect(find.text('2 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Next image'));
      await _render(tester);
      check(loads).deepEquals([0, 1, 1]);
      expect(find.text('3 of 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Previous image'));
      await _render(tester);
      expect(find.text('2 of 3'), findsOneWidget);
    },
  );

  testWidgets('retry reloads a failed image and ignores a late previous page', (
    tester,
  ) async {
    final lateImage = Completer<ImageViewerMedia>();
    var attempts = 0;
    await tester.pumpWidget(
      _host([
        ImageViewerItem(load: () => lateImage.future),
        ImageViewerItem(
          label: 'Second',
          load: () async {
            if (++attempts == 1) throw StateError('Offline');
            return ImageViewerMedia.bytes(_pixel);
          },
        ),
      ]),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('Next image'));
    await _render(tester);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await _render(tester);
    lateImage.complete(ImageViewerMedia.bytes(_pixel));
    await _render(tester);
    check(attempts).equals(2);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets(
    'session invalidation closes a viewer before a pending image arrives',
    (tester) async {
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final pending = Completer<ImageViewerMedia>();
      await tester.pumpWidget(
        _host([ImageViewerItem(load: () => pending.future)], active: active),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      active.value = false;
      await _render(tester);
      pending.complete(ImageViewerMedia.bytes(_pixel));
      await _render(tester);
      expect(find.byType(ImageViewer), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
