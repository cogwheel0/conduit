import 'package:checks/checks.dart';
import 'package:conduit/features/prompts/widgets/prompt_variable_dialog.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/utils/prompt_variable_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  // Material's AlertDialog sizes itself with IntrinsicWidth. The
  // native iOS 26 button builds a LayoutBuilder, which cannot report
  // intrinsic sizes, so the dialog failed layout and left a dead scrim.
  testWidgets('lays out on iOS 26 with native controls enabled', (
    tester,
  ) async {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;

    final variables = const PromptVariableParser().parse(
      'Say hello to {{name}} in one sentence.',
    );
    Map<String, String>? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await PromptVariableDialog.show(
                  context,
                  variables: variables,
                  promptTitle: 'Parity greeting',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    check(tester.takeException()).isNull();
    check(find.text('Parity greeting').evaluate()).isNotEmpty();

    await tester.enterText(find.byType(TextFormField), 'Ada');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    check(result).isNotNull().deepEquals({'name': 'Ada'});

    // The native package delays platform-view readiness in debug builds.
    // Dispose the controls before advancing that guard timer.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
