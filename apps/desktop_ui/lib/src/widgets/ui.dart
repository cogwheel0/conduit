import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import '../keyboard.dart';
import '../rpc/rpc_providers.dart';
import 'lucide_icons.dart';

export 'lucide_icons.dart';

/// The desktop's base pieces: icons, buttons,
/// tabs, and the class sets overlays and fields share.
///
/// Mostly functions and constants, like form_field.dart: they hold no
/// state, and the class strings are what keeps every screen on the same
/// sizes, radii and surfaces.

/// A Lucide icon, drawn inline and hidden from assistive technology: the
/// control around it carries the name.
Component icon(LucideIcon glyph, {String classes = 'size-4 shrink-0'}) => svg(
  [
    for (final (tag, attributes) in glyph.nodes)
      Component.element(tag: tag, attributes: attributes),
  ],
  viewBox: '0 0 24 24',
  classes: classes,
  attributes: const <String, String>{
    'fill': 'none',
    'stroke': 'currentColor',
    'stroke-width': '2',
    'stroke-linecap': 'round',
    'stroke-linejoin': 'round',
    'aria-hidden': 'true',
    'focusable': 'false',
  },
);

/// How strongly a button asks to be pressed.
enum ButtonTone {
  /// The one main action in a view: black on light, white on dark.
  primary,

  /// A bordered button on the panel.
  outline,

  /// A quiet fill for secondary actions.
  secondary,

  /// Text only until hovered; toolbars and rows.
  ghost,

  /// Deleting or leaving; used for the confirming button, not the one that
  /// opens the confirmation.
  destructive,

  /// Text only, in the destructive colour: the button that asks first.
  danger,
}

/// Control heights: 28 px in dense places, 32 px elsewhere.
enum ControlSize { sm, md }

/// The classes of a button of [tone] and [size]. Controls are `rounded-lg`.
String buttonClasses({
  ButtonTone tone = ButtonTone.outline,
  ControlSize size = ControlSize.md,
  bool iconOnly = false,
}) {
  final box = switch ((size, iconOnly)) {
    (ControlSize.sm, true) => 'size-7',
    (ControlSize.md, true) => 'size-8',
    (ControlSize.sm, false) => 'h-7 px-2.5 gap-1.5',
    (ControlSize.md, false) => 'h-8 px-3 gap-2',
  };
  final look = switch (tone) {
    ButtonTone.primary =>
      'bg-primary text-primary-foreground hover:bg-primary/85',
    ButtonTone.outline =>
      'border border-border bg-panel text-foreground '
          'hover:border-border-hover hover:bg-hover',
    ButtonTone.secondary => 'bg-surface text-foreground hover:bg-surface-hover',
    ButtonTone.ghost =>
      'text-foreground-subtle hover:bg-hover hover:text-foreground '
          'aria-pressed:bg-selected aria-pressed:text-foreground',
    ButtonTone.destructive =>
      'bg-destructive text-destructive-foreground hover:bg-destructive/85',
    ButtonTone.danger => 'text-destructive hover:bg-destructive/10',
  };
  return 'inline-flex shrink-0 items-center justify-center rounded-lg '
      'text-ui-sm font-medium whitespace-nowrap transition-colors '
      'disabled:pointer-events-none disabled:opacity-50 $box $look';
}

/// A text button, with an optional leading icon.
Component uiButton({
  required String text,
  void Function()? onClick,
  LucideIcon? leading,
  ButtonTone tone = ButtonTone.outline,
  ControlSize size = ControlSize.md,
  ButtonType type = ButtonType.button,
  bool disabled = false,
  String? id,
  String classes = '',
  Map<String, String>? attributes,
}) => button(
  [if (leading != null) icon(leading), Component.text(text)],
  id: id,
  classes: '${buttonClasses(tone: tone, size: size)} $classes'.trim(),
  type: type,
  disabled: disabled,
  attributes: attributes,
  onClick: onClick,
);

/// A button that is only an icon.
///
/// [label] is its accessible name and its tooltip; [pressed] makes it a
/// toggle, announced as one. [shortcut] is shown in the tooltip after the
/// label.
Component iconButton({
  required LucideIcon glyph,
  required String label,
  void Function()? onClick,
  bool? pressed,
  String? shortcut,
  ControlSize size = ControlSize.sm,
  ButtonTone tone = ButtonTone.ghost,
  bool disabled = false,
  String? id,
  String classes = '',
  TooltipSide tooltip = TooltipSide.bottom,
  Map<String, String>? attributes,
}) => button(
  [icon(glyph)],
  id: id,
  classes: '${buttonClasses(tone: tone, size: size, iconOnly: true)} $classes'
      .trim(),
  type: ButtonType.button,
  disabled: disabled,
  attributes: <String, String>{
    'aria-label': label,
    'aria-pressed': ?pressed?.toString(),
    ...tooltipAttributes(
      shortcut == null ? label : '$label  $shortcut',
      side: tooltip,
    ),
    ...?attributes,
  },
  onClick: onClick,
);

/// An icon button named by text a screen reader reads and the eye does
/// not: the same as [iconButton] to a user, but its name is content rather
/// than an attribute, so it is found by its words -- in the transcript's
/// action rows, where "Copy" is also what a test looks for.
Component iconAction({
  required LucideIcon glyph,
  required String label,
  void Function()? onClick,
  bool? pressed,
  bool destructive = false,
  bool disabled = false,
  String? id,
  String classes = '',
  TooltipSide tooltip = TooltipSide.bottom,
  Map<String, String>? attributes,
}) => button(
  [
    icon(glyph, classes: 'size-3.5'),
    span(classes: 'sr-only', [Component.text(label)]),
  ],
  id: id,
  classes:
      'inline-flex size-7 shrink-0 items-center justify-center rounded-lg '
      'transition-colors disabled:pointer-events-none disabled:opacity-40 '
      '${destructive ? 'text-foreground-subtle hover:bg-destructive/10 hover:text-destructive' : 'text-foreground-subtle hover:bg-hover hover:text-foreground aria-pressed:text-foreground'} '
      '$classes',
  type: ButtonType.button,
  disabled: disabled,
  attributes: <String, String>{
    'aria-pressed': ?pressed?.toString(),
    ...tooltipAttributes(label, side: tooltip),
    ...?attributes,
  },
  onClick: onClick,
);

/// Where a tooltip opens relative to its control.
enum TooltipSide { top, bottom, left, right }

/// Attributes that give an element a tooltip, drawn by app.css.
///
/// Shown on hover and on keyboard focus, and never the only place a name
/// lives: the element's own label is what a screen reader reads, so the
/// tooltip is hidden from it.
Map<String, String> tooltipAttributes(
  String text, {
  TooltipSide side = TooltipSide.bottom,
}) => <String, String>{'data-tooltip': text, 'data-tooltip-side': side.name};

/// One tab in a [TabStrip].
class UiTab {
  const UiTab({required this.id, required this.label, this.glyph});

  final String id;
  final String label;
  final LucideIcon? glyph;
}

/// A row of tabs over a panel.
///
/// Real ARIA tabs: the strip is a `tablist`, each tab says whether it is
/// selected and which panel it controls, and the panel with id
/// `$idPrefix-panel-<tab id>` is expected to carry `role="tabpanel"`. The
/// strip is one tab stop; the arrow keys, Home and End move within it, and
/// selection follows focus.
class TabStrip extends StatelessComponent {
  const TabStrip({
    required this.idPrefix,
    required this.label,
    required this.tabs,
    required this.selected,
    required this.onSelect,
    this.classes = '',
    super.key,
  });

  final String idPrefix;
  final String label;
  final List<UiTab> tabs;
  final String selected;
  final void Function(String id) onSelect;
  final String classes;

  @override
  Component build(BuildContext context) => div(
    classes: 'flex min-w-0 items-center gap-0.5 $classes'.trim(),
    attributes: <String, String>{'role': 'tablist', 'aria-label': label},
    events: <String, EventCallback>{
      'keydown': tabKeys((step) {
        if (tabs.isEmpty) return;
        final index = tabs.indexWhere((t) => t.id == selected);
        final next = tabs[(index + step).clamp(0, tabs.length - 1)];
        onSelect(next.id);
        context.read(windowCommandsProvider).focus('$idPrefix-tab-${next.id}');
      }),
    },
    [
      for (final tab in tabs)
        button(
          [
            if (tab.glyph case final glyph?) icon(glyph),
            span(classes: 'truncate', [Component.text(tab.label)]),
          ],
          id: '$idPrefix-tab-${tab.id}',
          classes:
              'inline-flex h-7 min-w-0 items-center gap-1.5 rounded-md px-2 '
              'text-ui-sm font-medium transition-colors '
              '${tab.id == selected ? 'bg-selected text-foreground' : 'text-foreground-subtle hover:bg-hover hover:text-foreground'}',
          type: ButtonType.button,
          attributes: <String, String>{
            'role': 'tab',
            'aria-selected': '${tab.id == selected}',
            'aria-controls': '$idPrefix-panel-${tab.id}',
            'tabindex': tab.id == selected ? '0' : '-1',
          },
          onClick: () => onSelect(tab.id),
        ),
    ],
  );
}

/// A menu's box: `lg` corners, with `md` rows inside ([menuItemClasses]).
const String menuClasses =
    'flex min-w-44 flex-col gap-0.5 rounded-lg border border-border bg-menu '
    'p-1 text-ui-base text-popover-foreground shadow-md';

/// A row in a menu.
String menuItemClasses({bool destructive = false}) =>
    'flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left '
    'outline-none focus-visible:bg-menu-hover '
    '${destructive ? 'text-destructive hover:bg-destructive/10' : 'hover:bg-menu-hover'}';

/// A dialog's box: `2xl` corners, and the overlay shadow.
const String dialogClasses =
    'rounded-2xl border border-border bg-popover text-popover-foreground '
    'shadow-md';

/// The dim layer behind a dialog.
const String scrimClasses = 'fixed inset-0 z-50 bg-black/40';

/// A text field or select: 32 px, `lg` corners, a border that firms up on
/// hover and focus.
String fieldClasses({bool invalid = false}) =>
    'w-full rounded-lg border bg-panel px-2.5 py-1.5 text-ui-base '
    'text-foreground placeholder:text-foreground-subtlest outline-none '
    'transition-colors hover:border-border-hover focus-visible:border-ring '
    'disabled:opacity-60 '
    '${invalid ? 'border-destructive' : 'border-border'}';

/// A frame's small caps heading: a sidebar group, a pane section.
const String sectionLabelClasses =
    'text-ui-xs font-medium uppercase tracking-wide text-foreground-subtle';

/// A keyboard shortcut, e.g. in a menu row or a tooltip.
Component kbd(String keys) => span(
  classes:
      'ml-auto rounded-lg border border-border px-1 font-mono text-ui-xs '
      'text-foreground-subtle',
  [Component.text(keys)],
);
