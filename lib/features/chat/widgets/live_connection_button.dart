import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/locale_display_formatters.dart';
import '../../../shared/widgets/adaptive_toolbar_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';

/// The existing socket owns reconnection and health checks; this only observes it.
final liveConnectionDisconnectedProvider = StreamProvider.autoDispose<bool>((
  ref,
) async* {
  if (!ref.watch(openWebUiAccountAvailableProvider)) return;
  final service = ref.watch(socketServiceProvider);
  if (service == null) return;
  yield !service.currentHealth.isConnected;
  yield* service.healthStream.map((health) => !health.isConnected).distinct();
});

class LiveConnectionButton extends ConsumerStatefulWidget {
  const LiveConnectionButton({super.key});

  @override
  ConsumerState<LiveConnectionButton> createState() =>
      _LiveConnectionButtonState();
}

class _LiveConnectionButtonState extends ConsumerState<LiveConnectionButton> {
  bool _reconnecting = false;
  bool _showingDetails = false;

  Future<void> _showDetails() async {
    if (_showingDetails || _reconnecting) return;
    final service = ref.read(socketServiceProvider);
    if (service == null) return;
    // The navigator outlives this indicator if the socket reconnects while
    // details are open. Retry still belongs to the same account/service.
    final ownerContext = Navigator.of(context).context;
    final container = ProviderScope.containerOf(ownerContext, listen: false);
    _showingDetails = true;
    try {
      final l10n = AppLocalizations.of(context)!;
      final health = service.currentHealth;
      final message = [
        l10n.liveConnectionDetailsMessage,
        '',
        switch (health.transport) {
          'websocket' => l10n.socketTransportWebSocket,
          'polling' => l10n.socketTransportPolling,
          _ => l10n.socketTransportUnknown,
        },
        '${l10n.socketReconnectsLabel}: ${LocaleDisplayFormatters.integer(context, health.reconnectCount)}',
        if (health.lastHeartbeat case final heartbeat?)
          l10n.socketLastHeartbeat(
            LocaleDisplayFormatters.relativeTime(l10n, heartbeat),
          ),
      ].join('\n');
      final retry = await _showDetailsDialog(message);
      if (retry &&
          ownerContext.mounted &&
          container.read(socketServiceProvider) == service &&
          !service.currentHealth.isConnected) {
        await _reconnect(ownerContext);
      }
    } finally {
      _showingDetails = false;
    }
  }

  Future<bool> _showDetailsDialog(String message) async {
    final l10n = AppLocalizations.of(context)!;
    if (PlatformUiCapabilities.usesNativeIOS26) {
      try {
        final result = await NativeSheetBridge.instance.presentSheet(
          rethrowErrors: true,
          root: NativeSheetDetailConfig(
            id: 'live-connection-details',
            title: l10n.liveConnectionDetailsTitle,
            maxHeightFraction: 0.5,
            sections: [
              NativeSheetSectionConfig(
                footer: message,
                items: [
                  NativeSheetItemConfig(
                    id: 'status',
                    title: l10n.socketDisconnected,
                    sfSymbol: 'icloud.slash',
                    kind: NativeSheetItemKind.info,
                  ),
                ],
              ),
              NativeSheetSectionConfig(
                items: [
                  NativeSheetItemConfig(
                    id: 'retry',
                    title: l10n.retry,
                    sfSymbol: 'arrow.clockwise',
                    showsDisclosure: false,
                    dismissOnSelect: true,
                    actionId: 'retry',
                  ),
                ],
              ),
            ],
          ),
        );
        return result?.actionId == 'retry';
      } catch (_) {
        // Keep details and retry available when native presentation fails.
      }
      if (!mounted) return false;
    }
    var retry = false;
    await AdaptiveAlertDialog.show(
      context: context,
      title: l10n.liveConnectionDetailsTitle,
      message: message,
      actions: [
        AlertAction(title: l10n.close, onPressed: () {}),
        AlertAction(
          title: l10n.retry,
          style: AlertActionStyle.primary,
          onPressed: () => retry = true,
        ),
      ],
    );
    return retry;
  }

  Future<void> _reconnect(BuildContext ownerContext) async {
    if (_reconnecting) return;
    final container = ProviderScope.containerOf(ownerContext, listen: false);
    final service = container.read(socketServiceProvider);
    if (service == null) return;
    _reconnecting = true;
    if (mounted) setState(() {});
    var connected = false;
    try {
      connected = await service.ensureConnected();
    } catch (_) {
      // Show a localized recovery message, never raw transport details.
    }
    _reconnecting = false;
    if (mounted) setState(() {});
    if (ownerContext.mounted &&
        !connected &&
        container.read(socketServiceProvider) == service) {
      AdaptiveSnackBar.show(
        ownerContext,
        message: AppLocalizations.of(ownerContext)!.liveConnectionRetryFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_reconnecting) {
      return SizedBox.square(
        dimension: conduitScaledControlExtent(context),
        child: Center(
          child: AdaptiveProgressIndicator(semanticLabel: l10n.connecting),
        ),
      );
    }
    return ConduitAdaptiveAppBarIconButton(
      key: const ValueKey('live-connection-retry'),
      icon: Icons.cloud_off_outlined,
      iosSymbol: 'icloud.slash',
      semanticLabel: l10n.liveConnectionDetails,
      iconColor: context.conduitTheme.error,
      onPressed: _showDetails,
    );
  }
}
