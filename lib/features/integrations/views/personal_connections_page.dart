import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/integrations/personal_connection_edits.dart';
import 'package:conduit_core/features/integrations/personal_connection_settings.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import 'personal_connection_messages.dart';

/// Lists the signed-in account's personal tool servers and terminals and lets
/// the user add, switch, edit and delete them.
///
/// The screen belongs to the Advanced disclosure and to the server's own rule
/// for who may keep personal connections. Existing selections in chat keep
/// working whether or not it is reachable.
class PersonalConnectionsPage extends ConsumerWidget {
  const PersonalConnectionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final advanced = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.advancedFeaturesEnabled,
      ),
    );
    final access = ref.watch(personalConnectionsAccessProvider);

    if (!advanced) {
      return _Unavailable(
        key: const Key('personal-connections-needs-advanced'),
        message: l10n.personalConnectionsNeedsAdvanced,
      );
    }
    final block = access.block;
    if (block != null) {
      return _Unavailable(
        key: const Key('personal-connections-unavailable'),
        message: personalConnectionsBlockText(l10n, block),
      );
    }

    final connections = ref.watch(personalConnectionsProvider);
    return UtilityPageScaffold.settings(
      title: l10n.personalConnectionsTitle,
      children: connections.when(
        loading: () => const [
          Center(child: CircularProgressIndicator.adaptive()),
        ],
        error: (_, _) => [
          Text(l10n.personalConnectionsLoadFailed),
          const SizedBox(height: Spacing.md),
          ConduitButton(
            key: const Key('personal-connections-retry'),
            text: l10n.retry,
            onPressed: () => ref.invalidate(personalConnectionsProvider),
          ),
        ],
        data: (snapshot) => snapshot == null
            ? const [Center(child: CircularProgressIndicator.adaptive())]
            : _content(context, ref, l10n, snapshot),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    PersonalConnectionsSnapshot snapshot,
  ) {
    final theme = context.conduitTheme;
    final cleared = ref.watch(personalSelectionNoticeProvider);
    return [
      Text(
        l10n.personalConnectionsStoredOn(
          snapshot.accountName,
          snapshot.serverName,
        ),
        key: const Key('personal-connections-account'),
        style: AppTypography.bodyMediumStyle.copyWith(color: theme.textPrimary),
      ),
      const SizedBox(height: Spacing.xs),
      Text(
        l10n.personalConnectionsKeyStorageNote,
        style: AppTypography.bodySmallStyle.copyWith(
          color: theme.textSecondary,
        ),
      ),
      if (cleared.isNotEmpty) ...[
        const SizedBox(height: Spacing.md),
        InsetGroupedSection(
          key: const Key('personal-connections-cleared'),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.personalConnectionsSelectionCleared(
                    personalSelectionNoticeText(l10n, cleared),
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(personalSelectionNoticeProvider.notifier).clear(),
                child: Text(l10n.ok),
              ),
            ],
          ),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      _section(
        context,
        ref,
        l10n,
        kind: PersonalConnectionKind.toolServer,
        title: l10n.toolServers,
        emptyText: l10n.personalConnectionsEmptyToolServers,
        addLabel: l10n.personalConnectionsAddToolServer,
        entries: snapshot.toolServers,
        owner: snapshot.session,
      ),
      const SizedBox(height: Spacing.lg),
      _section(
        context,
        ref,
        l10n,
        kind: PersonalConnectionKind.terminal,
        title: l10n.personalConnectionsTerminals,
        emptyText: l10n.personalConnectionsEmptyTerminals,
        addLabel: l10n.personalConnectionsAddTerminal,
        entries: snapshot.terminals,
        owner: snapshot.session,
        footer: snapshot.terminals.length > 1
            ? l10n.personalConnectionsTerminalOneActive
            : null,
      ),
    ];
  }

  Widget _section(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n, {
    required PersonalConnectionKind kind,
    required String title,
    required String emptyText,
    required String addLabel,
    required List<PersonalConnectionEntry> entries,
    required PersonalConnectionsSession owner,
    String? footer,
  }) {
    final isTool = kind == PersonalConnectionKind.toolServer;
    final prefix = isTool ? 'personal-tool' : 'personal-terminal';
    return InsetGroupedList(
      title: title,
      footer: footer,
      children: [
        if (entries.isEmpty)
          UtilityRow(title: emptyText, enabled: false)
        else
          for (final entry in entries)
            UtilityRow(
              key: Key('$prefix-${entry.identity}'),
              title: entry.displayName,
              subtitle: entry.editable
                  ? entry.url
                  : l10n.personalConnectionsUnsupported,
              subtitleMaxLines: entry.editable ? 1 : 3,
              showChevron: true,
              preserveTrailingSemantics: true,
              onTap: () => context.pushNamed(
                RouteNames.personalConnectionEditor,
                pathParameters: {
                  'kind': personalConnectionKindRouteValue(kind),
                  'identity': entry.identity,
                },
              ),
              trailing: AdaptiveSwitch(
                key: Key('$prefix-switch-${entry.identity}'),
                value: entry.enabled,
                semanticLabel: entry.displayName,
                onChanged: (value) =>
                    _setEnabled(context, ref, l10n, owner, entry, value),
              ),
            ),
        UtilityRow(
          key: Key('$prefix-add'),
          title: addLabel,
          leading: Icon(
            UiUtils.platformIcon(
              ios: CupertinoIcons.add_circled,
              android: Icons.add_circle_outline,
            ),
          ),
          onTap: () => context.pushNamed(
            RouteNames.personalConnectionEditor,
            pathParameters: {
              'kind': personalConnectionKindRouteValue(kind),
              'identity': personalConnectionNewRouteValue,
            },
          ),
        ),
      ],
    );
  }

  Future<void> _setEnabled(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    PersonalConnectionsSession owner,
    PersonalConnectionEntry entry,
    bool value,
  ) async {
    // The row belongs to the list it was drawn from; a switch drawn for an
    // account that has since gone is refused, not applied to the new one.
    try {
      await ref
          .read(personalConnectionsProvider.notifier)
          .save(
            owner,
            entry.kind,
            SetPersonalConnectionEnabled(entry.identity, value),
          );
    } catch (error) {
      if (!context.mounted) return;
      UiUtils.showMessage(
        context,
        personalConnectionSaveError(l10n, error),
        isError: true,
      );
    }
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return UtilityPageScaffold.settings(
      title: l10n.personalConnectionsTitle,
      children: [Text(message)],
    );
  }
}
