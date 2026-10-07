import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> pumpChips(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  );
}

/// The visible pill, without the touch target around it.
Finder pill(Finder chip) =>
    find.descendant(of: chip, matching: find.byType(Container)).first;

void main() {
  testWidgets('is announced as a button with its selection', (tester) async {
    var taps = 0;
    await pumpChips(
      tester,
      Wrap(
        children: [
          ConduitChip(
            key: const Key('on'),
            label: 'Daily',
            isSelected: true,
            onTap: () => taps++,
          ),
          const ConduitChip(key: Key('off'), label: 'Weekly'),
        ],
      ),
    );

    expect(
      tester.getSemantics(find.byKey(const Key('on'))),
      isSemantics(
        label: 'Daily',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
      ),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('off'))),
      isSemantics(
        label: 'Weekly',
        isButton: true,
        isSelected: false,
        hasSelectedState: true,
        isEnabled: false,
        hasEnabledState: true,
      ),
    );
    await tester.tap(find.byKey(const Key('on')));
    expect(taps, 1);
  });

  testWidgets('takes taps over a minimum touch target while the pill keeps '
      'its height', (tester) async {
    var taps = 0;
    await pumpChips(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: ConduitChip(
          key: const Key('chip'),
          label: 'Daily',
          isCompact: true,
          onTap: () => taps++,
        ),
      ),
    );

    final chip = find.byKey(const Key('chip'));
    final outer = tester.getRect(chip);
    final visible = tester.getRect(pill(chip));
    expect(outer.height, greaterThanOrEqualTo(44));
    expect(visible.height, lessThan(44));
    expect(visible.center.dy, moreOrLessEquals(outer.center.dy));
    expect(visible.width, outer.width);

    // A tap just above the pill, inside the target, still counts.
    await tester.tapAt(Offset(visible.center.dx, outer.top + 2));
    expect(taps, 1);
  });

  testWidgets('a chip in an Expanded still fills it', (tester) async {
    await pumpChips(
      tester,
      const Row(
        children: [
          Expanded(
            child: ConduitChip(key: Key('a'), label: 'Users'),
          ),
          SizedBox(width: 8),
          Expanded(
            child: ConduitChip(key: Key('b'), label: 'Groups'),
          ),
        ],
      ),
    );

    final a = find.byKey(const Key('a'));
    expect(tester.getSize(pill(a)).width, tester.getSize(a).width);
    expect(
      tester.getSize(pill(a)).width,
      moreOrLessEquals(tester.getSize(find.byKey(const Key('b'))).width),
    );
  });

  testWidgets('a long label ends in an ellipsis instead of overflowing', (
    tester,
  ) async {
    await pumpChips(
      tester,
      const SizedBox(
        width: 120,
        child: Wrap(
          children: [
            ConduitChip(
              key: Key('long'),
              label: 'A calendar with a very long name indeed',
              icon: Icons.event,
            ),
          ],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('long')),
        matching: find.byType(Text),
      ),
    );
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
    expect(tester.getSize(find.byKey(const Key('long'))).width, 120);
  });

  testWidgets('lays out in a row that gives it unbounded width', (
    tester,
  ) async {
    await pumpChips(
      tester,
      const Row(
        children: [
          ConduitChip(label: 'All'),
          ConduitChip(label: 'Active'),
          ConduitChip(label: 'Paused'),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Paused'), findsOneWidget);
  });
}
