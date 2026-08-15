import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as modern_cupertino;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as modern_material;

void main() {
  testWidgets('supplies modern app and legacy dependency localizations', (
    tester,
  ) async {
    await tester.pumpWidget(
      modern_material.MaterialApp(
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => modern_cupertino.CupertinoTheme(
          data: const modern_cupertino.CupertinoThemeData(),
          child: LegacyDesignCompatibility(child: child!),
        ),
        home: const modern_material.Text('compatibility-ready'),
      ),
    );

    expect(find.text('compatibility-ready'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.runtimeType.toString() == 'MaterialUiCompatibilityBridge',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.runtimeType.toString() == 'CupertinoUiCompatibilityBridge',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
