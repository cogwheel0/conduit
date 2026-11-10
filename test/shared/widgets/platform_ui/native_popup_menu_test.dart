import 'dart:async';

import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNPopupMenuDivider, CNPopupMenuSubmenu, CNPopupMenuSubmenuStyle;
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

void main() {
  setUp(() {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 27;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Widget host(Widget child) => ProviderScope(
    child: MaterialApp(
      localizationsDelegates: conduitLocalizationsDelegates,
      builder: (context, child) => LegacyDesignCompatibility(child: child!),
      home: Scaffold(
        body: Material(
          type: MaterialType.transparency,
          child: Center(child: child),
        ),
      ),
    ),
  );

  testWidgets('native icon menus receive the human-readable action label', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AdaptivePopupMenuButton.icon<int>(
          icon: 'ellipsis',
          semanticLabel: 'More sketch actions',
          items: const [AdaptivePopupMenuItem<int>(label: 'Export', value: 7)],
          onSelected: (_, _) {},
        ),
      ),
    );
    final menu = tester.widget<CNPopupMenuButton>(
      find.byType(CNPopupMenuButton),
    );
    expect(menu.semanticLabel, 'More sketch actions');
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('native menu dividers retain original values and disabled rows', (
    tester,
  ) async {
    int? index;
    int? value;
    await tester.pumpWidget(
      host(
        AdaptivePopupMenuButton.text<int>(
          label: 'More actions',
          items: const [
            AdaptivePopupMenuItem<int>(label: 'Keep', value: 41, checked: true),
            AdaptivePopupMenuDivider(),
            AdaptivePopupMenuItem<int>(
              label: 'Unavailable',
              value: 99,
              enabled: false,
            ),
            AdaptivePopupMenuItem<int>(label: 'Export', value: 7),
          ],
          onSelected: (selectedIndex, entry) {
            index = selectedIndex;
            value = entry.value;
          },
        ),
      ),
    );
    final menu = tester.widget<CNPopupMenuButton>(
      find.byType(CNPopupMenuButton),
    );
    expect(menu.items, hasLength(4));
    expect(menu.items[0], isA<CNPopupMenuItem>());
    expect((menu.items[0] as CNPopupMenuItem).checked, isTrue);
    expect((menu.items[0] as CNPopupMenuItem).enabled, isTrue);
    expect(menu.items[1], isA<CNPopupMenuDivider>());
    expect((menu.items[2] as CNPopupMenuItem).enabled, isFalse);
    expect((menu.items[3] as CNPopupMenuItem).label, 'Export');
    // A flat menu keeps the system's order: first item nearest the button.
    expect(menu.preserveTopToBottomOrder, isFalse);
    menu.onSelected!(3);
    expect(index, 3);
    expect(value, 7);
    menu.onSelected!(1);
    menu.onSelected!(2);
    menu.onSelected!(99);
    expect(value, 7);
    menu.onSelected!(0);
    expect(value, 41);
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  const sectionedItems = [
    AdaptivePopupMenuSection<int>(
      style: AdaptivePopupMenuSectionStyle.palette,
      items: [
        AdaptivePopupMenuItem<int>(label: 'Copy', icon: 'doc.on.doc', value: 1),
        AdaptivePopupMenuItem<int>(
          label: 'Share',
          icon: 'square.and.arrow.up',
          value: 2,
        ),
      ],
    ),
    AdaptivePopupMenuSection<int>(
      items: [
        AdaptivePopupMenuItem<int>(label: 'Info', value: 3),
        AdaptivePopupMenuItem<int>(
          label: 'Unavailable',
          value: 4,
          enabled: false,
        ),
      ],
    ),
    AdaptivePopupMenuItem<int>(label: 'Delete', value: 5, isDestructive: true),
  ];

  testWidgets('sections become native palette and inline groups', (
    tester,
  ) async {
    final chosen = <(int, int?)>[];
    await tester.pumpWidget(
      host(
        AdaptivePopupMenuButton.icon<int>(
          icon: 'ellipsis',
          semanticLabel: 'More',
          items: sectionedItems,
          onSelected: (index, entry) => chosen.add((index, entry.value)),
        ),
      ),
    );
    final menu = tester.widget<CNPopupMenuButton>(
      find.byType(CNPopupMenuButton),
    );
    final palette = menu.items[0] as CNPopupMenuSubmenu;
    final inline = menu.items[1] as CNPopupMenuSubmenu;
    expect(palette.style, CNPopupMenuSubmenuStyle.palette);
    expect(inline.style, CNPopupMenuSubmenuStyle.inline);
    // Untitled, so neither draws a header; VoiceOver reads each palette icon
    // by its item's label.
    expect([palette.label, inline.label], ['', '']);
    expect(
      [
        for (final item in palette.items.cast<CNPopupMenuItem>())
          (item.label, item.icon?.name),
      ],
      [('Copy', 'doc.on.doc'), ('Share', 'square.and.arrow.up')],
    );
    expect((menu.items[2] as CNPopupMenuItem).isDestructive, isTrue);
    // Opening upward does not move the palette to the bottom.
    expect(menu.preserveTopToBottomOrder, isTrue);

    menu.onPathSelected!([0, 1]);
    menu.onPathSelected!([1, 1]);
    menu.onPathSelected!([1, 7]);
    menu.onPathSelected!([0]);
    menu.onPathSelected!([2]);
    expect(chosen, [(0, 2), (2, 5)]);
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Flutter menus list sections in place between dividers', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.android;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    final chosen = <(int, int?)>[];
    await tester.pumpWidget(
      host(
        AdaptivePopupMenuButton.icon<int>(
          icon: Icons.more_horiz,
          semanticLabel: 'More',
          items: sectionedItems,
          onSelected: (index, entry) => chosen.add((index, entry.value)),
        ),
      ),
    );

    Future<void> choose(String label) async {
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    final rows = ['Copy', 'Share', 'Info', 'Unavailable', 'Delete'];
    final tops = [for (final row in rows) tester.getTopLeft(find.text(row)).dy];
    expect(tops, orderedEquals([...tops]..sort()));
    final divider = find.byType(PopupMenuDivider);
    final dividers = [
      for (var i = 0; i < divider.evaluate().length; i++)
        tester.getCenter(divider.at(i)).dy,
    ];
    expect(dividers, hasLength(2));
    expect(dividers[0], inExclusiveRange(tops[1], tops[2]));
    expect(dividers[1], inExclusiveRange(tops[3], tops[4]));
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await choose('Share');
    await choose('Delete');
    expect(chosen, [(0, 2), (2, 5)]);
  });

  group('menus around a widget', () {
    const triggerKey = Key('sample-menu-trigger');
    final dropdown = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.conduit.NativeDropdownHostApi.show',
      NativeDropdownHostApi.pigeonChannelCodec,
    );
    final requests = <PlatformDropdownRequest>[];
    final haptics = <Object?>[];
    late List<Object?> reply;

    TestDefaultBinaryMessenger messenger() =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      requests.clear();
      haptics.clear();
      reply = [null];
      messenger().setMockDecodedMessageHandler<Object?>(dropdown, (
        message,
      ) async {
        requests.add(
          (message! as List<Object?>).single! as PlatformDropdownRequest,
        );
        return reply;
      });
      messenger().setMockMethodCallHandler(SystemChannels.platform, (
        call,
      ) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add(call.arguments);
        }
        return null;
      });
    });

    tearDown(() {
      messenger().setMockDecodedMessageHandler<Object?>(dropdown, null);
      messenger().setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Widget menu(
      List<AdaptivePopupMenuEntry> items,
      void Function(int, AdaptivePopupMenuItem<String>) onSelected, {
      bool triggerOnLongPress = false,
    }) => host(
      AdaptivePopupMenuButton.widget<String>(
        items: items,
        onSelected: onSelected,
        triggerOnLongPress: triggerOnLongPress,
        child: const ColoredBox(
          key: triggerKey,
          color: Color(0x00000000),
          child: SizedBox(width: 120, height: 44),
        ),
      ),
    );

    for (final longPress in [false, true]) {
      testWidgets('open the system menu over the widget '
          '(${longPress ? 'long press' : 'tap'})', (tester) async {
        final selections = <(int, String?)>[];
        await tester.pumpWidget(
          menu(
            const [
              AdaptivePopupMenuItem<String>(
                label: 'Preview',
                value: 'preview',
                icon: CupertinoIcons.eye,
              ),
              AdaptivePopupMenuDivider(),
              AdaptivePopupMenuItem<String>(
                label: 'Everyone',
                subtitle: 'Anyone with an account',
                value: 'everyone',
                icon: 'globe',
                checked: true,
              ),
              AdaptivePopupMenuItem<String>(
                label: 'Erase',
                value: 'erase',
                icon: 'trash',
                isDestructive: true,
                enabled: false,
              ),
            ],
            (index, entry) => selections.add((index, entry.value)),
            triggerOnLongPress: longPress,
          ),
        );
        reply = ['2'];

        if (longPress) {
          await tester.longPress(find.byKey(triggerKey));
        } else {
          await tester.tap(find.byKey(triggerKey));
        }
        await tester.pumpAndSettle();

        final request = requests.single;
        final trigger = tester.getRect(find.byKey(triggerKey));
        expect(
          [
            request.sourceRect!.x,
            request.sourceRect!.y,
            request.sourceRect!.width,
            request.sourceRect!.height,
          ],
          [trigger.left, trigger.top, trigger.width, trigger.height],
        );
        expect(request.cancelLabel, 'Cancel');
        expect(
          [
            for (final option in request.options)
              (
                option.id,
                option.label,
                option.subtitle,
                option.sfSymbol,
                option.enabled,
                option.destructive,
              ),
          ],
          [
            ('0', 'Preview', null, 'eye', true, false),
            // A checked item shows the check in place of its icon.
            (
              '2',
              'Everyone',
              'Anyone with an account',
              'checkmark',
              true,
              false,
            ),
            ('3', 'Erase', null, 'trash', false, true),
          ],
        );
        expect(selections, [(2, 'everyone')]);
        expect(haptics, ['HapticFeedbackType.selectionClick']);
        expect(find.byType(CupertinoActionSheet), findsNothing);
      }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
    }

    testWidgets('a dismissed system menu selects nothing', (tester) async {
      final selections = <int>[];
      await tester.pumpWidget(
        menu(const [
          AdaptivePopupMenuItem<String>(label: 'Preview'),
        ], (index, _) => selections.add(index)),
      );

      await tester.tap(find.byKey(triggerKey));
      await tester.pumpAndSettle();

      expect(requests, hasLength(1));
      expect(selections, isEmpty);
      expect(find.byType(CupertinoActionSheet), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('an item the system menu cannot show keeps the Flutter menu', (
      tester,
    ) async {
      final selections = <int>[];
      await tester.pumpWidget(
        menu([
          const AdaptivePopupMenuItem<String>(label: 'Preview'),
          AdaptivePopupMenuItem<String>(
            label: 'Sample avatar',
            imageBytes: _transparentPixel,
          ),
        ], (index, _) => selections.add(index)),
      );

      await tester.tap(find.byKey(triggerKey));
      await tester.pumpAndSettle();

      expect(requests, isEmpty);
      expect(find.byType(CupertinoActionSheet), findsOneWidget);
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(selections, [0]);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets(
      'a system menu that fails to open falls back to the Flutter menu',
      (tester) async {
        final selections = <int>[];
        await tester.pumpWidget(
          menu(const [
            AdaptivePopupMenuItem<String>(label: 'Preview'),
          ], (index, _) => selections.add(index)),
        );
        reply = ['PRESENTATION_FAILED', 'Synthetic host detached', null];

        await tester.tap(find.byKey(triggerKey));
        await tester.pumpAndSettle();

        expect(requests, hasLength(1));
        expect(find.byType(CupertinoActionSheet), findsOneWidget);
        await tester.tap(find.text('Preview'));
        await tester.pumpAndSettle();
        expect(selections, [0]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );

    testWidgets(
      "an error from the chosen item's handler is not taken for a failed menu",
      (tester) async {
        await tester.pumpWidget(
          menu(const [
            AdaptivePopupMenuItem<String>(label: 'Preview'),
          ], (_, _) => throw StateError('Synthetic handler failure')),
        );
        reply = ['0'];
        // The menu opens from the tap, so its error surfaces in this zone.
        final errors = <Object>[];
        await runZonedGuarded(() async {
          await tester.tap(find.byKey(triggerKey));
          await tester.pumpAndSettle();
        }, (error, _) => errors.add(error));

        expect(requests, hasLength(1));
        expect(errors, [isStateError]);
        expect(find.byType(CupertinoActionSheet), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  });
}

/// A 1x1 transparent PNG.
final _transparentPixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00,
  0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
