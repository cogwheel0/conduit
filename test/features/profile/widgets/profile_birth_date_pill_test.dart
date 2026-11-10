import 'package:conduit/features/profile/widgets/profile_birth_date_pill.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/utils/account_profile_form.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

// The system pill is native on an Apple host and a Flutter fallback on the
// Linux CI, so these tests read what the pill and Clear are given and call
// their callbacks, never what either path draws.
void main() {
  setUp(() {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<void> pumpPill(
    WidgetTester tester, {
    required DateTime date,
    ValueChanged<String>? onChanged,
    VoidCallback? onClear,
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => LegacyDesignCompatibility(child: child!),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ProfileBirthDatePill(
              date: date,
              onChanged: onChanged,
              onClear: onClear,
            ),
          ),
        ),
      ),
    );
    // The native button starts a short timer once its view exists.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  AdaptiveCompactDatePicker picker(WidgetTester tester) =>
      tester.widget(find.byType(AdaptiveCompactDatePicker));

  ConduitTextButton clear(WidgetTester tester) =>
      tester.widget(find.byType(ConduitTextButton));

  testWidgets(
    'the pill shows the stored date within the profile bounds and passes a '
    'pick on as YYYY-MM-DD',
    (tester) async {
      final stored = <String>[];
      await pumpPill(
        tester,
        date: DateTime(1991, 4, 12),
        onChanged: stored.add,
      );

      final pill = picker(tester);
      expect(
        (pill.value.year, pill.value.month, pill.value.day),
        (1991, 4, 12),
      );
      expect(pill.mode, AdaptiveCompactDatePickerMode.date);
      expect(pill.minimumDate, kEarliestProfileBirthDate);
      expect(pill.maximumDate!.isAfter(DateTime.now()), isFalse);
      expect(pill.semanticLabel, 'Date of Birth');

      // The pill answers with the picked wall clock in UTC.
      pill.onChanged!(DateTime.utc(1988, 2, 29));
      expect(stored, ['1988-02-29']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Clear is reported, and without callbacks both controls are disabled',
    (tester) async {
      var cleared = 0;
      await pumpPill(
        tester,
        date: DateTime(1991, 4, 12),
        onChanged: (_) {},
        onClear: () => cleared++,
      );
      expect(clear(tester).text, 'Clear');
      clear(tester).onPressed!();
      expect(cleared, 1);

      await pumpPill(tester, date: DateTime(1991, 4, 12));
      expect(picker(tester).onChanged, isNull);
      expect(clear(tester).onPressed, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('a date the profile cannot hold is shown at its nearest bound', (
    tester,
  ) async {
    await pumpPill(tester, date: DateTime(1850, 6, 1), onChanged: (_) {});

    expect(picker(tester).value, kEarliestProfileBirthDate);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'on a narrow screen Clear moves under the pill instead of overflowing',
    (tester) async {
      // Laying out without an overflow error is the check. At this width the
      // Flutter fallback's wider pill leaves Clear no room beside it.
      await pumpPill(
        tester,
        date: DateTime(1991, 4, 12),
        onChanged: (_) {},
        onClear: () {},
        width: 320,
      );

      expect(find.byType(AdaptiveCompactDatePicker), findsOneWidget);
      expect(find.byType(ConduitTextButton), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
