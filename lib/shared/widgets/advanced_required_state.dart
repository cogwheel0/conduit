import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/utils/ui_utils.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';

/// Shown in place of a page that belongs to Advanced while Advanced is off,
/// for instance after a deep link or a stale native Settings row.
///
/// [feature] names the page in the message. The button turns Advanced on
/// where the user is, so the page appears without a trip to Settings.
class AdvancedRequiredState extends ConsumerWidget {
  const AdvancedRequiredState({super.key, required this.feature});

  final String feature;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ConduitEmptyState(
      key: const ValueKey('advanced-required'),
      icon: UiUtils.platformIcon(
        ios: CupertinoIcons.gear_alt,
        android: Icons.settings_suggest_outlined,
      ),
      title: l10n.advancedRequiredTitle,
      message: l10n.advancedRequiredMessage(feature),
      action: ConduitButton(
        key: const ValueKey('advanced-required-turn-on'),
        text: l10n.advancedTurnOn,
        onPressed: () => ref
            .read(appSettingsProvider.notifier)
            .setAdvancedFeaturesEnabled(true),
      ),
    );
  }
}
