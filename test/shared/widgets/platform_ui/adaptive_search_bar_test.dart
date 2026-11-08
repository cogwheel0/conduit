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

  testWidgets('iOS 26 uses the system search bar, set up to keep its text', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await show(tester, _field(controller, focus: focusNode));

    expect(bar(tester).placeholder, 'Search things');
    expect(bar(tester).expandable, isFalse);
    expect(bar(tester).expandedHeight, TouchTarget.minimum);
    // The app's text and focus reach the field through its controller.
    expect(bar(tester).controller, isNotNull);
    // Cancel would collapse a bar that cannot expand again, and a bar hidden
    // under a modal comes back without its text.
    expect(bar(tester).showCancelButton, isFalse);
    expect(bar(tester).autoHideOnModal, isFalse);
  }, variant: ios);

  testWidgets('an opt-out or older iOS keep the Flutter field', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await show(tester, _field(controller, native: false));
    expect(searchBar, findsNothing);
    expect(flutterField, findsOneWidget);

    PlatformUiCapabilities.debugIOSMajorVersionOverride = 25;
    PlatformUiCapabilities.debugNativeIOS26Override = false;
    await show(tester, _field(controller));
    expect(searchBar, findsNothing);
  }, variant: ios);

  testWidgets('each edit fills the controller and is reported, clearing too', (
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

    // The clear button empties the field; as the iOS Flutter field does, the
    // empty text is reported as an edit.
    bar(tester).onChanged!('');
    expect(controller.text, isEmpty);
    expect(changes, ['a', 'ab', '']);
    expect(clears, 0);
  }, variant: ios);

  testWidgets('text the app sets goes to the field and is not reported back', (
    tester,
  ) async {
    final saved = TextEditingController(text: 'saved query');
    addTearDown(saved.dispose);
    final changes = <String>[];
    await show(tester, _field(saved, onChanged: changes.add));

    // A saved query no longer needs the Flutter field.
    expect(searchBar, findsOneWidget);
    // The field reports the text it was given; the app knows it already.
    bar(tester).onChanged!('saved query');
    expect(changes, isEmpty);
    // What the person types from there is theirs.
    bar(tester).onChanged!('saved query 2');
    expect(changes, ['saved query 2']);
    expect(saved.text, 'saved query 2');

    saved.clear();
    await tester.pump();
    bar(tester).onChanged!('');
    expect(changes, ['saved query 2']);
  }, variant: ios);

  testWidgets(
    'the focus node stands for the field, and a dragged list takes it away',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await show(
        tester,
        Column(
          children: [
            _field(controller, focus: focusNode),
            Expanded(
              child: ListView(
                key: const ValueKey('results'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 48, child: Text('Result $i')),
                ],
              ),
            ),
          ],
        ),
      );

      // Asking for focus asks the native field for its keyboard, which a
      // caller can do only once the node is in the tree.
      expect(focusNode.context, isNotNull);
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      // Dragging the results takes focus from the node, which tells the
      // native field to put its keyboard away.
      await tester.drag(
        find.byKey(const ValueKey('results')),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // A tap on the field, which focuses it natively, focuses the node
      // too, so the next drag reaches the field as well.
      await tester.tap(searchBar);
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      await tester.drag(
        find.byKey(const ValueKey('results')),
        const Offset(0, 200),
      );
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);
    },
    variant: ios,
  );

  testWidgets(
    'texts the app sets in quick succession are not reported as edits',
    (tester) async {
      final query = TextEditingController();
      addTearDown(query.dispose);
      final changes = <String>[];
      await show(tester, _field(query, onChanged: changes.add));

      // A second text before the field has reported the first.
      query.text = 'alpha';
      query.text = 'beta';
      await tester.pump();
      bar(tester).onChanged!('alpha');
      bar(tester).onChanged!('beta');
      // A text sent again reports nothing new.
      bar(tester).onChanged!('beta');
      expect(changes, isEmpty);
      expect(query.text, 'beta');

      // An edit is still the person's.
      bar(tester).onChanged!('beta 2');
      expect(changes, ['beta 2']);
      expect(query.text, 'beta 2');
    },
    variant: ios,
  );

  testWidgets(
    'text replaced before the field could take it does not hide an edit',
    (tester) async {
      final query = TextEditingController(text: 'draft');
      addTearDown(query.dispose);
      final changes = <String>[];
      // The first text is set before the field exists, then replaced.
      await tester.pumpWidget(host(_field(query, onChanged: changes.add)));
      query.clear();
      await tester.pump(const Duration(milliseconds: 500));

      // Typing that same text later is the person's edit.
      bar(tester).onChanged!('draft');
      expect(changes, ['draft']);
      expect(query.text, 'draft');
    },
    variant: ios,
  );

  testWidgets('a new placeholder replaces the field and keeps the query', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changes = <String>[];
    await show(tester, _field(controller, onChanged: changes.add));
    bar(tester).onChanged!('ada');
    final typedInto = tester.state(searchBar);

    // The native placeholder is fixed when the field is created.
    await show(
      tester,
      _field(controller, onChanged: changes.add, hint: 'Search groups'),
    );
    expect(tester.state(searchBar), isNot(same(typedInto)));
    expect(bar(tester).placeholder, 'Search groups');
    expect(controller.text, 'ada');
    // The new field reports the query it was given; it is not an edit.
    bar(tester).onChanged!('ada');
    expect(changes, ['ada']);
  }, variant: ios);
}

ConduitGlassSearchField _field(
  TextEditingController controller, {
  FocusNode? focus,
  bool native = true,
  String hint = 'Search things',
  ValueChanged<String>? onChanged,
  VoidCallback? onClear,
}) => ConduitGlassSearchField(
  controller: controller,
  focusNode: focus,
  hintText: hint,
  query: controller.text,
  onChanged: onChanged ?? (_) {},
  onClear: onClear ?? () {},
  nativeOnIOS26: native,
);
