import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../widgets/push_target_actions.dart';

/// "How push stays private": the threat model in a few plain sentences, with
/// a link to the full document.
class PushPrivacyPage extends StatelessWidget {
  const PushPrivacyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final sections = [
      (l10n.pushPrivacyServerTitle, l10n.pushPrivacyServerBody),
      (l10n.pushPrivacyRelayTitle, l10n.pushPrivacyRelayBody),
      (l10n.pushPrivacyProvidersTitle, l10n.pushPrivacyProvidersBody),
      (l10n.pushPrivacyUnifiedPushTitle, l10n.pushPrivacyUnifiedPushBody),
      (l10n.pushPrivacyOffTitle, l10n.pushPrivacyOffBody),
    ];
    return UtilityPageScaffold.settings(
      title: l10n.pushPrivacyTitle,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
          child: Text(
            l10n.pushPrivacyIntro,
            style: theme.bodyMedium?.copyWith(color: theme.textPrimary),
          ),
        ),
        for (final (title, body) in sections) ...[
          settingsSectionGap,
          InsetGroupedSection(
            title: title,
            child: Text(
              body,
              style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
            ),
          ),
        ],
        settingsSectionGap,
        InsetGroupedList(
          children: [
            UtilityRow(
              key: const Key('push-privacy-read-more'),
              title: l10n.pushPrivacyReadMore,
              trailing: Icon(
                UiUtils.platformIcon(
                  ios: CupertinoIcons.arrow_up_right,
                  android: Icons.open_in_new,
                ),
                size: IconSize.medium,
                color: theme.textSecondary,
              ),
              onTap: () =>
                  launchExternalLink(kConduitPushThreatModelUrl, scope: 'push'),
            ),
          ],
        ),
      ],
    );
  }
}
