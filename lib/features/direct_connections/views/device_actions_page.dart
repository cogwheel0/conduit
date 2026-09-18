import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';

/// One entry of the on-device assistant catalog: the action, what it does,
/// and an example of how to ask for it.
class DeviceAction {
  const DeviceAction({
    required this.name,
    required this.description,
    required this.example,
  });

  final String name;
  final String description;
  final String example;
}

class DeviceActionGroup {
  const DeviceActionGroup({required this.title, required this.actions});

  final String title;
  final List<DeviceAction> actions;
}

const List<DeviceActionGroup> kDeviceActionGroups = <DeviceActionGroup>[
  DeviceActionGroup(
    title: 'Alarms & timers',
    actions: <DeviceAction>[
      DeviceAction(
        name: 'Alarms',
        description: 'Schedules an alarm on the device clock, with an optional label.',
        example: '"Set an alarm for 7:30 called wake up"',
      ),
      DeviceAction(
        name: 'Timers',
        description: 'Starts a countdown between 1 second and 24 hours.',
        example: '"Set a timer for 5 minutes"',
      ),
    ],
  ),
  DeviceActionGroup(
    title: 'Device controls',
    actions: <DeviceAction>[
      DeviceAction(
        name: 'Flashlight',
        description: 'Turns the camera torch on or off.',
        example: '"Turn on the flashlight"',
      ),
      DeviceAction(
        name: 'Volume',
        description: 'Sets media, ring, alarm, or notification volume by percent.',
        example: '"Set media volume to 40%"',
      ),
      DeviceAction(
        name: 'Settings screens',
        description:
            'Opens a system settings page such as Wi-Fi, Bluetooth, sound, '
            'display, battery, hotspot, or notifications.',
        example: '"Open Wi-Fi settings"',
      ),
    ],
  ),
  DeviceActionGroup(
    title: 'Apps & content',
    actions: <DeviceAction>[
      DeviceAction(
        name: 'Calendar drafts',
        description: 'Opens the calendar with a new event prefilled.',
        example: '"Draft a calendar event for Saturday at 3pm called Brunch"',
      ),
      DeviceAction(
        name: 'Dialer',
        description:
            'Opens the dialer, optionally with a number entered. It never '
            'places a call by itself.',
        example: '"Open the dialer with 555-1234"',
      ),
      DeviceAction(
        name: 'Messages',
        description: 'Opens a drafted SMS in your messaging app. Nothing is sent.',
        example: '"Draft a message to Alex saying I am on my way"',
      ),
      DeviceAction(
        name: 'Play media',
        description: 'Asks your music app to start playback.',
        example: '"Play some jazz"',
      ),
      DeviceAction(
        name: 'Open apps',
        description: 'Launches an installed app by name.',
        example: '"Open Spotify"',
      ),
      DeviceAction(
        name: 'Web search',
        description: 'Hands a query to the device web search.',
        example: '"Search the web for weather tomorrow"',
      ),
      DeviceAction(
        name: 'Share sheet',
        description: 'Opens the Android share sheet with text you ask for.',
        example: '"Share this address with text"',
      ),
      DeviceAction(
        name: 'Weather',
        description:
            'Answers with live weather for a named area, or your local area '
            'when location permission is granted.',
        example: '"What is the weather in Madrid?" / "Weather here today"',
      ),
    ],
  ),
];

/// Read-only catalog of what the on-device assistant can do. Shown from the
/// Gemini Nano section so users can discover the tool set before asking.
class DeviceActionsPage extends StatelessWidget {
  const DeviceActionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return UtilityPageScaffold.settings(
      title: l10n.deviceActionsTitle,
      children: [
        Text(
          l10n.deviceActionsSubtitle,
          style: AppTypography.bodyMediumStyle.copyWith(
            color: context.conduitTheme.textSecondary,
          ),
        ),
        const SizedBox(height: Spacing.lg),
        for (final group in kDeviceActionGroups) ...[
          SettingsSectionHeader(title: group.title),
          const SizedBox(height: Spacing.sm),
          InsetGroupedList(
            useNativeSurface: PlatformInfo.isIOS,
            footer: 'Try: ${group.actions.map((a) => a.example).join(' · ')}',
            children: [
              for (final action in group.actions)
                UtilityRow(
                  key: ValueKey<String>('device-action-${action.name}'),
                  title: action.name,
                  subtitle: action.description,
                  subtitleMaxLines: 3,
                  showChevron: false,
                ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
        ],
      ],
    );
  }
}