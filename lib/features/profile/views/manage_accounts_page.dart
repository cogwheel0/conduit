import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/account_actions.dart';
import '../widgets/settings_page_scaffold.dart';

/// Every saved Open WebUI account, grouped by the server it is on.
///
/// Tap an account to switch to it; sign out of any one of them; add another
/// account on a saved server or on a new one.
class ManageAccountsPage extends ConsumerWidget {
  const ManageAccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final accounts = ref.watch(openWebUiAccountsProvider);

    return UtilityPageScaffold.settings(
      title: l10n.accountsTitle,
      children: accounts.when(
        data: (entries) => _buildSections(context, ref, entries),
        loading: () => [
          const Padding(
            padding: EdgeInsets.all(Spacing.xl),
            child: Center(child: ConduitLoadingIndicator()),
          ),
        ],
        error: (_, _) => [
          InsetGroupedList(
            children: [UtilityRow(title: l10n.errorMessage)],
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    WidgetRef ref,
    List<OpenWebUiAccountEntry> entries,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final byServer = <String, List<OpenWebUiAccountEntry>>{};
    for (final entry in entries) {
      byServer.putIfAbsent(entry.server.id, () => []).add(entry);
    }

    return [
      for (final group in byServer.values) ...[
        InsetGroupedList(
          key: Key('accounts-server-${group.first.server.id}'),
          title: serverDisplayName(group.first.server),
          children: [
            for (final entry in group) _AccountRow(entry: entry),
            UtilityRow(
              key: Key('accounts-add-on-${group.first.server.id}'),
              title: l10n.accountsAddOnThisServer,
              leading: _rowIcon(
                context,
                UiUtils.platformIcon(
                  ios: CupertinoIcons.person_badge_plus,
                  android: Icons.person_add_alt,
                ),
              ),
              onTap: () => openAddAccount(
                context,
                ref,
                serverId: group.first.server.id,
              ),
            ),
          ],
        ),
        settingsSectionGap,
      ],
      InsetGroupedList(
        children: [
          UtilityRow(
            key: const Key('accounts-add-new-server'),
            title: l10n.accountsNewServer,
            leading: _rowIcon(
              context,
              UiUtils.platformIcon(
                ios: CupertinoIcons.add_circled,
                android: Icons.add_circle_outline,
              ),
            ),
            onTap: () => openAddAccount(context, ref),
          ),
        ],
      ),
    ];
  }

  static Widget _rowIcon(BuildContext context, IconData icon) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Icon(
        icon,
        color: context.conduitTheme.buttonPrimary,
        size: IconSize.medium,
      ),
    );
  }
}

class _AccountRow extends ConsumerWidget {
  const _AccountRow({required this.entry});

  final OpenWebUiAccountEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final name = accountDisplayName(entry, l10n);
    return UtilityRow(
      key: Key('accounts-row-${entry.id}'),
      title: name,
      subtitle: accountDetailLine(entry, l10n),
      leading: SavedAccountAvatar(entry: entry, size: IconSize.xl),
      selected: entry.isActive,
      preserveTrailingSemantics: true,
      onTap: entry.isActive
          ? null
          : () => switchToSavedAccount(context, ref, entry.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entry.isActive)
            Semantics(
              label: l10n.accountsActive,
              child: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.checkmark_alt,
                  android: Icons.check,
                ),
                color: theme.buttonPrimary,
                size: IconSize.medium,
              ),
            ),
          AdaptiveButton.icon(
            key: Key('accounts-sign-out-${entry.id}'),
            semanticLabel: l10n.accountsSignOutOf(name),
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.square_arrow_left,
              android: Icons.logout,
            ),
            iconColor: theme.error,
            style: AdaptiveButtonStyle.plain,
            // A row of a scrolling list: no native view per row.
            useNative: false,
            onPressed: () => signOutOfSavedAccount(context, ref, entry),
          ),
        ],
      ),
    );
  }
}
