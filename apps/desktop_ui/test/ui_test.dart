@TestOn('vm')
library;

import 'package:conduit_desktop_ui/src/rpc/rpc_providers.dart';
import 'package:conduit_desktop_ui/src/widgets/ui.dart';
import 'package:conduit_desktop_ui/src/window_commands.dart';
import 'package:jaspr/dom.dart' show button, div, svg;
import 'package:jaspr_riverpod/jaspr_riverpod.dart';
import 'package:jaspr_test/jaspr_test.dart';

void main() {
  test('every vendored icon has something to draw', () {
    for (final glyph in LucideIcon.values) {
      expect(glyph.nodes, isNotEmpty, reason: glyph.lucideName);
      for (final (tag, _) in glyph.nodes) {
        expect(
          const <String>{
            'path',
            'circle',
            'rect',
            'line',
            'polyline',
            'polygon',
            'ellipse',
          },
          contains(tag),
          reason: glyph.lucideName,
        );
      }
    }
  });

  testComponents('an icon is drawn as inline svg', (tester) async {
    tester.pumpComponent(div([icon(LucideIcon.x)]));
    expect(find.byType(svg), findsOneComponent);
  });

  testComponents('an icon button is named, and says when it is pressed', (
    tester,
  ) async {
    var clicks = 0;
    tester.pumpComponent(
      div([
        iconButton(
          glyph: LucideIcon.panelLeft,
          label: 'Toggle sidebar',
          shortcut: 'Ctrl+B',
          pressed: true,
          onClick: () => clicks++,
        ),
      ]),
    );
    await tester.click(find.byType(button));
    expect(clicks, 1);
  });

  testComponents('a tab strip selects on click', (tester) async {
    final selected = <String>[];
    tester.pumpComponent(
      ProviderScope(
        overrides: [
          windowCommandsProvider.overrideWithValue(RecordingWindowCommands()),
        ],
        child: TabStrip(
          idPrefix: 'side',
          label: 'Side pane',
          tabs: const <UiTab>[
            UiTab(id: 'controls', label: 'Controls'),
            UiTab(id: 'notes', label: 'Notes'),
          ],
          selected: 'controls',
          onSelect: selected.add,
        ),
      ),
    );
    await tester.click(find.componentWithText(button, 'Notes'));
    expect(selected, <String>['notes']);
  });

  test('buttons keep to the control sizes and rounded-lg', () {
    expect(buttonClasses(size: ControlSize.sm), contains('h-7'));
    expect(buttonClasses(), contains('h-8'));
    expect(buttonClasses(iconOnly: true), contains('size-8'));
    for (final tone in ButtonTone.values) {
      expect(buttonClasses(tone: tone), contains('rounded-lg'));
    }
  });

  test('tooltip attributes carry the text and the side', () {
    expect(tooltipAttributes('Copy', side: TooltipSide.right), <String, String>{
      'data-tooltip': 'Copy',
      'data-tooltip-side': 'right',
    });
  });
}
