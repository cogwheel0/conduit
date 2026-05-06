import 'package:conduit/core/models/channel.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/conduit_input_styles.dart';
import 'package:conduit/shared/theme/theme_extensions.dart';
import 'package:conduit/shared/widgets/conduit_components.dart';
import 'package:conduit/shared/widgets/themed_dialogs.dart';
import 'package:flutter/material.dart';

/// Submitted values from the channel create/edit form.
class ChannelFormResult {
  /// Creates submitted channel form values.
  const ChannelFormResult({
    required this.name,
    required this.description,
    required this.isPrivate,
  });

  /// Trimmed channel name.
  final String name;

  /// Trimmed channel description.
  final String description;

  /// Whether the channel should be private.
  final bool isPrivate;
}

/// Shows the shared channel create dialog.
Future<ChannelFormResult?> showCreateChannelFormDialog(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return showChannelFormDialog(
    context,
    title: l10n.channelCreateTitle,
    submitText: l10n.channelCreateTitle,
    initialName: '',
    initialDescription: '',
    initialIsPrivate: false,
    includePrivacyToggle: true,
  );
}

/// Shows the shared channel edit dialog.
Future<ChannelFormResult?> showEditChannelFormDialog(
  BuildContext context, {
  required Channel channel,
  bool includePrivacyToggle = true,
}) {
  final l10n = AppLocalizations.of(context)!;
  return showChannelFormDialog(
    context,
    title: l10n.channelEdit,
    submitText: l10n.save,
    initialName: channel.name,
    initialDescription: channel.description,
    initialIsPrivate: channel.isPrivate,
    includePrivacyToggle: includePrivacyToggle,
  );
}

/// Shows the shared channel form dialog.
Future<ChannelFormResult?> showChannelFormDialog(
  BuildContext context, {
  required String title,
  required String submitText,
  required String initialName,
  required String initialDescription,
  required bool initialIsPrivate,
  required bool includePrivacyToggle,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final nameController = TextEditingController(text: initialName);
  final descriptionController = TextEditingController(text: initialDescription);
  var isPrivate = initialIsPrivate;

  return showDialog<ChannelFormResult>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        final theme = dialogContext.conduitTheme;
        return ThemedDialogs.buildBase(
          context: dialogContext,
          title: title,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textPrimary,
                ),
                decoration: dialogContext.conduitInputStyles.underline(
                  hint: l10n.channelName,
                ),
              ),
              const SizedBox(height: Spacing.md),
              TextField(
                controller: descriptionController,
                style: AppTypography.bodyMediumStyle.copyWith(
                  color: theme.textPrimary,
                ),
                decoration: dialogContext.conduitInputStyles.underline(
                  hint: l10n.channelDescription,
                ),
                maxLines: 3,
                minLines: 1,
              ),
              if (includePrivacyToggle) ...[
                const SizedBox(height: Spacing.sm),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.channelPrivate),
                  value: isPrivate,
                  onChanged: (value) {
                    setDialogState(() => isPrivate = value);
                  },
                ),
              ],
            ],
          ),
          actions: [
            ConduitTextButton(
              text: l10n.cancel,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            ConduitTextButton(
              text: submitText,
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) {
                  return;
                }
                Navigator.of(dialogContext).pop(
                  ChannelFormResult(
                    name: name,
                    description: descriptionController.text.trim(),
                    isPrivate: isPrivate,
                  ),
                );
              },
              isPrimary: true,
            ),
          ],
        );
      },
    ),
  );
}
