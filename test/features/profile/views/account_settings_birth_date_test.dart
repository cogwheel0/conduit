import 'package:conduit/features/profile/views/account_settings_page.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/server_about_info.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/account_profile_form.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

class _Profile extends AccountProfile {
  _Profile(this.dateOfBirth);

  final String? dateOfBirth;
  final saved = <String?>[];

  @override
  Future<AccountMetadata?> build() async => AccountMetadata(
    id: 'user-1',
    email: 'sample.user@example.com',
    name: 'Sample User',
    role: 'user',
    isActive: true,
    dateOfBirth: dateOfBirth,
  );

  @override
  Future<AccountMetadata> save({
    required String name,
    required String profileImageUrl,
    String? bio,
    String? gender,
    String? dateOfBirth,
    String? timezone,
  }) async {
    saved.add(dateOfBirth);
    return state.requireValue!;
  }
}

/// The page keeps an avatar placeholder animating, so it never settles.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// iOS 26 draws these buttons natively, so they are pressed through the
/// widget rather than a tap on their label.
void press(WidgetTester tester, String label) {
  final button = tester.widget(
    find.byWidgetPredicate(
      (widget) =>
          (widget is ConduitButton && widget.text == label) ||
          (widget is ConduitTextButton && widget.text == label),
    ),
  );
  final onPressed = switch (button) {
    ConduitButton(:final onPressed) => onPressed,
    ConduitTextButton(:final onPressed) => onPressed,
    _ => null,
  };
  onPressed!();
}

void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<_Profile> pumpPage(WidgetTester tester, String? dateOfBirth) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    stubNativePlatformViews();
    final profile = _Profile(dateOfBirth);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiServiceProvider.overrideWithValue(null),
          accountProfileProvider.overrideWith(() => profile),
          serverAboutInfoProvider.overrideWith(
            (ref) async => null as ServerAboutInfo?,
          ),
        ],
        child: MaterialApp(
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => LegacyDesignCompatibility(child: child!),
          home: const AccountSettingsPage(),
        ),
      ),
    );
    await settle(tester);
    return profile;
  }

  Finder pill() => find.byKey(const ValueKey('account-birth-date-pill'));

  testWidgets(
    'on iOS 26 a birth date is edited in place and saved as YYYY-MM-DD',
    (tester) async {
      final profile = await pumpPage(tester, '1991-04-12');

      final picker = tester.widget<AdaptiveCompactDatePicker>(pill());
      expect(
        (picker.value.year, picker.value.month, picker.value.day),
        (1991, 4, 12),
      );
      expect(picker.minimumDate, kEarliestProfileBirthDate);
      expect(picker.maximumDate!.isAfter(DateTime.now()), isFalse);

      // The pill answers with the picked wall clock in UTC.
      picker.onChanged!(DateTime.utc(1988, 2, 29));
      await settle(tester);
      press(tester, 'Save profile');
      await settle(tester);

      expect(profile.saved, ['1988-02-29']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('Clear empties the date, which then waits for a choice', (
    tester,
  ) async {
    final profile = await pumpPage(tester, '1991-04-12');

    press(tester, 'Clear');
    await settle(tester);
    expect(pill(), findsNothing);
    expect(find.text('Select a date'), findsOneWidget);

    press(tester, 'Save profile');
    await settle(tester);
    expect(profile.saved, ['']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
