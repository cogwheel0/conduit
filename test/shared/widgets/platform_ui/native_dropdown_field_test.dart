import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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

  Widget host(Widget child) => MaterialApp(
    builder: (context, child) => LegacyDesignCompatibility(child: child!),
    home: Scaffold(body: child),
  );

  for (final enabled in [true, false]) {
    testWidgets('empty native fields get a name (enabled: $enabled)', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          AdaptiveDropdownField<String>(
            value: null,
            options: const [
              AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
            ],
            onChanged: enabled ? (_) {} : null,
            decoration: const InputDecoration(labelText: 'Shape'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (enabled) {
        final button = tester.widget<CNPopupMenuButton>(
          find.byType(CNPopupMenuButton),
        );
        expect(button.buttonLabel, isEmpty);
        expect(button.semanticLabel, 'Shape');
      } else {
        final button = tester.widget<CNButton>(find.byType(CNButton));
        expect(button.label, isEmpty);
        expect(button.semanticLabel, 'Shape');
      }
      await tester.pumpWidget(
        host(
          AdaptiveDropdownField<String>(
            value: null,
            options: const [
              AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
            ],
            onChanged: enabled ? (_) {} : null,
            decoration: const InputDecoration(),
            semanticLabel: 'Request shape',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        enabled
            ? tester
                  .widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton))
                  .semanticLabel
            : tester.widget<CNButton>(find.byType(CNButton)).semanticLabel,
        'Request shape',
      );
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }

  testWidgets('native names identify fields and preserve visible labels', (
    tester,
  ) async {
    for (final enabled in [true, false]) {
      for (final (value, hint, name, expectedName)
          in <(String?, String, String?, String?)>[
            (null, 'Choose shape', 'Shape', 'Shape, Choose shape'),
            ('kite', 'Choose shape', 'Shape', 'Shape, Kite'),
            (null, 'Shape', 'Shape', 'Shape'),
            ('kite', 'Choose shape', null, null),
            ('kite', 'Choose shape', '', null),
          ]) {
        await tester.pumpWidget(
          host(
            AdaptiveDropdownField<String>(
              value: value,
              options: const [
                AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
              ],
              onChanged: enabled ? (_) {} : null,
              decoration: InputDecoration(hintText: hint),
              semanticLabel: name,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final visibleLabel = value == null ? hint : 'Kite';
        if (enabled) {
          final button = tester.widget<CNPopupMenuButton>(
            find.byType(CNPopupMenuButton),
          );
          expect(button.buttonLabel, visibleLabel);
          expect(button.semanticLabel, expectedName);
        } else {
          final button = tester.widget<CNButton>(find.byType(CNButton));
          expect(button.label, visibleLabel);
          expect(button.semanticLabel, expectedName);
        }
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('native choices preserve nullable values and checked state', (
    tester,
  ) async {
    final values = <String?>[];
    await tester.pumpWidget(
      host(
        AdaptiveDropdownField<String?>(
          value: 'kite',
          options: const [
            AdaptiveDropdownOption(value: null, label: 'None'),
            AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
            AdaptiveDropdownOption(
              value: 'boat',
              label: 'Boat',
              enabled: false,
            ),
          ],
          onChanged: values.add,
          decoration: const InputDecoration(labelText: 'Shape'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    var menu = tester.widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton));
    expect((menu.items[1] as CNPopupMenuItem).checked, isTrue);
    menu.onSelected(2);
    menu.onSelected(-1);
    menu.onSelected(9);
    expect(values, isEmpty);
    menu.onSelected(0);
    await tester.pumpAndSettle();
    expect(values, [null]);
    menu = tester.widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton));
    expect(menu.buttonLabel, 'None');
    expect((menu.items.first as CNPopupMenuItem).checked, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('disabled fields have no menu and reject an old callback', (
    tester,
  ) async {
    var enabled = true;
    var calls = 0;
    late StateSetter update;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AdaptiveDropdownField<String>(
              value: 'kite',
              options: const [
                AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
              ],
              onChanged: enabled ? (_) => calls++ : null,
              decoration: const InputDecoration(labelText: 'Shape'),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final menu = tester.widget<CNPopupMenuButton>(
      find.byType(CNPopupMenuButton),
    );
    update(() => enabled = false);
    await tester.pumpAndSettle();
    expect(find.byType(CNPopupMenuButton), findsNothing);
    final button = tester.widget<CNButton>(find.byType(CNButton));
    expect(button.enabled, isFalse);
    expect(button.onPressed, isNull);
    menu.onSelected(0);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    menu.onSelected(0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('native choices retain labels, hints and validation', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(
      host(
        Form(
          key: form,
          child: AdaptiveDropdownField<String>(
            value: null,
            options: const [
              AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
            ],
            onChanged: (_) {},
            validator: (value) => value == null ? 'Choose a shape' : null,
            decoration: const InputDecoration(
              labelText: 'Shape',
              hintText: 'Select shape',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Shape'), findsOneWidget);
    expect(
      tester
          .widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton))
          .buttonLabel,
      'Select shape',
    );
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Choose a shape'), findsOneWidget);
    tester
        .widget<CNPopupMenuButton>(find.byType(CNPopupMenuButton))
        .onSelected(0);
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    await tester.pumpAndSettle();
    // iOS Form schedules the validation announcement after a one-second delay.
    await tester.pump(const Duration(seconds: 1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('choices with descriptions retain the existing presentation', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AdaptiveDropdownField<String>(
          value: 'kite',
          options: const [
            AdaptiveDropdownOption(
              value: 'kite',
              label: 'Kite',
              subtitle: 'Paper shape',
            ),
          ],
          onChanged: (_) {},
          decoration: const InputDecoration(labelText: 'Shape'),
        ),
      ),
    );
    expect(find.byType(CNPopupMenuButton), findsNothing);
    expect(find.text('Kite'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
