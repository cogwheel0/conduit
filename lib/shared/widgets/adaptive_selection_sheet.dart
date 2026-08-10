import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'modal_safe_area.dart';
import 'sheet_handle.dart';
import 'themed_sheets.dart';
import 'utility_components.dart';

/// Presents the canonical adaptive selector surface.
Future<T?> showAdaptiveSelectionSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool useSafeArea = false,
}) {
  return ThemedSheets.showCustom<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    barrierColor: Colors.transparent,
    builder: builder,
  );
}

/// Shared model-selector style shell for single-choice pickers.
class AdaptiveSelectionSheet extends StatelessWidget {
  const AdaptiveSelectionSheet({
    super.key,
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    this.description,
    this.initialChildSize = 0.55,
    this.minChildSize = 0.32,
    this.maxChildSize = 0.82,
  });

  final String title;
  final String? description;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;

  @override
  Widget build(BuildContext context) {
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
          initialChildSize: initialChildSize,
          minChildSize: minChildSize,
          maxChildSize: maxChildSize,
          builder: (context, scrollController) {
            final theme = context.conduitTheme;

            return Container(
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
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.modalPadding,
                  vertical: Spacing.modalPadding,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SheetHandle(),
                    _SelectionSheetHeader(
                      title: title,
                      description: description,
                    ),
                    const SizedBox(height: Spacing.md),
                    Expanded(
                      child: Scrollbar(
                        controller: scrollController,
                        child: ListView.builder(
                          controller: scrollController,
                          padding: EdgeInsets.zero,
                          itemCount: itemCount,
                          itemBuilder: itemBuilder,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Canonical selected-row treatment for [AdaptiveSelectionSheet].
class AdaptiveSelectionTile extends StatelessWidget {
  const AdaptiveSelectionTile({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.leading,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    return UtilityRow(
      title: title,
      subtitle: subtitle,
      leading: leading,
      selected: selected,
      onTap: onTap,
      trailing:
          trailing ??
          (selected
              ? Icon(
                  Icons.check,
                  color: theme.buttonPrimary,
                  size: IconSize.medium,
                )
              : null),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.sm,
        vertical: Spacing.xs,
      ),
    );
  }
}

class _SelectionSheetHeader extends StatelessWidget {
  const _SelectionSheetHeader({required this.title, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.headingSmall?.copyWith(
            color: theme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (description != null && description!.isNotEmpty) ...[
          const SizedBox(height: Spacing.xs),
          Text(
            description!,
            style: theme.bodySmall?.copyWith(color: theme.textSecondary),
          ),
        ],
      ],
    );
  }
}
