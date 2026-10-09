import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../hermes/widgets/hermes_connection_switcher.dart';
import '../widgets/account_actions.dart';
import '../widgets/account_sheet.dart';
import '../widgets/settings_page_scaffold.dart';

/// Every account and connection, a card for each place they live: one per
/// Open WebUI server with its accounts, then Hermes with its connections,
/// then Direct with its providers.
///
/// Tap an Open WebUI account or a Hermes connection to switch to it, or a
/// Direct provider to edit it; a card's top row opens its page, and + adds
/// another.
class ManageAccountsPage extends ConsumerWidget {
  const ManageAccountsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final accounts = ref.watch(openWebUiAccountsProvider);

    return UtilityPageScaffold.settings(
      title: l10n.accountsTitle,
      trailing: AdaptiveTooltip(
        message: l10n.accountsAddAccount,
        child: ConduitAdaptiveAppBarIconButton(
          key: const Key('accounts-add'),
          icon: context.usesCupertinoChrome ? CupertinoIcons.add : Icons.add,
          semanticLabel: l10n.accountsAddAccount,
          onPressed: () => showAddAccountSheet(context, ref),
        ),
      ),
      children: [
        ...accounts.when(
          data: (entries) => _openWebUiCards(context, ref, entries),
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(Spacing.xl),
              child: Center(child: ConduitLoadingIndicator()),
            ),
          ],
          error: (_, _) => [
            InsetGroupedList(children: [UtilityRow(title: l10n.errorMessage)]),
            settingsSectionGap,
          ],
        ),
        const _HermesCard(),
        settingsSectionGap,
        const _DirectCard(),
        // With one account, Settings' Sign out already signs out of it.
        if ((accounts.value?.length ?? 0) > 1) ...[
          settingsSectionGap,
          InsetGroupedList(
            children: [
              UtilityRow(
                key: const Key('accounts-sign-out-all'),
                title: l10n.accountsSignOutAll,
                leading: _RowGlyph(
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.square_arrow_left,
                    android: Icons.logout,
                  ),
                  color: context.conduitTheme.error,
                ),
                destructive: true,
                onTap: () => signOutOfAllAccounts(context, ref),
              ),
            ],
          ),
        ],
      ],
    );
  }

  List<Widget> _openWebUiCards(
    BuildContext context,
    WidgetRef ref,
    List<OpenWebUiAccountEntry> entries,
  ) {
    final l10n = AppLocalizations.of(context)!;
    if (entries.isEmpty) {
      return [
        InsetGroupedList(
          key: const Key('accounts-openwebui'),
          children: [
            UtilityRow(
              title: l10n.backendChooserOpenWebUITitle,
              leading: const _RowLogo('assets/icons/open_webui.png'),
            ),
            _AddRow(
              key: const Key('accounts-openwebui-add'),
              title: l10n.connectOpenWebUITitle,
              onTap: () => showAddAccountSheet(context, ref),
            ),
          ],
        ),
        settingsSectionGap,
      ];
    }
    final byServer = <String, List<OpenWebUiAccountEntry>>{};
    for (final entry in entries) {
      byServer.putIfAbsent(entry.server.id, () => []).add(entry);
    }
    return [
      for (final group in byServer.values) ...[
        InsetGroupedList(
          key: Key('accounts-server-${group.first.server.id}'),
          children: [
            UtilityRow(
              key: Key('accounts-server-open-${group.first.server.id}'),
              title: serverDisplayName(group.first.server),
              leading: _ServerBadge(
                name: serverDisplayName(group.first.server),
              ),
              showChevron: true,
              onTap: () => context.pushNamed(
                RouteNames.serverAddresses,
                extra: group.first.server.id,
              ),
            ),
            for (final entry in group)
              SavedAccountRow(
                key: Key('accounts-row-${entry.id}'),
                entry: entry,
              ),
          ],
        ),
        settingsSectionGap,
      ],
    ];
  }
}

/// The saved Hermes connections, the one in use checked while Hermes is on.
class _HermesCard extends ConsumerWidget {
  const _HermesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connections = ref.watch(hermesConnectionsProvider);
    final activeId = ref.watch(hermesActiveConnectionIdProvider);
    final enabled = ref.watch(hermesEnabledProvider);
    return InsetGroupedList(
      key: const Key('accounts-hermes'),
      children: [
        UtilityRow(
          key: const Key('accounts-hermes-open'),
          title: l10n.hermesAgentSettingsTitle,
          leading: const _RowLogo('assets/icons/hermes_agent.png'),
          showChevron: true,
          onTap: () => context.pushNamed(RouteNames.hermesSettings),
        ),
        for (final connection in connections)
          _HermesConnectionRow(
            key: Key('accounts-hermes-${connection.id}'),
            name: connection.name,
            summary: hermesConnectionSummary(connection),
            desktop: connection.mode == HermesBackendMode.desktopGateway,
            inUse: enabled && connection.id == activeId,
            onTap: () => useHermesConnection(context, ref, connection.id),
            onEdit: () => showAccountSheet(
              context,
              EditHermesConnectionRequest(connection.id),
            ),
          ),
        if (connections.isEmpty)
          _AddRow(
            key: const Key('accounts-hermes-add'),
            title: l10n.hermesAddConnection,
            onTap: () =>
                showAddAccountSheet(context, ref, kind: AccountKind.hermes),
          ),
      ],
    );
  }
}

class _HermesConnectionRow extends StatelessWidget {
  const _HermesConnectionRow({
    super.key,
    required this.name,
    required this.summary,
    required this.desktop,
    required this.inUse,
    required this.onTap,
    required this.onEdit,
  });

  final String name;
  final String summary;
  final bool desktop;
  final bool inUse;
  final VoidCallback onTap;

  /// A long press edits the connection; a tap only puts it in use.
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final row = UtilityRow(
      title: name,
      subtitle: summary,
      leading: _RowGlyph(
        desktop
            ? UiUtils.platformIcon(
                ios: CupertinoIcons.desktopcomputer,
                android: Icons.computer_outlined,
              )
            : UiUtils.platformIcon(
                ios: CupertinoIcons.cloud,
                android: Icons.cloud_outlined,
              ),
      ),
      selected: inUse,
      preserveTrailingSemantics: true,
      onTap: inUse ? null : onTap,
      trailing: inUse
          ? ActiveCheckmark(semanticLabel: l10n.accountsActive)
          : null,
    );
    return Semantics(
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.edit): onEdit,
      },
      child: GestureDetector(onLongPress: onEdit, child: row),
    );
  }
}

/// The Direct providers: Apple's built-in models where there are any, then
/// those saved on this device. All the enabled ones are used at once, so
/// none is checked; tapping one opens it.
class _DirectCard extends ConsumerWidget {
  const _DirectCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directConnectionProfilesProvider);
    // The Apple toggles default to on: only where Apple Intelligence can
    // exist are they rows.
    final apple = ref.watch(applePccPlatformSupportedProvider);
    final appleOnDevice = apple && ref.watch(appleOnDeviceEnabledProvider);
    final applePcc = apple && ref.watch(applePccEnabledProvider);
    final saved = profiles.value ?? const <DirectConnectionProfile>[];
    void openDirect() => context.pushNamed(RouteNames.directConnections);
    final appleIcon = UiUtils.platformIcon(
      ios: CupertinoIcons.device_phone_portrait,
      android: Icons.phone_iphone,
    );
    return InsetGroupedList(
      key: const Key('accounts-direct'),
      children: [
        UtilityRow(
          key: const Key('accounts-direct-open'),
          title: l10n.directConnectionsTitle,
          leading: _RowGlyph(
            UiUtils.platformIcon(
              ios: CupertinoIcons.link,
              android: Icons.hub_outlined,
            ),
          ),
          showChevron: true,
          onTap: openDirect,
        ),
        if (appleOnDevice)
          UtilityRow(
            key: const Key('accounts-direct-apple-on-device'),
            title: l10n.backendChooserAppleOnDeviceTitle,
            leading: _RowGlyph(appleIcon),
            showChevron: true,
            onTap: openDirect,
          ),
        if (applePcc)
          UtilityRow(
            key: const Key('accounts-direct-apple-pcc'),
            title: l10n.backendChooserApplePccTitle,
            leading: _RowGlyph(
              UiUtils.platformIcon(
                ios: CupertinoIcons.lock_shield,
                android: Icons.cloud_outlined,
              ),
            ),
            showChevron: true,
            onTap: openDirect,
          ),
        for (final profile in saved)
          UtilityRow(
            key: Key('accounts-direct-${profile.id}'),
            title: profile.name,
            subtitle: [
              _directProviderName(profile, l10n),
              if (!profile.enabled) l10n.disabledLabel,
            ].join(' · '),
            leading: _RowGlyph(
              profile.adapterKey == kOllamaAdapterKey
                  ? UiUtils.platformIcon(
                      ios: CupertinoIcons.desktopcomputer,
                      android: Icons.computer_outlined,
                    )
                  : UiUtils.platformIcon(
                      ios: CupertinoIcons.cloud,
                      android: Icons.cloud_outlined,
                    ),
            ),
            showChevron: true,
            onTap: () => showAccountSheet(
              context,
              EditDirectConnectionRequest(profile.id),
            ),
          ),
        // Not offered while the saved ones are unread or unreadable: the
        // Direct page says which, and adds from there.
        if (profiles.hasValue && saved.isEmpty && !appleOnDevice && !applePcc)
          _AddRow(
            key: const Key('accounts-direct-add'),
            title: l10n.addDirectConnection,
            onTap: () =>
                showAddAccountSheet(context, ref, kind: AccountKind.direct),
          ),
      ],
    );
  }

  static String _directProviderName(
    DirectConnectionProfile profile,
    AppLocalizations l10n,
  ) {
    if (profile.adapterKey == kOllamaAdapterKey) return l10n.ollama;
    if (profile.isOpenRouter) return l10n.openRouterProviderName;
    return l10n.openAICompatible;
  }
}

/// The row an empty card offers to add its first entry with.
class _AddRow extends StatelessWidget {
  const _AddRow({super.key, required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = context.conduitTheme.buttonPrimary;
    return UtilityRow(
      title: title,
      foregroundColor: accent,
      leading: _RowGlyph(
        UiUtils.platformIcon(ios: CupertinoIcons.add, android: Icons.add),
        color: accent,
      ),
      onTap: onTap,
    );
  }
}

/// Up to two letters for a server, in a circle: the initials of the first
/// two words of its name, else the first letter of its host.
class _ServerBadge extends StatelessWidget {
  const _ServerBadge({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .take(2)
        .map((word) => word.characters.first.toUpperCase())
        .join();
    return Container(
      width: IconSize.xl,
      height: IconSize.xl,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.groupedBackground,
        shape: BoxShape.circle,
      ),
      child: Text(
        initials,
        maxLines: 1,
        style: AppTypography.labelSmallStyle.copyWith(
          color: theme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A card row's plain glyph, in a fixed box so every title lines up.
class _RowGlyph extends StatelessWidget {
  const _RowGlyph(this.icon, {this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Icon(
        icon,
        color: color ?? context.conduitTheme.iconSecondary,
        size: IconSize.medium,
      ),
    );
  }
}

/// A card's top-row logo, tinted like the glyphs.
class _RowLogo extends StatelessWidget {
  const _RowLogo(this.asset);

  final String asset;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: IconSize.xl,
      height: IconSize.xl,
      child: Center(
        child: Image.asset(
          asset,
          width: IconSize.medium + 2,
          height: IconSize.medium + 2,
          color: context.conduitTheme.textPrimary,
          colorBlendMode: BlendMode.srcIn,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}
