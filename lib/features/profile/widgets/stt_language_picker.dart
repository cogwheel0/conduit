import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/settings_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../chat/services/voice_input_service.dart';
import 'settings_page_scaffold.dart';

String sttLanguageSubtitle(AppLocalizations l10n, AppSettings settings) {
  return settings.sttLanguageCode ?? l10n.sttTranscriptionLanguageAuto;
}

String deviceSttLanguageSubtitle(AppLocalizations l10n, AppSettings settings) {
  final localeId = settings.voiceLocaleId;
  if (localeId == null) {
    return l10n.sttTranscriptionLanguageAuto;
  }
  if (localeId == SettingsService.voiceLocaleSystemDefault) {
    return l10n.ttsSystemDefault;
  }
  return localeId;
}

Future<void> showDeviceSttLanguagePickerSheet(
  BuildContext context,
  WidgetRef ref,
  AppSettings settings,
) async {
  final l10n = AppLocalizations.of(context)!;
  final notifier = ref.read(appSettingsProvider.notifier);
  final voiceInput = ref.read(voiceInputServiceProvider);
  await voiceInput.initialize(forceLocalStt: true);
  if (!context.mounted) {
    return;
  }

  final localeMap = <String, LocaleName>{};
  for (final locale in voiceInput.locales) {
    final localeId = SettingsService.normalizeVoiceLocaleId(locale.localeId);
    if (localeId == null ||
        localeId == SettingsService.voiceLocaleSystemDefault) {
      continue;
    }
    localeMap.putIfAbsent(localeId.toLowerCase(), () {
      return LocaleName(localeId, locale.name);
    });
  }
  final locales = localeMap.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> saveAndClose(BuildContext sheetContext, String? localeId) async {
    await notifier.setVoiceLocaleId(localeId);
    if (sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
  }

  Future<void> promptForCustomLocale(BuildContext sheetContext) async {
    if (sheetContext.mounted) {
      Navigator.of(sheetContext).pop();
    }
    final currentLocale = settings.voiceLocaleId;
    final input = await ThemedDialogs.promptTextInput(
      context,
      title: l10n.sttDeviceLanguage,
      hintText: l10n.sttDeviceLanguagePlaceholder,
      initialValue: currentLocale == SettingsService.voiceLocaleSystemDefault
          ? null
          : currentLocale,
      keyboardType: TextInputType.text,
      textCapitalization: TextCapitalization.none,
      maxLength: 64,
    );
    if (input == null) {
      return;
    }

    final normalized = SettingsService.normalizeVoiceLocaleId(input);
    final normalizedInput = input.trim().toLowerCase();
    if (normalized == null &&
        normalizedInput.isNotEmpty &&
        normalizedInput != 'auto') {
      if (context.mounted) {
        UiUtils.showMessage(context, l10n.sttDeviceLanguageInvalid);
      }
      return;
    }
    await notifier.setVoiceLocaleId(normalized);
  }

  await showSettingsSheet<void>(
    context: context,
    builder: (sheetContext) {
      return DeviceSttLanguagePicker(
        settings: settings,
        locales: locales,
        onSelected: (localeId) => saveAndClose(sheetContext, localeId),
        onCustom: () => promptForCustomLocale(sheetContext),
      );
    },
  );
}

class DeviceSttLanguagePicker extends StatelessWidget {
  const DeviceSttLanguagePicker({
    super.key,
    required this.settings,
    required this.locales,
    required this.onSelected,
    required this.onCustom,
  });

  final AppSettings settings;
  final List<LocaleName> locales;
  final Future<void> Function(String? localeId) onSelected;
  final Future<void> Function() onCustom;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final selectedLocaleId = settings.voiceLocaleId;
    final installedIds = locales
        .map((locale) => locale.localeId.toLowerCase())
        .toSet();
    final hasCustomSelection =
        selectedLocaleId != null &&
        selectedLocaleId != SettingsService.voiceLocaleSystemDefault &&
        !installedIds.contains(selectedLocaleId.toLowerCase());

    return SettingsSelectorSheet(
      title: l10n.sttDeviceLanguage,
      description: l10n.sttDeviceLanguageDescription,
      itemCount: locales.length + 3,
      initialChildSize: 0.62,
      minChildSize: 0.38,
      maxChildSize: 0.86,
      itemBuilder: (context, index) {
        if (index == 0) {
          return SettingsSelectorTile(
            key: const Key('device-stt-auto-option'),
            title: l10n.sttTranscriptionLanguageAuto,
            subtitle: l10n.sttDeviceLanguageAutoDescription,
            selected: selectedLocaleId == null,
            onTap: () => onSelected(null),
          );
        }
        if (index == 1) {
          return SettingsSelectorTile(
            key: const Key('device-stt-system-option'),
            title: l10n.ttsSystemDefault,
            subtitle: l10n.sttDeviceLanguageSystemDescription,
            selected:
                selectedLocaleId == SettingsService.voiceLocaleSystemDefault,
            onTap: () => onSelected(SettingsService.voiceLocaleSystemDefault),
          );
        }
        if (index == locales.length + 2) {
          return SettingsSelectorTile(
            key: const Key('device-stt-custom-option'),
            title: l10n.sttTranscriptionLanguageCustom,
            subtitle: hasCustomSelection
                ? selectedLocaleId
                : l10n.sttDeviceLanguagePlaceholder,
            selected: hasCustomSelection,
            onTap: onCustom,
          );
        }

        final locale = locales[index - 2];
        return SettingsSelectorTile(
          key: Key('device-stt-locale-${locale.localeId}'),
          title: locale.name,
          subtitle: locale.name == locale.localeId ? null : locale.localeId,
          selected:
              selectedLocaleId?.toLowerCase() == locale.localeId.toLowerCase(),
          onTap: () => onSelected(locale.localeId),
        );
      },
    );
  }
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
