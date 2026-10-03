import 'package:checks/checks.dart';
import 'package:conduit/features/workspace/widgets/workspace_editor_scaffold.dart';
import 'package:conduit/features/workspace/widgets/workspace_read_only_badge.dart';
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
  // Below the 840 px breakpoint the badge sits in the header, above it in the
  // toolbar.
  const widths = {'compact': 390.0, 'wide': 1000.0};

  Future<void> pumpDetail(
    WidgetTester tester, {
    required double width,
    VoidCallback? onEdit,
    Future<void> Function()? onSave,
  }) async {
    tester.view.physicalSize = Size(width, 844);
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
            onSave: onSave,
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  for (final MapEntry(key: layout, value: width) in widths.entries) {
    testWidgets('a detail page the user can edit is not marked read only '
        '($layout layout)', (tester) async {
      await pumpDetail(tester, width: width, onEdit: () {});
      check(find.byType(WorkspaceReadOnlyBadge).evaluate()).isEmpty();
    });

    testWidgets('a detail page without Edit is marked read only '
        '($layout layout)', (tester) async {
      await pumpDetail(tester, width: width);
      check(find.byType(WorkspaceReadOnlyBadge).evaluate()).isNotEmpty();
    });
  }

  testWidgets('a read-only page offers no Save in the wide toolbar', (
    tester,
  ) async {
    await pumpDetail(tester, width: 1000, onSave: () async {});
    check(find.byKey(const Key('workspace-editor-save')).evaluate()).isEmpty();
  });
}
