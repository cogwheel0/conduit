import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNDatePicker, CNDatePickerMode, CNDatePickerStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

void main() {
  setUp(() {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<CNDatePicker> pump(
    WidgetTester tester,
    AdaptiveCompactDatePicker picker,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => LegacyDesignCompatibility(child: child!),
        home: Scaffold(body: Center(child: picker)),
      ),
    );
    return tester.widget<CNDatePicker>(find.byType(CNDatePicker));
  }

  testWidgets(
    'local and UTC values reach the system pill as the same wall clock',
    (tester) async {
      for (final value in [
        DateTime(2026, 6, 15, 14, 45),
        DateTime.utc(2026, 6, 15, 14, 45),
      ]) {
        final native = await pump(
          tester,
          AdaptiveCompactDatePicker(
            value: value,
            mode: AdaptiveCompactDatePickerMode.time,
            minimumDate: DateTime(2026, 1, 2, 8, 15),
            maximumDate: DateTime.utc(2026, 12, 30, 23, 59),
            onChanged: (_) {},
          ),
        );
        // Kept field for field, in UTC, so the device's zone can't move
        // them.
        expect(native.value, DateTime.utc(2026, 6, 15, 14, 45));
        expect(native.minimumDate, DateTime.utc(2026, 1, 2, 8, 15));
        expect(native.maximumDate, DateTime.utc(2026, 12, 30, 23, 59));
        expect(
          (native.mode, native.style),
          (CNDatePickerMode.time, CNDatePickerStyle.compact),
        );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a pill without a callback is disabled, and a pick is passed on',
    (tester) async {
      var native = await pump(
        tester,
        AdaptiveCompactDatePicker(
          value: DateTime(2026, 11, 7),
          mode: AdaptiveCompactDatePickerMode.date,
          onChanged: null,
        ),
      );
      expect(native.enabled, isFalse);
      expect((native.minimumDate, native.maximumDate), (null, null));
      // A late report from the native view is dropped.
      native.onChanged(DateTime.utc(2026, 11, 9));

      final picked = <DateTime>[];
      native = await pump(
        tester,
        AdaptiveCompactDatePicker(
          value: DateTime(2026, 11, 7),
          mode: AdaptiveCompactDatePickerMode.date,
          onChanged: picked.add,
        ),
      );
      expect(native.enabled, isTrue);
      expect(native.mode, CNDatePickerMode.date);
      native.onChanged(DateTime.utc(2026, 11, 9));
      expect(picked, [DateTime.utc(2026, 11, 9)]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
