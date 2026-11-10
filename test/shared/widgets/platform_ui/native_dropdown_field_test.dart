import 'dart:async';

import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/services.dart';
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

  CNPopUpButton<int> popUp(WidgetTester tester) =>
      tester.widget<CNPopUpButton<int>>(find.byType(CNPopUpButton<int>));

  // UIKit titles a pop-up button with the item whose value is selected.
  String shownLabel(CNPopUpButton<int> button) => button.items
      .whereType<CNPopUpButtonItem<int>>()
      .singleWhere((item) => item.value == button.value)
      .label;

  testWidgets('native names identify fields and show the choice or hint', (
    tester,
  ) async {
    for (final enabled in [true, false]) {
      for (final (value, decoration, name, expectedName)
          in <(String?, InputDecoration, String?, String?)>[
            (null, const InputDecoration(labelText: 'Shape'), null, 'Shape'),
            (null, const InputDecoration(), 'Request shape', 'Request shape'),
            (
              null,
              const InputDecoration(hintText: 'Choose shape'),
              'Shape',
              'Shape',
            ),
            (
              'kite',
              const InputDecoration(hintText: 'Choose shape'),
              'Shape',
              'Shape',
            ),
            ('kite', const InputDecoration(hintText: 'Choose shape'), '', null),
            ('kite', const InputDecoration(), null, null),
          ]) {
        await tester.pumpWidget(
          host(
            AdaptiveDropdownField<String>(
              value: value,
              options: const [
                AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
              ],
              onChanged: enabled ? (_) {} : null,
              decoration: decoration,
              semanticLabel: name,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final button = popUp(tester);
        // UIKit reads the name, then the shown choice as the value.
        expect(button.semanticLabel, expectedName);
        expect(
          shownLabel(button),
          value == null ? decoration.hintText ?? '' : 'Kite',
        );
        expect(button.onChanged == null, !enabled);
      }
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('native choices preserve nullable values and selection', (
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
    var button = popUp(tester);
    expect(shownLabel(button), 'Kite');
    expect(
      button.items.whereType<CNPopUpButtonItem<int>>().map((i) => i.enabled),
      [true, true, false],
    );
    button.onChanged!(2);
    button.onChanged!(-1);
    button.onChanged!(9);
    expect(values, isEmpty);
    button.onChanged!(0);
    await tester.pumpAndSettle();
    expect(values, [null]);
    button = popUp(tester);
    expect(shownLabel(button), 'None');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('disabled fields reject an old callback', (tester) async {
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
    final staleChange = popUp(tester).onChanged!;
    update(() => enabled = false);
    await tester.pumpAndSettle();
    expect(popUp(tester).onChanged, isNull);
    staleChange(0);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    staleChange(0);
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
    // The hint is the dimmed title item, so it can't be chosen back.
    final hint = popUp(tester).items.first as CNPopUpButtonItem<int>;
    expect((hint.label, hint.enabled), ('Select shape', false));
    expect(shownLabel(popUp(tester)), 'Select shape');
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Choose a shape'), findsOneWidget);
    popUp(tester).onChanged!(0);
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    expect(shownLabel(popUp(tester)), 'Kite');
    expect(
      popUp(tester).items
          .whereType<CNPopUpButtonItem<int>>()
          .map((i) => i.label),
      ['Kite'],
    );
    await tester.pumpAndSettle();
    // iOS Form schedules the validation announcement after a one-second delay.
    await tester.pump(const Duration(seconds: 1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  // In a Material dialog the field falls back to its own button, which
  // dropped the name a field gives only through `semanticLabel`.
  testWidgets('a field in a dialog keeps its accessible name', (tester) async {
    await tester.pumpWidget(
      host(
        AlertDialog(
          content: AdaptiveDropdownField<String>(
            value: 'kite',
            options: const [
              AdaptiveDropdownOption(value: 'kite', label: 'Kite'),
            ],
            onChanged: (_) {},
            decoration: const InputDecoration(),
            semanticLabel: 'Request shape',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CNPopUpButton<int>), findsNothing);
    expect(find.bySemanticsLabel(RegExp('Request shape')), findsOneWidget);
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
    expect(find.byType(CNPopUpButton<int>), findsNothing);
    expect(find.text('Kite'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  const sheetOptions = [
    AdaptiveDropdownOption(value: 'kite', label: 'Kite', subtitle: 'Paper'),
    AdaptiveDropdownOption(value: 'box', label: 'Box', subtitle: 'Wood'),
  ];

  // The sheet marked the value the field was built with, not the one it
  // shows after a choice its parent did not rebuild with.
  testWidgets('the sheet marks the choice the field shows', (tester) async {
    final sheet = _Sheet();
    addTearDown(sheet.dispose);
    await tester.pumpWidget(
      host(
        AdaptiveDropdownField<String>(
          value: 'kite',
          options: sheetOptions,
          onChanged: (_) {},
          decoration: const InputDecoration(labelText: 'Shape'),
        ),
      ),
    );
    sheet.answers.add('1');
    await tester.tap(find.text('Kite'));
    await tester.pumpAndSettle();
    expect(find.text('Box'), findsOneWidget);

    sheet.answers.add(null);
    await tester.tap(find.text('Box'));
    await tester.pumpAndSettle();
    expect(sheet.marked.last, ['box']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  // A choice made in a sheet that stayed open while its field was disabled
  // still changed the field and called its old callback.
  testWidgets('a field disabled while its sheet is open takes no choice', (
    tester,
  ) async {
    final sheet = _Sheet();
    addTearDown(sheet.dispose);
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
              options: sheetOptions,
              onChanged: enabled ? (_) => calls++ : null,
              decoration: const InputDecoration(labelText: 'Shape'),
            );
          },
        ),
      ),
    );
    final answer = Completer<String?>();
    sheet.pending = answer;
    await tester.tap(find.text('Kite'));
    await tester.pump();
    update(() => enabled = false);
    await tester.pump();
    answer.complete('1');
    await tester.pumpAndSettle();

    expect(calls, 0);
    expect(find.text('Kite'), findsOneWidget);
    expect(find.text('Box'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}

/// The native single-choice sheet: records which options it marked, and
/// answers each presentation from [answers] (or [pending]).
final class _Sheet {
  _Sheet() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockDecodedMessageHandler<Object?>(_channel, (message) async {
          final request = (message! as List<Object?>).single!
              as PlatformDropdownRequest;
          marked.add([
            for (final option in request.options)
              if (option.sfSymbol == 'checkmark') sheetValue(option.id),
          ]);
          final waiting = pending;
          pending = null;
          return [waiting != null ? await waiting.future : answers.removeAt(0)];
        });
  }

  static final _channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.conduit.NativeDropdownHostApi.show',
    NativeDropdownHostApi.pigeonChannelCodec,
  );

  final List<List<String>> marked = [];
  final List<String?> answers = [];
  Completer<String?>? pending;

  static String sheetValue(String id) => const ['kite', 'box'][int.parse(id)];

  void dispose() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockDecodedMessageHandler<Object?>(_channel, null);
}
