import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import '../../../core/utils/message_action_settings.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/utility_components.dart';

class MessageActionsSettingsPage extends ConsumerWidget {
  const MessageActionsSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final saved = ref.watch(appSettingsProvider).inlineMessageActions;
    final selected = saved ?? const <String>[];
    final notifier = ref.read(appSettingsProvider.notifier);
    final actions = messageActionSettings(l10n);
    final inline = [
      for (final id in selected)
        for (final action in actions)
          if (action.id == id) action,
    ];
    final overflow = saved == null
        ? const <({String id, String label, String symbol})>[]
        : actions.where((action) => !selected.contains(action.id));
    Widget row(
      ({String id, String label, String symbol}) action, {
      int? index,
    }) {
      final visible = selected.contains(action.id);
      return UtilityRow(
        key: ValueKey(action.id),
        title: action.label,
        toggled: visible,
        preserveTrailingSemantics: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AdaptiveSwitch(
              value: visible,
              onChanged: (value) =>
                  notifier.setMessageActionVisible(action.id, value),
            ),
            if (index != null)
              ReorderableDragStartListener(
                key: ValueKey('message-action-drag-${action.id}'),
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(Spacing.sm),
                  child: Icon(
                    UiUtils.platformIcon(
                      ios: CupertinoIcons.line_horizontal_3,
                      android: Icons.drag_handle,
                    ),
                    semanticLabel: l10n.messageActionsReorder,
                    color: context.conduitTheme.iconSecondary,
                  ),
                ),
              ),
          ],
        ),
        onTap: () => notifier.setMessageActionVisible(action.id, !visible),
      );
    }

    return UtilityPageScaffold.settings(
      title: l10n.messageActionsTitle,
      children: [
        Text(l10n.messageActionsDescription),
        InsetGroupedSection(
          child: UtilityRow(
            title: l10n.messageActionsAutomatic,
            toggled: saved == null,
            trailing: AdaptiveSwitch(
              value: saved == null,
              onChanged: (value) => notifier.setInlineMessageActions(
                value ? null : defaultInlineMessageActions,
              ),
            ),
            onTap: () => notifier.setInlineMessageActions(
              saved == null ? defaultInlineMessageActions : null,
            ),
          ),
        ),
        if (inline.isNotEmpty)
          InsetGroupedList(
            title: l10n.messageActionsInline,
            children: [
              ReorderableList(
                shrinkWrap: true,
                primary: false,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: inline.length,
                itemBuilder: (_, index) => row(inline[index], index: index),
                onReorderItem: (from, to) {
                  final ordered = inline.map((action) => action.id).toList();
                  ordered.insert(to, ordered.removeAt(from));
                  notifier.setInlineMessageActions(ordered);
                },
                proxyDecorator: (child, _, _) => AdaptiveCard(
                  margin: EdgeInsets.zero,
                  color: context.conduitTheme.groupedSurface,
                  borderRadius: BorderRadius.circular(AppBorderRadius.md),
                  child: child,
                ),
              ),
            ],
          ),
        if (overflow.isNotEmpty)
          InsetGroupedList(
            title: l10n.more,
            children: [for (final action in overflow) row(action)],
          ),
        InsetGroupedSection(
          child: UtilityRow(
            title: l10n.messageActionsReset,
            onTap: () => notifier.setInlineMessageActions(null),
          ),
        ),
      ],
    );
  }
}
