import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/legacy_design_compatibility.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNSearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../../support/native_platform_views.dart';

// The package draws CNSearchBar natively or as a Flutter fallback depending on
// the host running the test, so these tests drive the bar through its
// callbacks, which both report through, and never look inside it.
void main() {
  setUp(() {
    stubNativePlatformViews();
    PlatformUiCapabilities.debugPlatformOverride = TargetPlatform.iOS;
    PlatformUiCapabilities.debugIOSMajorVersionOverride = 26;
    PlatformUiCapabilities.debugNativeIOS26Override = true;
  });
  tearDown(PlatformUiCapabilities.resetDebugOverrides);

  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  Widget host(Widget child) => MaterialApp(
    builder: (context, child) => LegacyDesignCompatibility(child: child!),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );

  // The package holds glass back for 500 ms after its first platform view.
  Future<void> show(WidgetTester tester, Widget field) async {
    await tester.pumpWidget(host(field));
    await tester.pump(const Duration(milliseconds: 500));
  }

  final searchBar = find.byType(CNSearchBar);
  final flutterField = find.byType(EditableText);
  CNSearchBar bar(WidgetTester tester) => tester.widget<CNSearchBar>(searchBar);
  String flutterText(WidgetTester tester) =>
      tester.widget<EditableText>(flutterField).controller.text;

  testWidgets('iOS 26 uses the system search bar, set up to keep its text', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await show(tester, _field(controller));

    expect(bar(tester).placeholder, 'Search things');
    expect(bar(tester).expandable, isFalse);
    expect(bar(tester).expandedHeight, TouchTarget.minimum);
    // Cancel would collapse a bar that cannot expand again, and a bar hidden
    // under a modal comes back without its text.
    expect(bar(tester).showCancelButton, isFalse);
    expect(bar(tester).autoHideOnModal, isFalse);
  }, variant: ios);

  testWidgets('focus, an opt-out, a saved query or older iOS keep Flutter', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final saved = TextEditingController(text: 'saved query');
    addTearDown(saved.dispose);

    for (final field in [
      _field(controller, focus: focusNode),
      _field(controller, native: false),
      _field(saved),
    ]) {
      await show(tester, field);
      expect(searchBar, findsNothing);
      expect(flutterField, findsOneWidget);
    }
    expect(flutterText(tester), 'saved query');

    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await show(tester, _field(controller));
    expect(searchBar, findsNothing);
  }, variant: ios);

  testWidgets('typing fills the controller and clearing calls onClear once', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changes = <String>[];
    var clears = 0;
    await show(
      tester,
      _field(controller, onChanged: changes.add, onClear: () => clears++),
    );

    bar(tester).onChanged!('a');
    bar(tester).onChanged!('ab');
    expect(controller.text, 'ab');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    expect(changes, ['a', 'ab']);

    // The native clear button reports the empty text twice.
    bar(tester).onChanged!('');
    bar(tester).onChanged!('');
    expect(controller.text, isEmpty);
    expect(clears, 1);
    expect(changes, ['a', 'ab']);
  }, variant: ios);

  testWidgets('the app can clear the bar; other text it sets falls back', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await show(tester, _field(controller));
    bar(tester).onChanged!('ab');
    await tester.pump();
    final typedInto = tester.state(searchBar);

    // A new native field starts empty.
    controller.clear();
    await tester.pump();
    expect(tester.state(searchBar), isNot(same(typedInto)));

    controller.text = 'set by the app';
    await tester.pump();
    expect(searchBar, findsNothing);
    expect(flutterText(tester), 'set by the app');
  }, variant: ios);
}

ConduitGlassSearchField _field(
  TextEditingController controller, {
  FocusNode? focus,
  bool native = true,
  ValueChanged<String>? onChanged,
  VoidCallback? onClear,
}) => ConduitGlassSearchField(
  controller: controller,
  focusNode: focus,
  hintText: 'Search things',
  query: controller.text,
  onChanged: onChanged ?? (_) {},
  onClear: onClear ?? () {},
  nativeOnIOS26: native,
);
