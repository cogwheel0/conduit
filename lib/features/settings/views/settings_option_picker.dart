import 'package:flutter/widgets.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/sheet_handle.dart';
import 'settings_symbols.dart';

/// Lists this long get a search field, as the native picker does for
/// languages and voices but not for five palettes.
const _searchThreshold = 8;

/// Opens the choices of [item], with [selectedId] marked, and returns the
/// id chosen, or null when the picker was dismissed.
Future<String?> showSettingsOptionPicker(
  BuildContext context, {
  required NativeSheetItemConfig item,
  required String? selectedId,
}) {
  return showAdaptiveSelectionSheet<String>(
    context: context,
    builder: (_) => SettingsOptionSheet(item: item, selectedId: selectedId),
  );
}

/// The picker sheet for one row's options: a search field when the list is
/// long, the row's filter groups when it has them, and the options.
class SettingsOptionSheet extends StatefulWidget {
  const SettingsOptionSheet({
    super.key,
    required this.item,
    required this.selectedId,
  });

  final NativeSheetItemConfig item;
  final String? selectedId;

  @override
  State<SettingsOptionSheet> createState() => _SettingsOptionSheetState();
}

class _SettingsOptionSheetState extends State<SettingsOptionSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  String? _group;

  List<NativeSheetOptionConfig> get _options => widget.item.options;

  bool get _searchable => _options.length > _searchThreshold;

  /// The filter groups in the order they first appear, when the row offers
  /// a filter at all.
  List<String> get _groups {
    if (widget.item.filterAllLabel == null) return const [];
    final seen = <String>{};
    return [
      for (final option in _options)
        if ((option.filterGroup ?? '').isNotEmpty &&
            seen.add(option.filterGroup!))
          option.filterGroup!,
    ];
  }

  List<NativeSheetOptionConfig> get _visible {
    final query = _query.trim().toLowerCase();
    return [
      for (final option in _options)
        if ((_group == null ||
                (option.filterGroup ?? '').isEmpty ||
                option.filterGroup == _group) &&
            (query.isEmpty ||
                option.label.toLowerCase().contains(query) ||
                (option.subtitle?.toLowerCase().contains(query) ?? false)))
          option,
    ];
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final visible = _visible;
    final groups = _groups;
    final tall = _searchable || groups.isNotEmpty;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: tall ? 0.82 : 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.92,
          builder: (context, scrollController) => Container(
            decoration: BoxDecoration(
              color: theme.surfaceBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppBorderRadius.bottomSheet),
              ),
              border: Border.all(
                color: theme.dividerColor,
                width: BorderWidth.regular,
              ),
              boxShadow: ConduitShadows.modal(context),
            ),
            child: ModalSheetSafeArea(
              padding: const EdgeInsets.all(Spacing.modalPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  Semantics(
                    header: true,
                    child: Text(
                      widget.item.title,
                      style: AppTypography.headlineSmallStyle.copyWith(
                        color: theme.textPrimary,
                      ),
                    ),
                  ),
                  if (_searchable) ...[
                    const SizedBox(height: Spacing.sm),
                    AdaptiveTextField(
                      controller: _search,
                      placeholder: MaterialLocalizations.of(context)
                          .searchFieldLabel,
                      prefixIcon: Icon(
                        Icons.search,
                        color: theme.iconSecondary,
                        size: IconSize.medium,
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ],
                  if (groups.isNotEmpty) ...[
                    const SizedBox(height: Spacing.sm),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _groupChip(widget.item.filterAllLabel!, null),
                          for (final group in groups) _groupChip(group, group),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: Spacing.sm),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      padding: EdgeInsets.zero,
                      itemCount: visible.length,
                      itemBuilder: (context, index) =>
                          _optionRow(context, visible[index]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _groupChip(String label, String? group) => Padding(
    padding: const EdgeInsets.only(right: Spacing.xs),
    child: AdaptiveChip.choice(
      label: Text(label),
      selected: _group == group,
      onSelected: (_) => setState(() => _group = group),
    ),
  );

  Widget _optionRow(BuildContext context, NativeSheetOptionConfig option) {
    final theme = context.conduitTheme;
    final swatches =
        (theme.isDark ? option.darkSwatches : null) ?? option.swatches;
    final Widget? leading = swatches != null && swatches.isNotEmpty
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final color in swatches.take(3))
                Padding(
                  padding: const EdgeInsets.only(right: 2),
                  child: Container(
                    width: IconSize.small,
                    height: IconSize.small,
                    decoration: BoxDecoration(
                      color: Color(color),
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.dividerColor),
                    ),
                  ),
                ),
            ],
          )
        : option.sfSymbol != null
        ? Icon(
            settingsMaterialIcon(option.sfSymbol!),
            color: option.destructive ? theme.error : theme.iconSecondary,
            size: IconSize.medium,
          )
        : null;
    final row = AdaptiveSelectionTile(
      key: ValueKey<String>('settings-option-${option.id}'),
      title: option.label,
      subtitle: option.subtitle,
      leading: leading,
      selected: option.id == widget.selectedId,
      onTap: option.enabled
          ? () => Navigator.of(context).pop(option.id)
          : () {},
    );
    if (option.enabled) return row;
    // Read out, as unavailable, with why in its subtitle; it does nothing.
    return Opacity(
      opacity: 0.45,
      child: Semantics(
        enabled: false,
        label: [option.label, ?option.subtitle].join(', '),
        excludeSemantics: true,
        child: IgnorePointer(child: row),
      ),
    );
  }
}
