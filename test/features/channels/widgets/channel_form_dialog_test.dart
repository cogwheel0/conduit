import 'package:checks/checks.dart';
import 'package:conduit/features/channels/widgets/channel_form_dialog.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// On iOS 26 the dialog action buttons were native platform views, which
/// `AlertDialog` cannot measure intrinsically: layout threw, and the
/// create-channel and "Remove from knowledge" dialogs drew only their barrier.
/// `AdaptiveButton` keeps its Flutter button inside an `AlertDialog`, which
/// these dialogs' `ConduitTextButton` actions rely on.
void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });

  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AdaptiveScaffold(
          body: Builder(
            builder: (context) {
              hostContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  testWidgets('create-channel dialog lays out and returns its form on iOS', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    final result = showCreateChannelFormDialog(context);
    await tester.pumpAndSettle();

    check(tester.takeException()).isNull();
    check(find.byType(TextField).evaluate()).length.equals(2);

    await tester.enterText(find.byType(TextField).first, 'Parity room');
    await tester.tap(find.widgetWithText(ConduitTextButton, 'Create channel'));
    await tester.pumpAndSettle();

    check((await result)?.name).equals('Parity room');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a themed dialog with a list tile and actions dismisses', (
    tester,
  ) async {
    final context = await pumpHost(tester);
    final result = ThemedDialogs.show<bool>(
      context,
      title: 'Remove file?',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('The file stays in your library.'),
          AdaptiveListTile(
            title: const Text('Also delete the file'),
            trailing: AdaptiveCheckbox(value: false, onChanged: (_) {}),
          ),
        ],
      ),
      actions: [
        ConduitTextButton(text: 'Cancel', onPressed: () {}),
        ConduitTextButton(text: 'Remove', isPrimary: true, onPressed: () {}),
      ],
    );
    await tester.pumpAndSettle();

    check(tester.takeException()).isNull();
    check(find.text('Also delete the file').evaluate()).isNotEmpty();

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    check(await result).isNull();
    check(find.text('Remove file?').evaluate()).isEmpty();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
