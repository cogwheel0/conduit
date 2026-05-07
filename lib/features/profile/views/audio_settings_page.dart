import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/settings_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../chat/providers/text_to_speech_provider.dart';
import '../../chat/services/voice_input_service.dart';
import '../widgets/adaptive_segmented_selector.dart';
import '../widgets/customization_tile.dart';
import '../widgets/settings_page_scaffold.dart';

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
                onChanged: (engine) {
                  final notifier = ref.read(appSettingsProvider.notifier);
                  if (engine == TtsEngine.server) {
                    notifier.setTtsVoice(null);
                  }
                  notifier.setTtsEngine(engine);
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
      return settings.ttsServerVoiceName ??
          settings.ttsServerVoiceId ??
          l10n.ttsSystemDefault;
    }
    return settings.ttsVoice ?? l10n.ttsSystemDefault;
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

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: settingsSheetBarrierColor(context),
      isScrollControlled: true,
      builder: (sheetContext) {
        return SettingsSelectorSheet(
          title: l10n.ttsSelectVoice,
          itemCount: voices.length + 1,
          initialChildSize: 0.68,
          minChildSize: 0.42,
          maxChildSize: 0.9,
          itemBuilder: (context, index) {
            if (index == 0) {
              return SettingsSelectorTile(
                title: l10n.ttsSystemDefault,
                selected: _isSystemDefaultSelected(settings),
                onTap: () {
                  final notifier = ref.read(appSettingsProvider.notifier);
                  if (settings.ttsEngine == TtsEngine.server) {
                    notifier.setTtsServerVoiceId(null);
                    notifier.setTtsServerVoiceName(null);
                  } else {
                    notifier.setTtsVoice(null);
                  }
                  Navigator.of(sheetContext).pop();
                },
              );
            }

            final voice = voices[index - 1];
            final name = (voice['name'] ?? voice['id'] ?? l10n.unknownLabel)
                .toString();
            final locale = (voice['locale'] as String?)?.trim() ?? '';
            return SettingsSelectorTile(
              title: name,
              subtitle: locale.isEmpty ? null : locale,
              selected: _isSelectedVoice(settings, voice),
              onTap: () {
                final id = _voiceId(settings.ttsEngine, voice);
                final notifier = ref.read(appSettingsProvider.notifier);
                if (settings.ttsEngine == TtsEngine.server) {
                  notifier.setTtsServerVoiceId(id);
                  notifier.setTtsServerVoiceName(name);
                } else {
                  notifier.setTtsVoice(id);
                }
                Navigator.of(sheetContext).pop();
              },
            );
          },
        );
      },
    );
  }

  bool _isSystemDefaultSelected(AppSettings settings) {
    return settings.ttsEngine == TtsEngine.server
        ? settings.ttsServerVoiceId == null
        : settings.ttsVoice == null;
  }

  bool _isSelectedVoice(AppSettings settings, Map<String, dynamic> voice) {
    final id = _voiceId(settings.ttsEngine, voice);
    return settings.ttsEngine == TtsEngine.server
        ? settings.ttsServerVoiceId == id
        : settings.ttsVoice == id;
  }

  String _voiceId(TtsEngine engine, Map<String, dynamic> voice) {
    final id = voice['id']?.toString();
    final name = voice['name']?.toString();
    final identifier = voice['identifier']?.toString();
    return switch (engine) {
      TtsEngine.server => id ?? name ?? identifier ?? 'unknown',
      TtsEngine.device => name ?? identifier ?? id ?? 'unknown',
    };
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
