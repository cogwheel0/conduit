import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/ports/ui_request_port.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';

/// Up to two initials for a Hermes connection name; "HA" (Hermes Agent)
/// without a usable name.
String hermesConnectionInitials(String? name) {
  final words = (name ?? '')
      .split(RegExp(r'[\s._-]+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return 'HA';
  final initials = words.length == 1
      ? words.single.characters.take(2).toString()
      : '${words[0].characters.first}${words[1].characters.first}';
  return initials.toUpperCase();
}

/// "Desktop Gateway · host" style summary of a saved connection.
String hermesConnectionSummary(HermesConnectionProfile profile) {
  final mode = profile.mode == HermesBackendMode.desktopGateway
      ? 'Desktop Gateway'
      : 'Responses API';
  final host = Uri.tryParse(profile.baseUrl)?.host ?? '';
  return host.isEmpty ? mode : '$mode · $host';
}

/// The app's [HermesConnectionSwitchPrompt]: asks, through the UI request
/// port, whether to switch to [connectionName] to continue a chat's session.
Future<bool> confirmHermesConnectionSwitch(
  UiRequestPort requests,
  String connectionName,
) async {
  final context = NavigationService.context;
  final l10n = context == null ? null : AppLocalizations.of(context);
  if (l10n == null) return false;
  return requests.confirm(
    title: l10n.hermesSwitchConnectionPromptTitle(connectionName),
    message: l10n.hermesSwitchConnectionPromptMessage(connectionName),
    confirmLabel: l10n.hermesSwitchConnectionConfirm,
    cancelLabel: l10n.hermesKeepCurrentConnection,
  );
}

/// Makes [connectionId] the active Hermes connection, reporting a failure to
/// the user. Returns whether the switch happened.
Future<bool> switchHermesConnection(
  BuildContext context,
  WidgetRef ref,
  String connectionId,
) async {
  final failureMessage = AppLocalizations.of(context)!
      .hermesSwitchConnectionFailed;
  try {
    await ref
        .read(hermesConfigProvider.notifier)
        .setActiveConnection(connectionId);
    return true;
  } catch (error) {
    DebugLogger.warning(
      'connection-switch-failed',
      scope: 'hermes/connections',
      data: {'errorType': error.runtimeType.toString()},
    );
    if (context.mounted) {
      AdaptiveSnackBar.show(
        context,
        message: failureMessage,
        type: AdaptiveSnackBarType.error,
      );
    }
    return false;
  }
}

/// Lists the saved connections with the active one checked; picking another
/// switches to it.
Future<void> showHermesConnectionPicker(
  BuildContext context,
  WidgetRef ref,
) async {
  final connections = ref.read(hermesConnectionsProvider);
  final activeId = ref.read(hermesActiveConnectionIdProvider);
  final l10n = AppLocalizations.of(context)!;
  final picked = await showAdaptiveSelectionSheet<String>(
    context: context,
    builder: (sheetContext) => AdaptiveSelectionSheet(
      title: l10n.hermesSwitchConnectionTitle,
      itemCount: connections.length,
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.75,
      itemBuilder: (context, index) {
        final connection = connections[index];
        return AdaptiveSelectionTile(
          key: ValueKey<String>('hermes-connection-option-${connection.id}'),
          title: connection.name,
          subtitle: hermesConnectionSummary(connection),
          selected: connection.id == activeId,
          onTap: () => Navigator.of(sheetContext).pop(connection.id),
        );
      },
    ),
  );
  if (picked == null || picked == activeId || !context.mounted) return;
  await switchHermesConnection(context, ref, picked);
}

/// Sidebar header naming the active Hermes connection. With more than one
/// saved connection it opens [showHermesConnectionPicker].
class HermesConnectionSwitcherTile extends ConsumerWidget {
  const HermesConnectionSwitcherTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(hermesActiveConnectionNameProvider);
    final count = ref.watch(hermesConnectionsProvider).length;
    if (name == null) return const SizedBox.shrink();
    final theme = context.conduitTheme;
    final canSwitch = count > 1;
    final label = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTypography.bodyMediumStyle.copyWith(
        color: theme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: theme.surfaceContainer,
            child: Text(
              hermesConnectionInitials(name),
              style: AppTypography.labelSmallStyle.copyWith(
                color: theme.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(child: label),
          if (canSwitch)
            Icon(
              Icons.unfold_more_rounded,
              size: IconSize.listItem,
              color: theme.iconSecondary,
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.xs,
        Spacing.sm,
        Spacing.xs,
      ),
      child: Semantics(
        button: canSwitch,
        label: canSwitch
            ? AppLocalizations.of(context)!.hermesSwitchConnectionTitle
            : null,
        child: InkWell(
          key: const ValueKey<String>('hermes-connection-switcher'),
          borderRadius: BorderRadius.circular(AppBorderRadius.card),
          onTap: canSwitch
              ? () => showHermesConnectionPicker(context, ref)
              : null,
          child: row,
        ),
      ),
    );
  }
}
