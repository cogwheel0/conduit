import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(
          buildImageViewerRoute(
            context,
            items: items,
            initialIndex: initialIndex,
            active: active,
          ),
        ),
        child: const Text('Open'),
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
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (staged() == null) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Native image viewer did not open');
    }
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  return staged()!;
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
    expect(find.byType(ImageViewer), findsOneWidget);

    dismissed.complete();
    await _finishExport(tester, previewFile);
    expect(await tester.runAsync(previewFile.exists), false);
    expect(find.byType(ImageViewer), findsNothing);
    expect(find.text('Open'), findsOneWidget);
    expect(dismissCount, 0);
  }, variant: _ios);

  testWidgets('native preview leaves sibling images reachable', (tester) async {
    await tester.pumpWidget(_host(items()));
    final previewFile = await _open(tester, () => staged);
    expect(loads, [1]);
    dismissed.complete();
    await _finishExport(tester, previewFile);
    expect(find.byType(ImageViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Previous image'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, [1, 0]);
    expect(openCount, 1);
    expect(find.text('1 of 2'), findsOneWidget);
  }, variant: _ios);

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
}
