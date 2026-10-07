import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit_core/features/notifications/models/notification_target.dart';
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart';
import 'package:conduit_core/services/settings_service.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import 'notification_target_editor.dart';

/// Webhook destinations on the Notifications page.
///
/// Advanced reveals this section and nothing more: it is a disclosure, not a
/// switch. Turning it off hides the controls, and destinations the server
/// already holds keep delivering. The section is also independent of the
/// master toggle and the phone's OS permission, since the server sends these
/// notifications, not this device.
class NotificationTargetsSection extends ConsumerWidget {
  const NotificationTargetsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final advanced = ref.watch(
      appSettingsProvider.select(
        (settings) => settings.advancedFeaturesEnabled,
      ),
    );
    if (!advanced || !ref.watch(notificationTargetsAvailableProvider)) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(notificationTargetsProvider);
    final data = state.asData?.value;
    final targets = [
      for (final target in data?.targets ?? const <NotificationTarget>[])
        if (target.isWebhook) target,
    ];

    return Column(
      children: [
        settingsSectionGap,
        InsetGroupedList(
          title: l10n.notificationTargetsTitle,
          description: l10n.notificationTargetsDescription,
          children: [
            if (data == null && state.isLoading)
              const Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: Center(child: ConduitLoadingIndicator(isCompact: true)),
              )
            else if (data == null)
              UtilityRow(
                title: l10n.notificationTargetsLoadFailed,
                subtitle: l10n.retry,
                onTap: () => _refresh(ref),
              )
            else if (targets.isEmpty)
              UtilityRow(
                title: l10n.notificationTargetsEmpty,
                semanticLabel: l10n.notificationTargetsEmpty,
              )
            else
              for (final target in targets)
                _TargetRow(
                  target: target,
                  onTap: () => _openEditor(context, ref, target),
                ),
            if (data != null)
              UtilityRow(
                key: const Key('notification-targets-add'),
                title: l10n.notificationTargetsAdd,
                showChevron: true,
                onTap: () => _openEditor(context, ref, null),
              ),
            if (data?.stale ?? false)
              UtilityRow(
                title: l10n.notificationTargetsStale,
                subtitle: l10n.retry,
                onTap: () => _refresh(ref),
              ),
          ],
        ),
      ],
    );
  }

  void _refresh(WidgetRef ref) {
    final notifier = ref.read(notificationTargetsProvider.notifier);
    final owner = notifier.captureOwner();
    if (owner == null) return;
    notifier.refresh(owner: owner);
  }

  void _openEditor(
    BuildContext context,
    WidgetRef ref,
    NotificationTarget? target,
  ) {
    // The account is captured here, on the tap, before anything is awaited.
    final notifier = ref.read(notificationTargetsProvider.notifier);
    final owner = notifier.captureOwner();
    showNotificationTargetEditor(
      context,
      notifier: notifier,
      owner: owner,
      events:
          ref.read(notificationTargetsProvider).asData?.value.events ??
          const <NotificationEvent>[],
      target: target,
    );
  }
}

class _TargetRow extends StatelessWidget {
  const _TargetRow({required this.target, required this.onTap});

  final NotificationTarget target;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final delivery = switch (target.delivery) {
      NotificationTarget.deliveryAlways =>
        l10n.notificationTargetDeliveryAlways,
      NotificationTarget.deliveryAway => l10n.notificationTargetDeliveryAway,
      final other => other,
    };
    final status = [
      if (target.isDefault == true) l10n.notificationTargetDefaultBadge,
      target.enabled ? l10n.enabled : l10n.disabled,
    ].join(' · ');
    final subtitle = [?target.maskedUrl, delivery].join(' · ');
    return UtilityRow(
      title: target.id,
      subtitle: subtitle,
      status: Text(
        status,
        style: context.conduitTheme.bodySmall?.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
      semanticLabel: '${target.id}. $status. $subtitle',
      showChevron: true,
      onTap: onTap,
    );
  }
}
