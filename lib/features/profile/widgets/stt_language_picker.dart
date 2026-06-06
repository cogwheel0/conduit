import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/settings_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import 'settings_page_scaffold.dart';

String sttLanguageSubtitle(AppLocalizations l10n, AppSettings settings) {
  return settings.sttLanguageCode ?? l10n.sttTranscriptionLanguageAuto;
}

Future<void> showSttLanguagePickerSheet(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
) {
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(appSettingsProvider.notifier);

  return showSettingsSheet<void>(
    context: context,
    builder: (sheetContext) {
      return SettingsSelectorSheet(
        title: l10n.sttTranscriptionLanguage,
        description: l10n.sttTranscriptionLanguageDescription,
        itemCount: 2,
        initialChildSize: 0.38,
        minChildSize: 0.28,
        maxChildSize: 0.58,
        itemBuilder: (context, index) {
          if (index == 0) {
            return SettingsSelectorTile(
              title: l10n.sttTranscriptionLanguageAuto,
              subtitle: l10n.sttTranscriptionLanguageDescription,
              selected: settings.sttLanguageCode == null,
              onTap: () async {
                await notifier.setSttLanguageCode(null);
                if (sheetContext.mounted) {
                  Navigator.of(sheetContext).pop();
                }
              },
            );
          }

          return SettingsSelectorTile(
            title: l10n.sttTranscriptionLanguageCustom,
            subtitle:
                settings.sttLanguageCode ??
                l10n.sttTranscriptionLanguagePlaceholder,
            selected: settings.sttLanguageCode != null,
            onTap: () async {
              if (sheetContext.mounted) {
                Navigator.of(sheetContext).pop();
              }
              final input = await ThemedDialogs.promptTextInput(
                context,
                title: l10n.sttTranscriptionLanguage,
                hintText: l10n.sttTranscriptionLanguagePlaceholder,
                initialValue: settings.sttLanguageCode,
                keyboardType: TextInputType.text,
                textCapitalization: TextCapitalization.none,
                maxLength: 8,
              );
              if (input == null) {
                return;
              }
              final normalized = SettingsService.normalizeSttLanguageCode(
                input,
              );
              if (normalized == null) {
                if (SettingsService.isSttLanguageAutoInput(input)) {
                  await notifier.setSttLanguageCode(null);
                  return;
                }
                if (context.mounted) {
                  UiUtils.showMessage(
                    context,
                    l10n.sttTranscriptionLanguageInvalid,
                  );
                }
                return;
              }
              await notifier.setSttLanguageCode(normalized);
            },
          );
        },
      );
    },
  );
}
