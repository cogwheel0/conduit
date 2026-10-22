import 'package:material_ui/material_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../theme/theme_extensions.dart';
import '../../../theme/color_tokens.dart';
import 'adaptive_layout.dart';
import 'compact_modal_owner.dart';

export 'compact_modal_owner.dart';

// Non-control presentation primitives used by the compact Android surfaces.
export 'package:material_ui/material_ui.dart'
    show Icons, Theme, Colors, ListTile, RefreshIndicator, SelectableText;

class CompactIconAction extends StatelessWidget {
  const CompactIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 24,
    this.color,
    this.backgroundColor,
    this.borderColor,
    this.extent = 44,
    this.fillHeight = false,
  });
  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double iconSize;
  final Color? color;
  final Color? backgroundColor;
  final Color? borderColor;
  final double extent;
  final bool fillHeight;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: icon,
    iconSize: iconSize,
    color: color,
    padding: EdgeInsets.zero,
    constraints: BoxConstraints.tightFor(
      width: extent < 48 ? 48 : extent,
      height: fillHeight ? double.infinity : (extent < 48 ? 48 : extent),
    ),
    style: IconButton.styleFrom(
      shape: const StadiumBorder(),
      backgroundColor: backgroundColor,
      side: borderColor == null
          ? null
          : BorderSide(
              color: withMinContrast(
                borderColor!,
                Color.alphaBlend(
                  backgroundColor ?? Colors.transparent,
                  context.conduitTheme.surfaceContainer,
                ),
                3,
              ),
            ),
    ),
  );
}

class CompactNavigationSurface extends StatelessWidget {
  const CompactNavigationSurface({super.key, required this.child, this.color});
  final Widget child;
  final Color? color;
  @override
  Widget build(BuildContext context) => Material(
    color: color ?? context.conduitTheme.surfaceChrome,
    shape: StadiumBorder(
      side: BorderSide(color: context.conduitTheme.borderChrome),
    ),
    child: child,
  );
}

class CompactMenuChoice<T> {
  const CompactMenuChoice(
    this.value,
    this.label, {
    this.icon,
    this.enabled = true,
    this.selected = false,
  });
  final T value;
  final String label;
  final IconData? icon;
  final bool enabled;
  final bool selected;
}

class CompactPopupMenu<T> extends StatelessWidget {
  const CompactPopupMenu({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.choices,
    required this.onSelected,
    this.maxHeightFraction,
    this.menuKey,
  });
  final GlobalKey<PopupMenuButtonState<T>>? menuKey;
  final String tooltip;
  final Widget icon;
  final List<CompactMenuChoice<T>> choices;
  final ValueChanged<T> onSelected;
  final double? maxHeightFraction;
  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    key: menuKey,
    tooltip: tooltip,
    icon: icon,
    position: PopupMenuPosition.under,
    constraints: BoxConstraints(
      minWidth: 112,
      maxWidth: 260,
      maxHeight: maxHeightFraction == null
          ? double.infinity
          : MediaQuery.sizeOf(context).height * maxHeightFraction!,
    ),
    menuPadding: const EdgeInsets.symmetric(vertical: 4),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final choice in choices)
        PopupMenuItem<T>(
          value: choice.value,
          enabled: choice.enabled,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (choice.icon != null) ...[
                Icon(choice.icon, size: 18),
                const SizedBox(width: 6),
              ],
              Flexible(child: Text(choice.label)),
              if (choice.selected) ...[
                const SizedBox(width: 8),
                const Icon(Icons.check_rounded, size: 18),
              ],
            ],
          ),
        ),
    ],
  );
}

/// Fits the menu to its labels and anchors it directly above its trigger.
Future<T?> showCompactMenuAbove<T>(
  BuildContext context,
  BuildContext anchor,
  List<CompactMenuChoice<T>> choices,
) => showCompactMenuAtAnchor(context, anchor, choices, above: true);

Future<T?> showCompactMenuAtAnchor<T>(
  BuildContext context,
  BuildContext anchor,
  List<CompactMenuChoice<T>> choices, {
  bool above = false,
}) {
  final button = anchor.findRenderObject()! as RenderBox;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  RelativeRect? lastPosition;
  Rect? lastAnchor;
  BuildContext? popupLayout;
  var open = true;
  Rect anchorRect() => Rect.fromPoints(
    button.localToGlobal(Offset.zero, ancestor: overlay),
    button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );
  void followAfterLayout(Duration _) {
    if (!open) return;
    final layout = popupLayout;
    if (!button.attached || !overlay.attached || layout?.mounted == false) {
      return;
    }
    if (layout != null) {
      final current = anchorRect();
      if (current != lastAnchor) {
        lastAnchor = current;
        (layout as Element).markNeedsBuild();
      }
    }
    // Observe frames already scheduled by IME/composer motion. A stationary
    // menu does not schedule any frames. Stop following when the popup closes.
    WidgetsBinding.instance.addPostFrameCallback(followAfterLayout);
  }

  WidgetsBinding.instance.addPostFrameCallback(followAfterLayout);
  return showMenu<T>(
    context: context,
    constraints: const BoxConstraints(minWidth: 112, maxWidth: 200),
    positionBuilder: (popupContext, constraints) {
      popupLayout = popupContext;
      if (!button.attached || !overlay.attached) {
        return lastPosition ?? RelativeRect.fill;
      }
      final rect = anchorRect();
      lastAnchor = rect;
      const gap = 8.0;
      final menuHeight = choices.length * 48 + 8; // Includes vertical padding.
      final top = (above ? rect.top - menuHeight - gap : rect.bottom + gap)
          .clamp(gap, overlay.size.height);
      return lastPosition = RelativeRect.fromLTRB(
        rect.left,
        top,
        overlay.size.width - rect.right,
        overlay.size.height - rect.top,
      );
    },
    menuPadding: const EdgeInsets.symmetric(vertical: 4),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    items: [
      for (final choice in choices)
        PopupMenuItem<T>(
          value: choice.value,
          enabled: choice.enabled,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (choice.icon != null) ...[
                Icon(choice.icon, size: 18),
                const SizedBox(width: 6),
              ],
              Flexible(child: Text(choice.label)),
            ],
          ),
        ),
    ],
  ).whenComplete(() => open = false);
}

AdaptiveAppBar compactConversationToolbar(
  BuildContext context, {
  required String title,
  required String backLabel,
  required VoidCallback onBack,
  required List<Widget> actions,
  IconData leadingIcon = Icons.arrow_back_rounded,
  Widget Function(Widget)? titleBuilder,
}) => AdaptiveAppBar(
  useNativeToolbar: false,
  appBar: AppBar(
    toolbarHeight: 48,
    backgroundColor: context.conduitTheme.surfaceBackground,
    foregroundColor: context.conduitTheme.textPrimary,
    scrolledUnderElevation: 0,
    leading: CompactIconAction(
      tooltip: backLabel,
      icon: Icon(leadingIcon),
      onPressed: onBack,
    ),
    title:
        titleBuilder?.call(
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: context.conduitTheme.textPrimary,
            ),
          ),
        ) ??
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: context.conduitTheme.textPrimary,
          ),
        ),
    actions: actions,
  ),
);

Future<void> showCompactConversationSheet(BuildContext context, Widget child) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .72,
        child: SafeArea(child: child),
      ),
    );

/// A content-sized mobile chooser with four columns at normal text sizes.
Future<T?> showCompactConfigurationSheet<T>(
  BuildContext context,
  WidgetBuilder builder,
) {
  final owner = CompactModalOwnerScope.maybeOf(context);
  final generation = owner?.generation;
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => owner == null
        ? SafeArea(top: false, child: builder(context))
        : _OwnedCompactConfigurationSheet(
            owner: owner,
            generation: generation!,
            builder: builder,
          ),
  );
}

class _OwnedCompactConfigurationSheet extends StatefulWidget {
  const _OwnedCompactConfigurationSheet({
    required this.owner,
    required this.generation,
    required this.builder,
  });

  final CompactModalOwner owner;
  final int generation;
  final WidgetBuilder builder;

  @override
  State<_OwnedCompactConfigurationSheet> createState() =>
      _OwnedCompactConfigurationSheetState();
}

class _OwnedCompactConfigurationSheetState
    extends State<_OwnedCompactConfigurationSheet> {
  ModalRoute<dynamic>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == null) return;
    _route = route;
    widget.owner.register(route, widget.generation);
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) widget.owner.unregister(route);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.owner.isCurrent(widget.generation)) {
      return const SizedBox.shrink();
    }
    return CompactModalOwnerScope(
      owner: widget.owner,
      child: SafeArea(top: false, child: Builder(builder: widget.builder)),
    );
  }
}

Future<void> showCompactMessageSelection(
  BuildContext context, {
  required String text,
  required String title,
  required String hint,
  required String closeLabel,
  WidgetBuilder? formattedContent,
}) => showCompactConfigurationSheet<void>(context, (context) {
  final theme = context.conduitTheme;
  return Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .65,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              CompactIconAction(
                tooltip: closeLabel,
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Text(hint, style: TextStyle(color: theme.textSecondary)),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child:
                  formattedContent?.call(context) ??
                  SelectableText(
                    text,
                    key: const ValueKey('hermes-select-message-text'),
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(color: theme.textPrimary),
                  ),
            ),
          ),
        ],
      ),
    ),
  );
});

Future<T?> showCompactSelectionGrid<T>(
  BuildContext context, {
  required String title,
  required List<CompactMenuChoice<T>> choices,
  Widget? header,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => SafeArea(
    top: false,
    child: CompactSelectionGrid<T>(
      title: title,
      choices: choices,
      header: header,
      onSelected: (value) => Navigator.of(context).pop(value),
    ),
  ),
);

class CompactSelectionGrid<T> extends StatelessWidget {
  const CompactSelectionGrid({
    super.key,
    required this.title,
    required this.choices,
    required this.onSelected,
    this.header,
  });
  final String title;
  final List<CompactMenuChoice<T>> choices;
  final ValueChanged<T> onSelected;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: theme.textPrimary,
                    ),
                  ),
                ),
                CompactIconAction(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (header != null) ...[header!, const SizedBox(height: 8)],
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) => GridView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: (constraints.maxWidth / (76 * textScale))
                        .floor()
                        .clamp(1, 4),
                    mainAxisExtent: 72 * textScale,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: choices.length,
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    final fill = choice.selected
                        ? Color.alphaBlend(
                            theme.buttonPrimary.withValues(alpha: .16),
                            theme.surfaceContainer,
                          )
                        : theme.surfaceContainer;
                    return Semantics(
                      button: true,
                      selected: choice.selected,
                      enabled: choice.enabled,
                      child: Material(
                        color: fill,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: choice.selected
                              ? BorderSide(
                                  color: withMinContrast(
                                    theme.buttonPrimary,
                                    fill,
                                    3,
                                  ),
                                )
                              : BorderSide.none,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: choice.enabled
                              ? () => onSelected(choice.value)
                              : null,
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Center(
                              child: Text(
                                choice.label,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: theme.textPrimary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared pill treatment for configuration and assistant footer actions.
class CompactActionSurface extends StatelessWidget {
  const CompactActionSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Material(
    color: context.conduitTheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

class CompactActionBubble extends StatelessWidget {
  const CompactActionBubble({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.busy = false,
  });
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null && !busy,
    label: icon != null || busy ? label : null,
    child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Material(
        color: context.conduitTheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: icon == null ? 12 : 8),
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : icon == null
                    ? Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: context.conduitTheme.textPrimary,
                        ),
                      )
                    : ExcludeSemantics(
                        child: Icon(
                          icon,
                          size: 18,
                          color: context.conduitTheme.textPrimary,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class CompactSearchField extends StatelessWidget {
  const CompactSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });
  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: context.conduitTheme.inputPlaceholder),
      prefixIcon: Icon(
        Icons.search_rounded,
        color: context.conduitTheme.iconSecondary,
      ),
      filled: true,
      fillColor: context.conduitTheme.surfaceContainer,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(24),
        borderSide: BorderSide.none,
      ),
    ),
  );
}

/// A compact, accessible disclosure row for mobile work-area sections.
class HermesSkillsIcon extends StatelessWidget {
  const HermesSkillsIcon({super.key});
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/hermes-skills.svg',
    width: 22,
    height: 22,
    colorFilter: ColorFilter.mode(
      context.conduitTheme.textPrimary,
      BlendMode.srcIn,
    ),
  );
}

/// Compact content rows keep internal padding independent of global tile themes.
class CompactContentRow extends StatelessWidget {
  const CompactContentRow({
    super.key,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
    this.surface = false,
  });
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback onTap;
  final bool surface;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    container: true,
    child: Material(
      color: surface ? context.conduitTheme.cardBackground : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DefaultTextStyle(
                        style: Theme.of(context).textTheme.bodyMedium!
                            .copyWith(color: context.conduitTheme.textPrimary),
                        child: title,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        DefaultTextStyle(
                          style: Theme.of(context).textTheme.bodySmall!
                              .copyWith(
                                color: context.conduitTheme.textSecondary,
                              ),
                          child: subtitle!,
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 12), trailing!],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class CompactDisclosureSection extends StatefulWidget {
  const CompactDisclosureSection({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyExpanded = false,
    this.iconWidget,
  });
  final String title;
  final IconData icon;
  final Widget? iconWidget;
  final Widget child;
  final bool initiallyExpanded;
  @override
  State<CompactDisclosureSection> createState() =>
      _CompactDisclosureSectionState();
}

class _CompactDisclosureSectionState extends State<CompactDisclosureSection> {
  late bool _expanded = widget.initiallyExpanded;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MergeSemantics(
        child: Semantics(
          expanded: _expanded,
          button: true,
          child: Material(
            color: Colors.transparent,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              minTileHeight: 56,
              tileColor: context.conduitTheme.surfaceContainer,
              leading: widget.iconWidget ?? Icon(widget.icon, size: 22),
              title: Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              trailing: Icon(
                _expanded
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
          ),
        ),
      ),
      if (_expanded) ...[
        const SizedBox(height: 8),
        ListTileTheme(
          data: ListTileTheme.of(context)
              .copyWith(tileColor: Colors.transparent),
          child: widget.child,
        ),
      ],
      const SizedBox(height: 16),
    ],
  );
}
