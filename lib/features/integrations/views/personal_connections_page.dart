import 'dart:async';

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

import '../../../core/services/haptic_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/advanced_required_state.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import 'personal_connection_messages.dart';

/// Lists the signed-in account's personal tool servers and terminals and lets
/// the user add, switch, edit and delete them.
///
/// The screen belongs to the Advanced disclosure and to the server's own rule
/// for who may keep personal connections. Existing selections in chat keep
/// working whether or not it is reachable.
class PersonalConnectionsPage extends ConsumerStatefulWidget {
  const PersonalConnectionsPage({super.key});

  @override
  ConsumerState<PersonalConnectionsPage> createState() =>
      _PersonalConnectionsPageState();
}

class _PersonalConnectionsPageState
    extends ConsumerState<PersonalConnectionsPage> {
  /// Switches moved by the user and not yet answered by the server, by kind
  /// and identity, with the state each was moved to.
  final Map<(PersonalConnectionKind, String), bool> _pending = {};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final advanced = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.advancedFeaturesEnabled,
      ),
    );
    final access = ref.watch(personalConnectionsAccessProvider);

    if (!advanced) {
      return UtilityPageScaffold.settings(
        key: const Key('personal-connections-needs-advanced'),
        title: l10n.personalConnectionsTitle,
        children: [
          AdvancedRequiredState(feature: l10n.personalConnectionsTitle),
        ],
      );
    }
    final block = access.block;
    if (block != null) {
      return UtilityPageScaffold.settings(
        key: const Key('personal-connections-unavailable'),
        title: l10n.personalConnectionsTitle,
        children: [Text(personalConnectionsBlockText(l10n, block))],
      );
    }

    final connections = ref.watch(personalConnectionsProvider);
    return UtilityPageScaffold.settings(
      title: l10n.personalConnectionsTitle,
      children: connections.when(
        loading: () => const [
          Center(child: ConduitLoadingIndicator(isCompact: true)),
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
            ? const [Center(child: ConduitLoadingIndicator(isCompact: true))]
            : _content(context, l10n, snapshot),
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
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
        InsetGroupedList(
          key: const Key('personal-connections-cleared'),
          useNativeSurface: PlatformInfo.isIOS,
          children: [
            UtilityRow(
              title: l10n.personalConnectionsSelectionCleared(
                personalSelectionNoticeText(l10n, cleared),
              ),
              trailing: ConduitButton(
                text: l10n.ok,
                isSecondary: true,
                isCompact: true,
                onPressed: () =>
                    ref.read(personalSelectionNoticeProvider.notifier).clear(),
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: Spacing.lg),
      _section(
        context,
        l10n,
        kind: PersonalConnectionKind.toolServer,
        title: l10n.toolServers,
        emptyText: l10n.personalConnectionsEmptyToolServers,
        emptyHint: l10n.personalConnectionsEmptyToolServersHint,
        addLabel: l10n.personalConnectionsAddToolServer,
        entries: snapshot.toolServers,
        owner: snapshot.session,
      ),
      const SizedBox(height: Spacing.lg),
      _section(
        context,
        l10n,
        kind: PersonalConnectionKind.terminal,
        title: l10n.personalConnectionsTerminals,
        emptyText: l10n.personalConnectionsEmptyTerminals,
        emptyHint: l10n.personalConnectionsEmptyTerminalsHint,
        addLabel: l10n.personalConnectionsAddTerminal,
        entries: snapshot.terminals,
        owner: snapshot.session,
        footer: snapshot.terminals.length > 1
            ? l10n.personalConnectionsTerminalOneActive
            : null,
      ),
    ];
  }

  void _add(PersonalConnectionKind kind) => context.pushNamed(
    RouteNames.personalConnectionEditor,
    pathParameters: {
      'kind': personalConnectionKindRouteValue(kind),
      'identity': personalConnectionNewRouteValue,
    },
  );

  Widget _section(
    BuildContext context,
    AppLocalizations l10n, {
    required PersonalConnectionKind kind,
    required String title,
    required String emptyText,
    required String emptyHint,
    required String addLabel,
    required List<PersonalConnectionEntry> entries,
    required PersonalConnectionsSession owner,
    String? footer,
  }) {
    final theme = context.conduitTheme;
    final isTool = kind == PersonalConnectionKind.toolServer;
    final prefix = isTool ? 'personal-tool' : 'personal-terminal';
    final addIcon = UiUtils.platformIcon(
      ios: CupertinoIcons.add_circled,
      android: Icons.add_circle_outline,
    );
    return InsetGroupedList(
      title: title,
      footer: footer,
      useNativeSurface: PlatformInfo.isIOS,
      children: [
        if (entries.isEmpty)
          // The empty list is itself the way to add the first entry.
          UtilityRow(
            key: Key('$prefix-add'),
            title: emptyText,
            subtitle: emptyHint,
            titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
            trailing: Icon(
              addIcon,
              color: theme.buttonPrimary,
              size: IconSize.medium,
            ),
            semanticLabel: '$addLabel. $emptyHint',
            onTap: () => _add(kind),
          )
        else ...[
          for (final entry in entries) _entryRow(l10n, prefix, owner, entry),
          UtilityRow(
            key: Key('$prefix-add'),
            title: addLabel,
            foregroundColor: theme.buttonPrimary,
            leading: Icon(addIcon, color: theme.buttonPrimary),
            onTap: () => _add(kind),
          ),
        ],
      ],
    );
  }

  Widget _entryRow(
    AppLocalizations l10n,
    String prefix,
    PersonalConnectionsSession owner,
    PersonalConnectionEntry entry,
  ) {
    final pending = _pending[(entry.kind, entry.identity)];
    return UtilityRow(
      key: Key('$prefix-${entry.identity}'),
      title: entry.displayName,
      subtitle: entry.editable
          ? personalConnectionPublicEndpoint(entry.url)
          : l10n.personalConnectionsUnsupported,
      subtitleMaxLines: entry.editable ? 1 : 3,
      showChevron: true,
      preserveTrailingSemantics: true,
      onTap: () => context.pushNamed(
        RouteNames.personalConnectionEditor,
        pathParameters: {
          'kind': personalConnectionKindRouteValue(entry.kind),
          'identity': entry.identity,
        },
      ),
      status: pending == null
          ? null
          : const ConduitLoadingIndicator(size: IconSize.small, isCompact: true),
      trailing: AdaptiveSwitch(
        key: Key('$prefix-switch-${entry.identity}'),
        value: pending ?? entry.enabled,
        semanticLabel: entry.displayName,
        onChanged: pending != null
            ? null
            : (value) => _setEnabled(l10n, owner, entry, value),
      ),
    );
  }

  /// Moves the switch at once and saves. A refusal puts it back and says why.
  Future<void> _setEnabled(
    AppLocalizations l10n,
    PersonalConnectionsSession owner,
    PersonalConnectionEntry entry,
    bool value,
  ) async {
    final key = (entry.kind, entry.identity);
    setState(() => _pending[key] = value);
    // The row belongs to the list it was drawn from; a switch drawn for an
    // account that has since gone is refused, not applied to the new one.
    try {
      final outcome = await ref
          .read(personalConnectionsProvider.notifier)
          .save(
            owner,
            entry.kind,
            SetPersonalConnectionEnabled(entry.identity, value),
          );
      if (!mounted) return;
      setState(() => _pending.remove(key));
      if (outcome.stale) {
        UiUtils.showMessage(
          context,
          l10n.personalConnectionsSavedForPreviousAccount,
        );
      } else if (PlatformInfo.isIOS) {
        // Android's switch already clicked when it moved.
        unawaited(ConduitHaptics.success());
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _pending.remove(key));
      UiUtils.showMessage(
        context,
        personalConnectionSaveError(l10n, error),
        isError: true,
      );
    }
  }
}
