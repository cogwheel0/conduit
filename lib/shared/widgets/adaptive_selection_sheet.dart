import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../theme/theme_extensions.dart';
import 'themed_sheets.dart';
import 'utility_components.dart';

@immutable
class AdaptiveSelectionItem<T> {
  const AdaptiveSelectionItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.leading,
    this.enabled = true,
  });

  final T value;
  final String label;
  final String? subtitle;
  final Widget? leading;
  final bool enabled;
}

/// Shared single and multiple-choice sheet geometry.
abstract final class AdaptiveSelectionSheet {
  static Future<T?> showSingle<T>({
    required BuildContext context,
    required String title,
    required List<AdaptiveSelectionItem<T>> items,
    required T selected,
  }) {
    return ThemedSheets.showSurface<T>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => _SelectionSheetFrame(
        title: title,
        child: InsetGroupedList(
          children: [
            for (final item in items)
              UtilityRow(
                title: item.label,
                subtitle: item.subtitle,
                leading: item.leading,
                selected: item.value == selected,
                enabled: item.enabled,
                onTap: item.enabled
                    ? () => Navigator.of(sheetContext).pop(item.value)
                    : null,
                trailing: item.value == selected
                    ? Icon(
                        sheetContext.usesCupertinoChrome
                            ? CupertinoIcons.check_mark
                            : Icons.check,
                        color: sheetContext.conduitTheme.buttonPrimary,
                        size: IconSize.medium,
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }

  static Future<Set<T>?> showMultiple<T>({
    required BuildContext context,
    required String title,
    required String cancelLabel,
    required String doneLabel,
    required List<AdaptiveSelectionItem<T>> items,
    required Set<T> selected,
  }) {
    return ThemedSheets.showSurface<Set<T>>(
      context: context,
      useRootNavigator: true,
      builder: (sheetContext) => _MultipleSelectionSheet<T>(
        title: title,
        cancelLabel: cancelLabel,
        doneLabel: doneLabel,
        items: items,
        initialSelection: selected,
      ),
    );
  }
}

class _SelectionSheetFrame extends StatelessWidget {
  const _SelectionSheetFrame({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.68,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: context.conduitTheme.headingSmall,
          ),
          const SizedBox(height: Spacing.md),
          Expanded(
            child: Scrollbar(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MultipleSelectionSheet<T> extends StatefulWidget {
  const _MultipleSelectionSheet({
    required this.title,
    required this.cancelLabel,
    required this.doneLabel,
    required this.items,
    required this.initialSelection,
  });

  final String title;
  final String cancelLabel;
  final String doneLabel;
  final List<AdaptiveSelectionItem<T>> items;
  final Set<T> initialSelection;

  @override
  State<_MultipleSelectionSheet<T>> createState() =>
      _MultipleSelectionSheetState<T>();
}

class _MultipleSelectionSheetState<T>
    extends State<_MultipleSelectionSheet<T>> {
  late final Set<T> _selection = Set<T>.of(widget.initialSelection);

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Column(
        children: [
          Row(
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(widget.cancelLabel),
              ),
              Expanded(
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: context.conduitTheme.headingSmall,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(_selection),
                child: Text(widget.doneLabel),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Expanded(
            child: Scrollbar(
              child: SingleChildScrollView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: InsetGroupedList(
                  children: [
                    for (final item in widget.items)
                      UtilityRow(
                        title: item.label,
                        subtitle: item.subtitle,
                        leading: item.leading,
                        enabled: item.enabled,
                        selected: _selection.contains(item.value),
                        onTap: item.enabled
                            ? () => setState(() {
                                if (!_selection.add(item.value)) {
                                  _selection.remove(item.value);
                                }
                              })
                            : null,
                        trailing: _selection.contains(item.value)
                            ? Icon(
                                context.usesCupertinoChrome
                                    ? CupertinoIcons.check_mark
                                    : Icons.check,
                                color: context.conduitTheme.buttonPrimary,
                                size: IconSize.medium,
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
