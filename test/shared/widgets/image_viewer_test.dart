import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/widgets/image_viewer/image_viewer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
);

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
