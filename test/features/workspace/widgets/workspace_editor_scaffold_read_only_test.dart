import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/workspace_navigation.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A detail page shows its fields read-only, and the editors passed that as
/// `readOnly`, so every detail page of a resource the admin owns carried the
/// "Read only: You have view-only access" badge next to a working Edit.
void main() {
  Future<void> pumpDetail(WidgetTester tester, {VoidCallback? onEdit}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: WorkspaceEditorScaffold(
            title: 'Parity skill',
            section: WorkspaceSection.skills,
            mode: WorkspaceRouteMode.detail,
            readOnly: true,
            onEdit: onEdit,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a detail page the user can edit is not marked read only', (
    tester,
  ) async {
    await pumpDetail(tester, onEdit: () {});
    check(find.text('Read only').evaluate()).isEmpty();
  });

  testWidgets('a detail page without Edit is marked read only', (tester) async {
    await pumpDetail(tester);
    check(find.text('Read only').evaluate()).isNotEmpty();
  });
}
