import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'an iOS settings row keeps room for its value beside a long label',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                // flex 9 lets the label claim almost the whole row.
                child: AccessibleFormField(
                  label: 'A very long connection name label for this row',
                  hint: 'value',
                  iosSettingsRow: true,
                  iosLabelFlex: 9,
                  controller: TextEditingController(),
                ),
              ),
            ),
          ),
        ),
      );

      // A starved value field overflows the row and reports an exception.
      expect(tester.takeException(), isNull);
      final field = tester.getSize(find.byType(EditableText));
      expect(field.width, greaterThanOrEqualTo(TouchTarget.minimum - 1));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
