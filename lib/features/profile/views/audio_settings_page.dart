import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/utils/tts_voice_utils.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../chat/providers/text_to_speech_provider.dart';
import '../../chat/services/voice_input_service.dart';
import '../widgets/adaptive_segmented_selector.dart';
import '../widgets/customization_tile.dart';
import '../widgets/settings_page_scaffold.dart';
import '../widgets/stt_language_picker.dart';

class AudioSettingsPage extends ConsumerWidget {
  const AudioSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final l10n = AppLocalizations.of(context)!;

    return SettingsPageScaffold(
      title: l10n.audioSettingsTitle,
      children: [
        _buildSttSection(context, ref, settings),
        settingsSectionGap,
        _buildTtsSection(context, ref, settings),
      ],
    );
  }

  Widget _buildSttSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final localSupport = ref.watch(localVoiceRecognitionAvailableProvider);
    final localAvailable = localSupport.asData?.value ?? false;
    final localLoading = localSupport.isLoading;
    final serverAvailable = ref.watch(serverVoiceRecognitionAvailableProvider);
    final notifier = ref.read(appSettingsProvider.notifier);

    final warnings = <String>[
      if (settings.sttPreference == SttPreference.deviceOnly &&
          !localAvailable &&
          !localLoading)
        l10n.sttDeviceUnavailableWarning,
      if (settings.sttPreference == SttPreference.serverOnly &&
          !serverAvailable)
        l10n.sttServerUnavailableWarning,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.sttSettings),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveSegmentedSelector<SttPreference>(
                value: settings.sttPreference,
                onChanged: notifier.setSttPreference,
                options: [
                  (
                    value: SttPreference.deviceOnly,
                    label: l10n.sttEngineDevice,
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: localAvailable || localLoading,
                  ),
                  (
                    value: SttPreference.serverOnly,
                    label: l10n.sttEngineServer,
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: serverAvailable,
                  ),
                ],
              ),
              if (localLoading) ...[
                const SizedBox(height: Spacing.sm),
                const LinearProgressIndicator(minHeight: 3),
              ],
              const SizedBox(height: Spacing.sm),
              Text(
                settings.sttPreference == SttPreference.serverOnly
                    ? l10n.sttEngineServerDescription
                    : l10n.sttEngineDeviceDescription,
                style: theme.bodyMedium?.copyWith(
                  color: theme.sidebarForeground.withValues(alpha: 0.85),
                ),
              ),
              for (final warning in warnings) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  warning,
                  style: theme.bodySmall?.copyWith(
                    color: theme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (settings.sttPreference == SttPreference.serverOnly) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
            leading: SettingsIconBadge(
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.globe,
                android: Icons.language,
              ),
              color: theme.buttonPrimary,
            ),
            title: l10n.sttTranscriptionLanguage,
            subtitle: sttLanguageSubtitle(l10n, settings),
            onTap: () => showSttLanguagePickerSheet(context, ref, settings),
          ),
          const SizedBox(height: Spacing.sm),
          ConduitCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.sttSilenceDuration,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  l10n.sttSilenceDurationDescription,
                  style: theme.bodySmall?.copyWith(
                    color: theme.sidebarForeground.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: Spacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AdaptiveSlider(
                        value: settings.voiceSilenceDuration.toDouble(),
                        min: SettingsService.minVoiceSilenceDurationMs
                            .toDouble(),
                        max: SettingsService.maxVoiceSilenceDurationMs
                            .toDouble(),
                        divisions:
                            (SettingsService.maxVoiceSilenceDurationMs -
                                SettingsService.minVoiceSilenceDurationMs) ~/
                            100,
                        onChanged: (value) {
                          notifier.setVoiceSilenceDuration(value.round());
                        },
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      '${(settings.voiceSilenceDuration / 1000).toStringAsFixed(1)}s',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTtsSection(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final ttsService = ref.watch(textToSpeechServiceProvider);
    final deviceAvailable =
        ttsService.deviceEngineAvailable || !ttsService.isInitialized;
    final serverAvailable = ttsService.serverEngineAvailable;

    final warnings = <String>[
      if (settings.ttsEngine == TtsEngine.device && !deviceAvailable)
        l10n.ttsDeviceUnavailableWarning,
      if (settings.ttsEngine == TtsEngine.server && !serverAvailable)
        l10n.ttsServerUnavailableWarning,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.ttsSettings),
        const SizedBox(height: Spacing.sm),
        ConduitCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AdaptiveSegmentedSelector<TtsEngine>(
                value: settings.ttsEngine,
                onChanged: (engine) async {
                  final notifier = ref.read(appSettingsProvider.notifier);
                  await notifier.setTtsEngineSelection(engine);
                },
                options: [
                  (
                    value: TtsEngine.device,
                    label: l10n.ttsEngineDevice,
                    cupertinoIcon: CupertinoIcons.device_phone_portrait,
                    materialIcon: Icons.phone_android,
                    enabled: deviceAvailable,
                  ),
                  (
                    value: TtsEngine.server,
                    label: l10n.ttsEngineServer,
                    cupertinoIcon: CupertinoIcons.cloud,
                    materialIcon: Icons.cloud,
                    enabled: serverAvailable,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                settings.ttsEngine == TtsEngine.server
                    ? l10n.ttsEngineServerDescription
                    : l10n.ttsEngineDeviceDescription,
                style: theme.bodyMedium?.copyWith(
                  color: theme.sidebarForeground.withValues(alpha: 0.85),
                ),
              ),
              for (final warning in warnings) ...[
                const SizedBox(height: Spacing.xs),
                Text(
                  warning,
                  style: theme.bodySmall?.copyWith(
                    color: theme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.speaker_3,
              android: Icons.record_voice_over,
            ),
            color: theme.buttonPrimary,
          ),
          title: l10n.ttsVoice,
          subtitle: _voiceSubtitle(l10n, settings),
          onTap: () => _showVoicePickerSheet(context, ref, settings),
        ),
        if (settings.ttsEngine == TtsEngine.device) ...[
          const SizedBox(height: Spacing.sm),
          ConduitCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.ttsSpeechRate,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.sidebarForeground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: AdaptiveSlider(
                        value: settings.ttsSpeechRate,
                        min: 0.25,
                        max: 2.0,
                        divisions: 35,
                        onChanged: (value) {
                          ref
                              .read(appSettingsProvider.notifier)
                              .setTtsSpeechRate(value);
                        },
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      '${(settings.ttsSpeechRate * 100).round()}%',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.buttonPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: UiUtils.platformIcon(
              ios: CupertinoIcons.play_fill,
              android: Icons.play_arrow,
            ),
            color: theme.buttonPrimary,
          ),
          title: l10n.ttsPreview,
          subtitle: l10n.ttsPreviewText,
          onTap: () => _previewTtsVoice(context, ref),
        ),
      ],
    );
  }

  String _voiceSubtitle(AppLocalizations l10n, AppSettings settings) {
    if (settings.ttsEngine == TtsEngine.server) {
      final voice =
          settings.ttsServerVoiceName ??
          settings.ttsServerVoiceId ??
          l10n.ttsSystemDefault;
      return formatTtsVoiceDisplayName(voice);
    }
    final voice =
        settings.ttsVoiceName ?? settings.ttsVoice ?? l10n.ttsSystemDefault;
    return formatTtsVoiceDisplayName(voice);
  }

  Future<void> _showVoicePickerSheet(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final ttsService = ref.read(textToSpeechServiceProvider);

    await ttsService.updateSettings(engine: settings.ttsEngine);
    final voices = await ttsService.getAvailableVoices();
    if (!context.mounted) {
      return;
    }
    if (voices.isEmpty) {
      UiUtils.showMessage(context, l10n.ttsNoVoicesAvailable);
      return;
    }

    final notifier = ref.read(appSettingsProvider.notifier);
    final voiceOptions = buildTtsVoiceOptions(l10n, settings.ttsEngine, voices);
    final selectedOptionId = selectedTtsVoiceOptionId(settings, voices);
    if (Platform.isIOS) {
      try {
        final selectedId = await NativeSheetBridge.instance
            .presentOptionsSelector(
              title: l10n.ttsSelectVoice,
              selectedOptionId: selectedOptionId,
              options: [
                NativeSheetOptionConfig(
                  id: ttsSystemDefaultVoiceId,
                  label: l10n.ttsSystemDefault,
                ),
                for (final option in voiceOptions)
                  NativeSheetOptionConfig(
                    id: option.id,
                    label: option.label,
                    subtitle: option.subtitle,
                  ),
              ],
              rethrowErrors: true,
            );
        if (selectedId == null) {
          return;
        }
        if (selectedId == ttsSystemDefaultVoiceId) {
          if (settings.ttsEngine == TtsEngine.server) {
            await notifier.setTtsServerVoiceSelection(null, null);
          } else {
            await notifier.setTtsDeviceVoiceSelection(null, null);
          }
          return;
        }
        final selectedVoice = findTtsVoiceOption(
          l10n,
          settings.ttsEngine,
          voices,
          selectedId,
        );
        if (selectedVoice == null) {
          return;
        }
        if (settings.ttsEngine == TtsEngine.server) {
          await notifier.setTtsServerVoiceSelection(
            selectedVoice.id,
            selectedVoice.label,
          );
        } else {
          await notifier.setTtsDeviceVoiceSelection(
            selectedVoice.id,
            selectedVoice.label,
          );
        }
        return;
      } catch (_) {}
      if (!context.mounted) {
        return;
      }
    }

    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.ttsSelectVoice,
          itemCount: voiceOptions.length + 1,
          initialChildSize: 0.68,
          minChildSize: 0.42,
          maxChildSize: 0.9,
          itemBuilder: (context, index) {
            if (index == 0) {
              return SettingsSelectorTile(
                title: l10n.ttsSystemDefault,
                selected: selectedOptionId == ttsSystemDefaultVoiceId,
                onTap: () async {
                  if (settings.ttsEngine == TtsEngine.server) {
                    await notifier.setTtsServerVoiceSelection(null, null);
                  } else {
                    await notifier.setTtsDeviceVoiceSelection(null, null);
                  }
                  if (!sheetContext.mounted) return;
                  Navigator.of(sheetContext).pop();
                },
              );
            }

            final option = voiceOptions[index - 1];
            return SettingsSelectorTile(
              title: option.label,
              subtitle: option.subtitle,
              selected: option.id == selectedOptionId,
              onTap: () async {
                if (settings.ttsEngine == TtsEngine.server) {
                  await notifier.setTtsServerVoiceSelection(
                    option.id,
                    option.label,
                  );
                } else {
                  await notifier.setTtsDeviceVoiceSelection(
                    option.id,
                    option.label,
                  );
                }
                if (!sheetContext.mounted) return;
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }

  Future<void> _previewTtsVoice(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;

    try {
      final controller = ref.read(textToSpeechControllerProvider.notifier);
      final state = ref.read(textToSpeechControllerProvider);
      if (state.isSpeaking || state.isBusy) {
        await controller.stop();
        return;
      }

      await controller.toggleForMessage(
        messageId: 'tts_preview',
        text: l10n.ttsPreviewText,
      );
    } catch (_) {
      if (!context.mounted) {
        return;
      }
      UiUtils.showMessage(context, l10n.errorMessage);
    }
  }
}
