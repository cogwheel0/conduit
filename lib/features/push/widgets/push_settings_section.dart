import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/navigation/routes.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show OpenWebUiAccountEntry;
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../notifications/services/local_notification_service.dart';
import '../../profile/widgets/account_actions.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import 'push_target_actions.dart';
import 'push_target_detail_sheet.dart';

/// The "Push notifications" group of the Notifications page: the master
/// switch, one row per account and connection with its one-tap fix, the
/// privacy explainer, and with Advanced on, delivery options.
class PushSettingsSection extends ConsumerWidget {
  const PushSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    // Push is started from launch; where it never was, this shows it off.
    final push = ref.watch(pushStateIfUsedProvider) ?? const PushState();
    final advanced = ref.watch(
      appSettingsProvider.select((s) => s.advancedFeaturesEnabled),
    );
    final android = Theme.of(context).platform == TargetPlatform.android;
    final available = push.available;
    final showTargets = push.enabled && push.targets.isNotEmpty;
    final accounts = showTargets
        ? pushAccountEntries(ref)
        : const <String, OpenWebUiAccountEntry>{};
    PushCoordinator coordinator() => ref.read(pushCoordinatorProvider.notifier);

    final String subtitle;
    if (available) {
      subtitle = l10n.pushEnabledDescription;
    } else if (android) {
      subtitle = l10n.pushUnavailableAndroid;
    } else {
      subtitle = l10n.pushUnavailableBuild;
    }

    final rows = <Widget>[
      UtilityRow(
        key: const Key('push-enabled'),
        enabled: available,
        title: l10n.pushEnabledTitle,
        subtitle: subtitle,
        toggled: push.enabled,
        trailing: AdaptiveSwitch(
          value: push.enabled,
          onChanged: available
              ? (value) => unawaited(coordinator().setEnabled(value))
              : null,
        ),
        onTap: available
            ? () => unawaited(coordinator().setEnabled(!push.enabled))
            : null,
      ),
      if (!available && android)
        UtilityRow(
          key: const Key('push-get-distributor'),
          title: l10n.pushGetDistributor,
          trailing: _externalLinkIcon(theme),
          onTap: () =>
              launchExternalLink(kUnifiedPushDistributorsUrl, scope: 'push'),
        ),
      if (push.enabled && push.permissionDenied)
        UtilityRow(
          key: const Key('push-permission-denied'),
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.bell_slash,
              android: Icons.notifications_off_outlined,
            ),
            color: theme.warning,
          ),
          title: l10n.pushStatusPermissionDenied,
          subtitle: l10n.pushExplainPermissionDenied,
          showChevron: true,
          onTap: () => _openSystemSettings(context, ref),
        ),
      if (showTargets)
        for (final target in push.targets.values)
          PushTargetRow(
            key: Key('push-target-${target.scope}'),
            target: target,
            title: pushTargetTitle(l10n, target.target, accounts),
          ),
      UtilityRow(
        key: const Key('push-privacy'),
        title: l10n.pushPrivacyTitle,
        showChevron: true,
        onTap: () => context.pushNamed(RouteNames.pushPrivacy),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        settingsSectionGap,
        InsetGroupedList(title: l10n.pushSectionTitle, children: rows),
        if (advanced && push.enabled) ...[
          if (android) ...[settingsSectionGap, const PushDeliverySection()],
          settingsSectionGap,
          InsetGroupedList(
            children: [
              UtilityRow(
                key: const Key('push-reset-keys'),
                title: l10n.pushResetKeys,
                subtitle: l10n.pushResetKeysDescription,
                destructive: true,
                onTap: () => _resetKeys(context, ref),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _openSystemSettings(BuildContext context, WidgetRef ref) async {
    final opened = await ref
        .read(localNotificationServiceProvider)
        .openSystemSettings();
    if (!opened && context.mounted) {
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!
            .notificationSystemSettingsOpenFailed,
        type: AdaptiveSnackBarType.warning,
      );
    }
  }

  Future<void> _resetKeys(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.pushResetKeysConfirmTitle,
      message: l10n.pushResetKeysConfirmMessage,
      confirmText: l10n.pushResetKeysConfirm,
      isDestructive: true,
    );
    if (!confirmed) return;
    unawaited(ref.read(pushCoordinatorProvider.notifier).resetKeys());
  }
}

Widget _externalLinkIcon(ConduitThemeExtension theme) => Icon(
  UiUtils.platformIcon(
    ios: CupertinoIcons.arrow_up_right,
    android: Icons.open_in_new,
  ),
  size: IconSize.medium,
  color: theme.textSecondary,
);

/// One account or connection: its status in plain words, and either its
/// one-tap fix, a spinner, or a check mark. Tapping it opens its details.
class PushTargetRow extends ConsumerWidget {
  const PushTargetRow({super.key, required this.target, required this.title});

  final PushTargetState target;
  final String title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final action = pushTargetAction(target);
    final Widget? trailing;
    if (pushTargetBusy(target)) {
      trailing = const ConduitLoadingIndicator(isCompact: true);
    } else if (action != null) {
      trailing = AdaptiveButton(
        key: Key('push-action-${target.scope}'),
        onPressed: () => runPushTargetAction(context, ref, target, action),
        label: pushActionLabel(l10n, action),
        style: AdaptiveButtonStyle.plain,
        size: AdaptiveButtonSize.small,
      );
    } else if (target.status == PushStatus.on && !target.notificationsOff) {
      trailing = ActiveCheckmark(semanticLabel: l10n.pushStatusOn);
    } else {
      trailing = null;
    }
    return UtilityRow(
      title: title,
      subtitle: pushStatusText(l10n, target),
      leading: Icon(
        target.target.kind == PushTargetKind.hermes
            ? UiUtils.platformIcon(
                ios: CupertinoIcons.desktopcomputer,
                android: Icons.computer_outlined,
              )
            : UiUtils.platformIcon(
                ios: CupertinoIcons.person_crop_circle,
                android: Icons.account_circle_outlined,
              ),
        size: IconSize.large,
        color: theme.textSecondary,
      ),
      preserveTrailingSemantics: true,
      trailing: trailing,
      onTap: () => showPushTargetDetailSheet(context, target.scope),
    );
  }
}

/// Android delivery: Automatic, Google (FCM) or UnifiedPush, and which
/// UnifiedPush distributor.
class PushDeliverySection extends ConsumerStatefulWidget {
  const PushDeliverySection({super.key});

  @override
  ConsumerState<PushDeliverySection> createState() =>
      _PushDeliverySectionState();
}

class _PushDeliverySectionState extends ConsumerState<PushDeliverySection> {
  List<String>? _distributors;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDistributors());
  }

  Future<void> _loadDistributors() async {
    final list = await ref
        .read(pushCoordinatorProvider.notifier)
        .distributors();
    if (mounted) setState(() => _distributors = list);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final push = ref.watch(pushCoordinatorProvider);
    final coordinator = ref.read(pushCoordinatorProvider.notifier);
    final fcm =
        push.relayConfigured &&
        push.availableTransports.contains(PushTransport.fcm);
    final choice = push.androidTransport;
    final distributors = _distributors;
    final selectedDistributor = push.distributor ?? distributors?.firstOrNull;

    Widget option(PushAndroidTransport? value, String title, Key key) =>
        UtilityRow(
          key: key,
          title: title,
          selected: choice == value,
          trailing: choice == value
              ? ActiveCheckmark(semanticLabel: title)
              : null,
          onTap: choice == value
              ? null
              : () => unawaited(
                  coordinator.setAndroidTransport(
                    value,
                    distributor: value == PushAndroidTransport.unifiedPush
                        ? selectedDistributor
                        : push.distributor,
                  ),
                ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InsetGroupedList(
          title: l10n.pushDeliveryTitle,
          children: [
            option(
              null,
              l10n.pushDeliveryAutomatic,
              const Key('push-delivery-auto'),
            ),
            if (fcm)
              option(
                PushAndroidTransport.fcm,
                l10n.pushDeliveryFcm,
                const Key('push-delivery-fcm'),
              ),
            option(
              PushAndroidTransport.unifiedPush,
              l10n.pushDeliveryUnifiedPush,
              const Key('push-delivery-unifiedpush'),
            ),
          ],
        ),
        if (choice == PushAndroidTransport.unifiedPush ||
            (choice == null && !fcm)) ...[
          settingsSectionGap,
          InsetGroupedList(
            title: l10n.pushDistributorTitle,
            children: [
              if (distributors == null)
                const Padding(
                  padding: EdgeInsets.all(Spacing.md),
                  child: Center(
                    child: ConduitLoadingIndicator(isCompact: true),
                  ),
                )
              else if (distributors.isEmpty) ...[
                UtilityRow(
                  key: const Key('push-no-distributor'),
                  title: l10n.pushNoDistributor,
                  foregroundColor: theme.textSecondary,
                ),
                UtilityRow(
                  key: const Key('push-get-distributor'),
                  title: l10n.pushGetDistributor,
                  trailing: _externalLinkIcon(theme),
                  onTap: () => launchExternalLink(
                    kUnifiedPushDistributorsUrl,
                    scope: 'push',
                  ),
                ),
              ] else
                for (final distributor in distributors)
                  UtilityRow(
                    key: Key('push-distributor-$distributor'),
                    title: distributor,
                    selected: distributor == selectedDistributor,
                    trailing: distributor == selectedDistributor
                        ? ActiveCheckmark(semanticLabel: distributor)
                        : null,
                    onTap: distributor == selectedDistributor
                        ? null
                        : () => unawaited(
                            coordinator.setAndroidTransport(
                              choice,
                              distributor: distributor,
                            ),
                          ),
                  ),
            ],
          ),
        ],
      ],
    );
  }
}
