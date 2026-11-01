import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
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
    menu.onSelected(3);
    expect(index, 3);
    expect(value, 7);
    menu.onSelected(1);
    menu.onSelected(2);
    menu.onSelected(99);
    expect(value, 7);
    menu.onSelected(0);
    expect(value, 41);
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
