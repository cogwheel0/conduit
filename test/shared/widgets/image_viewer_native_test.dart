import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);
const _preview = MethodChannel('app.cogwheel.conduit/image_preview');
const _paths = MethodChannel('plugins.flutter.io/path_provider');

const _mobile = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});
const _ios = TargetPlatformVariant({TargetPlatform.iOS});

Widget _host(
  List<ImageViewerItem> items, {
  int initialIndex = 1,
  ValueNotifier<bool>? active,
  int? otherIndex,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => Scaffold(
      body: Column(
        children: [
          TextButton(
            onPressed: () => showImageViewer(
              context,
              items: items,
              initialIndex: initialIndex,
              active: active,
            ),
            child: const Text('Open'),
          ),
          if (otherIndex != null)
            TextButton(
              onPressed: () => showImageViewer(
                context,
                items: items,
                initialIndex: otherIndex,
              ),
              child: const Text('Open other'),
            ),
        ],
      ),
    ),
  ),
);

Future<File> _open(WidgetTester tester, File? Function() staged) async {
  await tester.tap(find.text('Open'));
  return _waitForPreview(tester, staged);
}

Future<File> _waitForPreview(
  WidgetTester tester,
  File? Function() staged,
) async {
  await _waitUntil(tester, () => staged() != null);
  return staged()!;
}

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Image preview operation did not complete');
    }
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
}

Future<void> _finishExport(
  WidgetTester tester,
  File staged, {
  bool retained = false,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  await tester.pump();
  while (!retained && await tester.runAsync(staged.parent.exists) == true) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Preview staging file was not removed');
    }
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temporary;
  File? staged;
  late Completer<void> dismissed;
  late List<int> loads;
  late int openCount;
  late int dismissCount;
  late bool failPreview;

  List<ImageViewerItem> items() => [
    for (var index = 0; index < 2; index++)
      ImageViewerItem(
        label: 'Image $index',
        load: () async {
          loads.add(index);
          return ImageViewerMedia.bytes(_pixel);
        },
      ),
  ];

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'conduit_native_preview_',
    );
    staged = null;
    dismissed = Completer<void>();
    loads = [];
    openCount = 0;
    dismissCount = 0;
    failPreview = false;
    messenger.setMockMethodCallHandler(_paths, (_) async => temporary.path);
    messenger.setMockMethodCallHandler(_preview, (call) async {
      if (call.method == 'open') {
        openCount++;
        staged = File((call.arguments as Map)['path'] as String);
        if (failPreview) throw PlatformException(code: 'unsupported');
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          await dismissed.future;
        }
      } else if (call.method == 'dismiss') {
        dismissCount++;
        if (!dismissed.isCompleted) dismissed.complete();
      }
      return null;
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(_preview, null);
    messenger.setMockMethodCallHandler(_paths, null);
    await temporary.delete(recursive: true);
  });

  testWidgets('single image opens natively and returns to its origin', (
    tester,
  ) async {
    await tester.pumpWidget(_host([items()[1]], initialIndex: 0));
    final previewFile = await _open(tester, () => staged);
    expect(loads, [1]);
    expect(openCount, 1);
    expect(await tester.runAsync(previewFile.readAsBytes), _pixel);
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byTooltip('Quick Look'), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(Navigator.of(tester.element(find.text('Open'))).canPop(), false);

    dismissed.complete();
    await _finishExport(tester, previewFile);
    expect(await tester.runAsync(previewFile.exists), false);
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(dismissCount, 0);
  }, variant: _ios);

  testWidgets(
    'Quick Look opens only the tapped image without a Flutter route',
    (tester) async {
      await tester.pumpWidget(_host(items()));
      await tester.tap(find.text('Open'));
      await tester.pump();
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byTooltip('Quick Look'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      final previewFile = await _waitForPreview(tester, () => staged);
      expect(loads, [1]);
      expect(find.byType(ImageViewer), findsNothing);
      expect(await tester.runAsync(previewFile.readAsBytes), _pixel);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(dismissCount, 0);
      await tester.tap(find.text('Open'));
      await tester.pump();
      expect(loads, [1]);
      expect(openCount, 1);
      dismissed.complete();
      await _finishExport(tester, previewFile);
      expect(await tester.runAsync(previewFile.exists), false);
      expect(find.byType(ImageViewer), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(openCount, 1);
    },
    variant: _ios,
  );

  for (final invalidateOwner in [false, true]) {
    testWidgets(
      invalidateOwner
          ? 'owner change cancels a pending native image load'
          : 'selected staging failure reveals the usable Flutter gallery',
      (tester) async {
        final active = ValueNotifier(true);
        addTearDown(active.dispose);
        final pending = Completer<ImageViewerMedia>();
        final gallery = items();
        gallery[0] = ImageViewerItem(
          load: () {
            loads.add(0);
            return pending.future;
          },
        );
        await tester.pumpWidget(
          _host(gallery, initialIndex: 0, active: active),
        );
        await tester.tap(find.text('Open'));
        await _waitUntil(tester, () => loads.contains(0));
        expect(find.byTooltip('Quick Look'), findsNothing);
        if (invalidateOwner) active.value = false;
        pending.complete(
          ImageViewerMedia.bytes(
            invalidateOwner ? _pixel : base64Decode('AA=='),
          ),
        );
        await tester.pump();
        if (!invalidateOwner) {
          await _waitUntil(
            tester,
            () => find.byType(ImageViewer).evaluate().isNotEmpty,
          );
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(openCount, 0);
        expect(
          await tester.runAsync(() => temporary.list(recursive: true).toList()),
          isEmpty,
        );
        if (invalidateOwner) {
          expect(find.byType(ImageViewer), findsNothing);
          expect(find.text('Open'), findsOneWidget);
        } else {
          expect(find.byType(ImageViewer), findsOneWidget);
          expect(find.byType(Image), findsOneWidget);
          expect(find.byTooltip('Quick Look'), findsOneWidget);
          expect(find.text('1 of 2'), findsWidgets);
          await tester.tap(find.byTooltip('Next image'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(loads, [0, 1]);
          expect(find.text('2 of 2'), findsOneWidget);
        }
      },
      variant: _ios,
    );
  }

  testWidgets(
    'failed native preview falls back to the usable Flutter gallery',
    (tester) async {
      failPreview = true;
      await tester.pumpWidget(_host(items()));
      final previewFile = await _open(tester, () => staged);
      await _finishExport(tester, previewFile);

      expect(find.byType(ImageViewer), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.tap(find.byTooltip('Previous image'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(loads, [1, 0]);
      expect(openCount, 1);
      expect(find.text('1 of 2'), findsOneWidget);
    },
    variant: _ios,
  );

  testWidgets('Android uses the Flutter gallery until Open in is selected', (
    tester,
  ) async {
    await tester.pumpWidget(_host(items()));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(openCount, 0);
    expect(staged, isNull);

    await tester.tap(find.byTooltip('Previous image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, [1, 0]);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(openCount, 0);

    await tester.tap(find.byTooltip('Open in…'));
    final previewFile = await _waitForPreview(tester, () => staged);
    await _finishExport(tester, previewFile, retained: true);
    expect(openCount, 1);
    expect(await tester.runAsync(previewFile.readAsBytes), _pixel);
    expect(find.byType(ImageViewer), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));

  testWidgets('failed initial image leaves gallery paging available', (
    tester,
  ) async {
    final gallery = items();
    gallery[1] = ImageViewerItem(load: () async => throw StateError('Expired'));
    await tester.pumpWidget(_host(gallery));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.byTooltip('Previous image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, [0]);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(openCount, 0);
  }, variant: _mobile);

  testWidgets('owner invalidation dismisses automatic Quick Look once', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(_host(items(), active: active));
    final previewFile = await _open(tester, () => staged);

    active.value = false;
    await _finishExport(tester, previewFile);
    expect(dismissCount, 1);
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.text('Open'), findsOneWidget);
  }, variant: _ios);

  testWidgets('another image can replace a stalled native load', (
    tester,
  ) async {
    final pending = Completer<ImageViewerMedia>();
    final gallery = items();
    gallery[0] = ImageViewerItem(
      load: () {
        loads.add(0);
        return pending.future;
      },
    );
    await tester.pumpWidget(_host(gallery, initialIndex: 0, otherIndex: 1));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.tap(find.text('Open other'));
    await tester.pump();
    try {
      await _waitUntil(tester, () => loads.contains(1));
      expect(loads, [0, 1]);
      final previewFile = await _waitForPreview(tester, () => staged);
      pending.completeError(StateError('Replaced request failed later'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(openCount, 1);
      expect(find.byType(ImageViewer), findsNothing);
      dismissed.complete();
      await _finishExport(tester, previewFile);
      expect(
        await tester.runAsync(() => previewFile.parent.parent.list().toList()),
        isEmpty,
      );
    } finally {
      if (!pending.isCompleted) {
        pending.complete(ImageViewerMedia.bytes(_pixel));
      }
      if (!dismissed.isCompleted) dismissed.complete();
      await tester.pump();
    }
  }, variant: _ios);

  testWidgets('a stalled native load times out to a retryable gallery', (
    tester,
  ) async {
    final pending = Completer<ImageViewerMedia>();
    var attempts = 0;
    final gallery = items();
    gallery[0] = ImageViewerItem(
      load: () {
        attempts++;
        return pending.future;
      },
    );
    await tester.pumpWidget(_host(gallery, initialIndex: 0));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Retry'), findsOneWidget);
    expect(attempts, 1);
    expect(openCount, 0);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(attempts, 2);
    await tester.tap(find.byTooltip('Next image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, [1]);
    expect(find.byType(Image), findsOneWidget);
    pending.completeError(StateError('Timed-out request failed later'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(openCount, 0);
  }, variant: _ios);

  for (final navigation in ['go', 'push', 'pop']) {
    testWidgets(
      'Quick Look closes when its source route is left by $navigation',
      (tester) async {
        final gallery = items();
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('Destination')),
            ),
            GoRoute(
              path: '/source',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showImageViewer(context, items: gallery),
                  child: const Text('Open'),
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        unawaited(router.push('/source'));
        await tester.pumpAndSettle();
        final previewFile = await _open(tester, () => staged);
        switch (navigation) {
          case 'go':
            router.go('/');
          case 'push':
            unawaited(router.push('/'));
          case 'pop':
            router.pop();
        }
        await tester.pumpAndSettle();
        try {
          expect(dismissCount, 1);
          await _finishExport(tester, previewFile);
          expect(find.text('Destination'), findsOneWidget);
          expect(find.byType(ImageViewer), findsNothing);
        } finally {
          if (!dismissed.isCompleted) dismissed.complete();
          await tester.pump();
        }
      },
      variant: _ios,
    );
  }
}
