import 'package:checks/checks.dart';
import 'package:conduit/features/notes/utils/note_document_codec.dart';
import 'package:conduit/shared/widgets/adaptive_route_shell.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:fleather/fleather.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Pages on iOS are hosted by a [CupertinoPageScaffold], which provides no
/// [Material]. Material controls that pages place directly in their body
/// (the note checklist box, the channel message edit field, the reaction
/// chips) then rendered Flutter's "No Material widget found" error widget.
void main() {
  setUp(() {
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });

  tearDown(() {
    PlatformUiCapabilities.resetDebugOverrides();
  });

  Future<void> pumpRoute(WidgetTester tester, Widget body) {
    return tester.pumpWidget(
      MaterialApp(
        home: AdaptiveRouteShell(
          backgroundColor: const Color(0xFFFFFFFF),
          body: body,
        ),
      ),
    );
  }

  testWidgets('a text field in an iOS route body has a Material ancestor', (
    tester,
  ) async {
    await pumpRoute(tester, const Center(child: TextField()));

    check(tester.takeException()).isNull();
    check(find.byType(CupertinoPageScaffold).evaluate()).isNotEmpty();
    check(find.byType(EditableText).evaluate()).isNotEmpty();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('action chips in an iOS route body render', (tester) async {
    await pumpRoute(
      tester,
      Center(
        child: ActionChip(label: const Text('👍 1'), onPressed: () {}),
      ),
    );

    check(tester.takeException()).isNull();
    check(find.text('👍 1').evaluate()).isNotEmpty();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a note checklist renders its checkbox in an iOS route', (
    tester,
  ) async {
    final controller = FleatherController(
      document: documentFromMarkdown('- [ ] task\n'),
    );
    addTearDown(controller.dispose);

    await pumpRoute(
      tester,
      FleatherEditor(controller: controller, scrollable: false),
    );

    check(tester.takeException()).isNull();
    check(find.byType(ErrorWidget).evaluate()).isEmpty();
    check(
      find
          .byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == 'FleatherCheckbox',
          )
          .evaluate(),
    ).isNotEmpty();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('the iOS body keeps the Cupertino text style', (tester) async {
    late TextStyle bodyStyle;
    await pumpRoute(
      tester,
      Builder(
        builder: (context) {
          bodyStyle = DefaultTextStyle.of(context).style;
          return const SizedBox.shrink();
        },
      ),
    );

    final context = tester.element(find.byType(SizedBox).last);
    check(bodyStyle.fontFamily)
        .equals(CupertinoTheme.of(context).textTheme.textStyle.fontFamily);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
