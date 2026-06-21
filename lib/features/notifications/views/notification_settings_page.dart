import 'dart:async';

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../profile/widgets/customization_tile.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../services/local_notification_service.dart';

/// Notification preferences. The master toggle requests OS permission on
/// opt-in. The three Open WebUI-aligned prefs (master / sound / sound-always)
/// are mirrored to the server for cross-device parity; the rest are local-only.
class NotificationSettingsPage extends ConsumerWidget {
  const NotificationSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final settings = ref.watch(appSettingsProvider);
    final notifier = ref.read(appSettingsProvider.notifier);
    final enabled = settings.notificationsEnabled;

    Widget tile({
      required IconData icon,
      required String title,
      required String subtitle,
      required bool value,
      required ValueChanged<bool> onChanged,
      bool dependantOnMaster = true,
    }) {
      final interactive = !dependantOnMaster || enabled;
      return Opacity(
        opacity: interactive ? 1 : 0.5,
        child: CustomizationTile(
          leading: SettingsIconBadge(icon: icon, color: theme.buttonPrimary),
          title: title,
          subtitle: subtitle,
          showChevron: false,
          trailing: AdaptiveSwitch(
            value: value,
            onChanged: interactive ? onChanged : null,
          ),
          onTap: interactive ? () => onChanged(!value) : null,
        ),
      );
    }

    return SettingsPageScaffold(
      title: l10n.notificationsTitle,
      children: [
        tile(
          icon: CupertinoIcons.bell_fill,
          title: l10n.notificationsEnabledTitle,
          subtitle: l10n.notificationsEnabledDescription,
          value: enabled,
          dependantOnMaster: false,
          onChanged: (value) => _setMaster(context, ref, value),
        ),
        const SizedBox(height: Spacing.sm),
        SettingsSectionHeader(title: l10n.notificationSystemTitle),
        const SizedBox(height: Spacing.sm),
        tile(
          icon: CupertinoIcons.app_badge,
          title: l10n.notificationInAppBannerTitle,
          subtitle: l10n.notificationInAppBannerDescription,
          value: settings.notificationInAppBanner,
          onChanged: notifier.setNotificationInAppBanner,
        ),
        const SizedBox(height: Spacing.sm),
        tile(
          icon: CupertinoIcons.bell,
          title: l10n.notificationSystemTitle,
          subtitle: l10n.notificationSystemDescription,
          value: settings.notificationSystem,
          onChanged: notifier.setNotificationSystem,
        ),
        const SizedBox(height: Spacing.sm),
        tile(
          icon: CupertinoIcons.speaker_2_fill,
          title: l10n.notificationSoundTitle,
          subtitle: l10n.notificationSoundDescription,
          value: settings.notificationSound,
          onChanged: (value) => _setSound(ref, value),
        ),
        const SizedBox(height: Spacing.sm),
        tile(
          icon: CupertinoIcons.speaker_3_fill,
          title: l10n.notificationSoundAlwaysTitle,
          subtitle: l10n.notificationSoundAlwaysDescription,
          value: settings.notificationSoundAlways,
          onChanged: (value) => _setSoundAlways(ref, value),
        ),
        const SizedBox(height: Spacing.lg),
        SettingsSectionHeader(title: l10n.notificationsTitle),
        const SizedBox(height: Spacing.sm),
        tile(
          icon: CupertinoIcons.chat_bubble_2_fill,
          title: l10n.notificationChatTitle,
          subtitle: l10n.notificationChatDescription,
          value: settings.notificationChatEnabled,
          onChanged: notifier.setNotificationChatEnabled,
        ),
        const SizedBox(height: Spacing.sm),
        tile(
          icon: CupertinoIcons.number,
          title: l10n.notificationChannelTitle,
          subtitle: l10n.notificationChannelDescription,
          value: settings.notificationChannelEnabled,
          onChanged: notifier.setNotificationChannelEnabled,
        ),
      ],
    );
  }

  Future<void> _setMaster(
    BuildContext context,
    WidgetRef ref,
    bool value,
  ) async {
    await ref.read(appSettingsProvider.notifier).setNotificationsEnabled(value);
    _syncToServer(ref, enabled: value);

    if (value) {
      final granted = await ref
          .read(localNotificationServiceProvider)
          .requestPermissions();
      if (!granted && context.mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.notificationsPermissionDenied,
          type: AdaptiveSnackBarType.warning,
        );
      }
    }
  }

  Future<void> _setSound(WidgetRef ref, bool value) async {
    await ref.read(appSettingsProvider.notifier).setNotificationSound(value);
    _syncToServer(ref, sound: value);
  }

  Future<void> _setSoundAlways(WidgetRef ref, bool value) async {
    await ref
        .read(appSettingsProvider.notifier)
        .setNotificationSoundAlways(value);
    _syncToServer(ref, soundAlways: value);
  }

  /// Mirrors the three Open WebUI-aligned prefs to the server. Fire-and-forget:
  /// local persistence already succeeded, so a failed sync only loses
  /// cross-device parity, not the setting itself.
  void _syncToServer(
    WidgetRef ref, {
    bool? enabled,
    bool? sound,
    bool? soundAlways,
  }) {
    final api = ref.read(apiServiceProvider);
    if (api == null) return;
    unawaited(
      api
          .updateUserNotificationSettings(
            notificationEnabled: enabled,
            notificationSound: sound,
            notificationSoundAlways: soundAlways,
          )
          .then(
            (_) {},
            onError: (Object e, StackTrace st) {
              DebugLogger.error(
                'failed to sync notification prefs to server',
                error: e,
                stackTrace: st,
                scope: 'notifications/settings',
              );
            },
          ),
    );
  }
}
