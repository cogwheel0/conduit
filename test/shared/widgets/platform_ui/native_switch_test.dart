import 'package:conduit/shared/widgets/adaptive_dropdown_field.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
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

  testWidgets('empty native choice fields render their hint once', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        AdaptiveDropdownField<String?>(
          value: null,
          options: const [
            AdaptiveDropdownOption<String?>(value: 'boat', label: 'Paper boat'),
          ],
          onChanged: (_) {},
          decoration: const InputDecoration(hintText: 'Choose a shape'),
        ),
      ),
    );
    expect(find.text('Choose a shape'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('native switch remains controlled and has an accessible action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      var value = false;
      var changes = 0;
      late StateSetter update;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return AdaptiveSwitch(
                value: value,
                semanticLabel: 'Keep sketch',
                onChanged: (next) => setState(() {
                  value = next;
                  changes++;
                }),
              );
            },
          ),
        ),
      );
      expect(
        tester.widget<CNSwitch>(find.byType(CNSwitch)).semanticLabel,
        'Keep sketch',
      );
      final nativeView = find.descendant(
        of: find.byType(CNSwitch),
        matching: find.byType(UiKitView),
      );
      if (nativeView.evaluate().isEmpty) {
        expect(
          tester.getSemantics(find.byType(AdaptiveSwitch)),
          matchesSemantics(
            label: 'Keep sketch',
            hasToggledState: true,
            isToggled: false,
            hasEnabledState: true,
            isEnabled: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        tester.semantics.tap(find.semantics.byLabel('Keep sketch'));
      } else {
        // The stub has no UIKit accessibility tree. Check its creation data;
        // native VoiceOver is verified on iOS, without a duplicate Flutter node.
        expect(
          tester.widget<UiKitView>(nativeView).creationParams,
          containsPair('semanticLabel', 'Keep sketch'),
        );
        expect(find.bySemanticsLabel('Keep sketch'), findsNothing);
        tester.widget<CNSwitch>(find.byType(CNSwitch)).onChanged(true);
      }
      await tester.pump();
      expect(value, isTrue);
      expect(changes, 1);
      // Native SwiftUI reports both user changes and programmatic updates.
      tester.widget<CNSwitch>(find.byType(CNSwitch)).onChanged(true);
      expect(changes, 1);
      update(() => value = false);
      await tester.pump();
      final control = tester.widget<CNSwitch>(find.byType(CNSwitch));
      expect(control.value, isFalse);
      control.onChanged(false);
      expect(changes, 1);
      control.onChanged(true);
      expect(changes, 2);
      // Two native events can arrive before the next Flutter frame.
      control.onChanged(false);
      expect(changes, 3);
    } finally {
      semantics.dispose();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'disabled switches and explicit thumb colors retain their contracts',
    (tester) async {
      await tester.pumpWidget(
        host(
          const AdaptiveSwitch(
            value: true,
            onChanged: null,
            semanticLabel: 'Unavailable',
          ),
        ),
      );
      expect(tester.widget<CNSwitch>(find.byType(CNSwitch)).enabled, isFalse);
      await tester.pumpWidget(
        host(
          AdaptiveSwitch(
            value: true,
            onChanged: (_) {},
            thumbColor: CupertinoColors.systemRed,
          ),
        ),
      );
      expect(find.byType(CNSwitch), findsNothing);
      expect(
        tester.widget<CupertinoSwitch>(find.byType(CupertinoSwitch)).thumbColor,
        CupertinoColors.systemRed,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
