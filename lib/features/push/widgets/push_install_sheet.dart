import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';

/// Asks before installing open-source code on the user's server, with a
/// link to that code. Answers true only when the user confirmed.
Future<bool> confirmPushInstall(
  BuildContext context, {
  required String title,
  required String message,
  required String sourceUrl,
  required String confirmLabel,
}) async {
  final confirmed = await ThemedSheets.showCustom<bool>(
    context: context,
    builder: (_) => PushInstallSheet(
      title: title,
      message: message,
      sourceUrl: sourceUrl,
      confirmLabel: confirmLabel,
    ),
  );
  return confirmed ?? false;
}

class PushInstallSheet extends StatelessWidget {
  const PushInstallSheet({
    super.key,
    required this.title,
    required this.message,
    required this.sourceUrl,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String sourceUrl;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final navigator = Navigator.of(context);
    return ConduitModalSheetSurface(
      showHandle: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHandle(),
          Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title, style: theme.headingSmall),
                ),
              ),
              SheetCloseButton(
                tooltip: l10n.close,
                onPressed: () => navigator.pop(false),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            message,
            style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.md),
          InsetGroupedList(
            children: [
              UtilityRow(
                key: const Key('push-install-source'),
                title: l10n.pushViewSource,
                subtitle: sourceUrl,
                subtitleMaxLines: 1,
                trailing: Icon(
                  UiUtils.platformIcon(
                    ios: CupertinoIcons.arrow_up_right,
                    android: Icons.open_in_new,
                  ),
                  size: IconSize.medium,
                  color: theme.textSecondary,
                ),
                onTap: () => launchExternalLink(sourceUrl, scope: 'push'),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: AdaptiveButton(
                  key: const Key('push-install-cancel'),
                  onPressed: () => navigator.pop(false),
                  label: l10n.cancel,
                  style: AdaptiveButtonStyle.gray,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: AdaptiveButton(
                  key: const Key('push-install-confirm'),
                  onPressed: () => navigator.pop(true),
                  label: confirmLabel,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
        ],
      ),
    );
  }
}
