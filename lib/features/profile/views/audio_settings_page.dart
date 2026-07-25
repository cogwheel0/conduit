import 'dart:io' show Platform;

import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/navigation_service.dart';
import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/services/settings_service.dart';
import '../../../core/sherpa/sherpa_catalog.dart';
import '../../../core/sherpa/sherpa_model.dart';
import '../../../core/sherpa/sherpa_model_manager.dart';
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

bool shouldShowDeviceSttLanguageSetting(
  TargetPlatform platform,
  SttPreference preference,
) {
  return platform == TargetPlatform.android &&
      preference == SttPreference.deviceOnly;
}

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
        settingsSectionGap,
        _buildSherpaModelsEntry(context, ref),
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
    final installedSherpa =
        ref.watch(sherpaInstalledModelsProvider).value ?? const [];
    SherpaModel? selectedSherpaModel;
    for (final installed in installedSherpa) {
      if (installed.model.id == settings.sherpaSttModelId) {
        selectedSherpaModel = installed.model;
        break;
      }
    }
    final selectedSherpa = selectedSherpaModel != null;

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
                onChanged: (preference) async {
                  if (preference == SttPreference.sherpa) {
                    if (!selectedSherpa) {
                      await context.push(Routes.sherpaModelsFor(forTts: false));
                      return;
                    }
                  }
                  await notifier.setSttPreference(preference);
                },
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
                  (
                    value: SttPreference.sherpa,
                    label: l10n.sherpaEngine,
                    cupertinoIcon: CupertinoIcons.waveform,
                    materialIcon: Icons.graphic_eq,
                    enabled: true,
                  ),
                ],
              ),
              if (localLoading) ...[
                const SizedBox(height: Spacing.sm),
                const LinearProgressIndicator(minHeight: 3),
              ],
              const SizedBox(height: Spacing.sm),
              Text(
                switch (settings.sttPreference) {
                  SttPreference.serverOnly => l10n.sttEngineServerDescription,
                  SttPreference.deviceOnly => l10n.sttEngineDeviceDescription,
                  SttPreference.sherpa => l10n.sherpaSttDescription,
                },
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
        if (shouldShowDeviceSttLanguageSetting(
          defaultTargetPlatform,
          settings.sttPreference,
        )) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
            key: const Key('device-stt-language-tile'),
            leading: SettingsIconBadge(
              icon: Icons.language,
              color: theme.buttonPrimary,
            ),
            title: l10n.sttDeviceLanguage,
            subtitle: deviceSttLanguageSubtitle(l10n, settings),
            onTap: () =>
                showDeviceSttLanguagePickerSheet(context, ref, settings),
          ),
        ],
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
        ],
        if (settings.sttPreference == SttPreference.sherpa &&
            selectedSherpaModel != null &&
            selectedSherpaModel.languages.length > 1) ...[
          const SizedBox(height: Spacing.sm),
          CustomizationTile(
            leading: SettingsIconBadge(
              icon: Icons.language,
              color: theme.buttonPrimary,
            ),
            title: l10n.sttTranscriptionLanguage,
            subtitle:
                settings.sherpaSttLanguageCode?.toUpperCase() ??
                l10n.sttTranscriptionLanguageAuto,
            onTap: () => _showSherpaLanguagePicker(
              context,
              ref,
              selectedSherpaModel!,
              selectedLanguage: settings.sherpaSttLanguageCode,
              forTts: false,
            ),
          ),
        ],
        if (settings.sttPreference == SttPreference.serverOnly ||
            settings.sttPreference == SttPreference.sherpa) ...[
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
    final installedSherpa =
        ref.watch(sherpaInstalledModelsProvider).value ?? const [];
    SherpaModel? selectedSherpaModel;
    for (final installed in installedSherpa) {
      if (installed.model.id == settings.sherpaTtsModelId) {
        selectedSherpaModel = installed.model;
        break;
      }
    }
    final selectedSherpa = selectedSherpaModel != null;

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
                  if (engine == TtsEngine.sherpa && !selectedSherpa) {
                    await context.push(Routes.sherpaModelsFor(forTts: true));
                    return;
                  }
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
                  (
                    value: TtsEngine.sherpa,
                    label: l10n.sherpaEngine,
                    cupertinoIcon: CupertinoIcons.waveform,
                    materialIcon: Icons.graphic_eq,
                    enabled: true,
                  ),
                ],
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                switch (settings.ttsEngine) {
                  TtsEngine.server => l10n.ttsEngineServerDescription,
                  TtsEngine.device => l10n.ttsEngineDeviceDescription,
                  TtsEngine.sherpa => l10n.sherpaTtsDescription,
                },
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
        if (settings.ttsEngine == TtsEngine.sherpa &&
            selectedSherpaModel != null &&
            selectedSherpaModel.languages.length > 1) ...[
          CustomizationTile(
            leading: SettingsIconBadge(
              icon: Icons.language,
              color: theme.buttonPrimary,
            ),
            title: l10n.language,
            subtitle:
                settings.sherpaTtsLanguageCode?.toUpperCase() ??
                selectedSherpaModel.languages.first.tag.toUpperCase(),
            onTap: () => _showSherpaLanguagePicker(
              context,
              ref,
              selectedSherpaModel!,
              selectedLanguage: settings.sherpaTtsLanguageCode,
              forTts: true,
            ),
          ),
          const SizedBox(height: Spacing.sm),
        ],
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
        if (settings.ttsEngine == TtsEngine.device ||
            settings.ttsEngine == TtsEngine.sherpa) ...[
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
                        value: settings.ttsEngine == TtsEngine.sherpa
                            ? settings.sherpaTtsSpeed
                            : settings.ttsSpeechRate,
                        min: settings.ttsEngine == TtsEngine.sherpa
                            ? 0.5
                            : 0.25,
                        max: 2.0,
                        divisions: settings.ttsEngine == TtsEngine.sherpa
                            ? 15
                            : 35,
                        onChanged: (value) {
                          final notifier = ref.read(
                            appSettingsProvider.notifier,
                          );
                          if (settings.ttsEngine == TtsEngine.sherpa) {
                            notifier.setSherpaTtsSpeed(value);
                          } else {
                            notifier.setTtsSpeechRate(value);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    Text(
                      settings.ttsEngine == TtsEngine.sherpa
                          ? '${settings.sherpaTtsSpeed.toStringAsFixed(1)}×'
                          : '${(settings.ttsSpeechRate * 100).round()}%',
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
    if (settings.ttsEngine == TtsEngine.sherpa) {
      final model = sherpaModelById(settings.sherpaTtsModelId);
      final speaker = int.tryParse(settings.sherpaTtsSpeakerId ?? '');
      final metadata =
          speaker == null ||
              model == null ||
              speaker < 0 ||
              speaker >= model.speakers.length
          ? null
          : model.speakers[speaker];
      return metadata?.name ??
          (speaker == null
              ? l10n.sherpaChooseVoice
              : l10n.sherpaVoiceNumber(speaker + 1));
    }
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
    if (settings.ttsEngine == TtsEngine.sherpa) {
      await _showSherpaVoicePicker(context, ref, settings);
      return;
    }
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

  Future<void> _showSherpaVoicePicker(
    BuildContext context,
    WidgetRef ref,
    AppSettings settings,
  ) async {
    final model = sherpaModelById(settings.sherpaTtsModelId);
    if (model == null || model.speakers.isEmpty) {
      await context.push(Routes.sherpaModelsFor(forTts: true));
      return;
    }
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _SherpaSpeakerSheet(
        model: model,
        selectedId: settings.sherpaTtsSpeakerId,
      ),
    );
    if (selected != null) {
      await ref
          .read(appSettingsProvider.notifier)
          .setSherpaTtsSpeakerId(selected.toString());
    }
  }

  Future<void> _showSherpaLanguagePicker(
    BuildContext context,
    WidgetRef ref,
    SherpaModel model, {
    required String? selectedLanguage,
    required bool forTts,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final allowAutomatic =
        !forTts &&
        (model.family == SherpaModelFamily.nemotron ||
            model.family == SherpaModelFamily.whisper ||
            model.family == SherpaModelFamily.senseVoice);
    await showSettingsSheet<void>(
      context: context,
      builder: (sheetContext) => SettingsSelectorSheet(
        title: l10n.selectLanguage,
        itemCount: model.languages.length + (allowAutomatic ? 1 : 0),
        itemBuilder: (context, index) {
          if (allowAutomatic && index == 0) {
            return SettingsSelectorTile(
              title: l10n.sttTranscriptionLanguageAuto,
              selected: selectedLanguage == null,
              onTap: () async {
                await ref
                    .read(appSettingsProvider.notifier)
                    .setSherpaSttLanguageCode(null);
                if (sheetContext.mounted) Navigator.of(sheetContext).pop();
              },
            );
          }
          final language =
              model.languages[index - (allowAutomatic ? 1 : 0)].tag;
          return SettingsSelectorTile(
            title: language.toUpperCase(),
            selected: selectedLanguage == language,
            onTap: () async {
              final notifier = ref.read(appSettingsProvider.notifier);
              if (forTts) {
                await notifier.setSherpaTtsLanguageCode(language);
              } else {
                await notifier.setSherpaSttLanguageCode(language);
              }
              if (sheetContext.mounted) Navigator.of(sheetContext).pop();
            },
          );
        },
      ),
    );
  }

  Widget _buildSherpaModelsEntry(BuildContext context, WidgetRef ref) {
    final theme = context.conduitTheme;
    final installed = ref.watch(sherpaInstalledModelsProvider);
    final values = installed.value ?? const [];
    final bytes = values.fold<int>(
      0,
      (total, model) => total + model.installedBytes,
    );
    final l10n = AppLocalizations.of(context)!;
    final subtitle = installed.isLoading
        ? l10n.sherpaCheckingModels
        : l10n.sherpaInstalledSummary(values.length, formatModelBytes(bytes));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsSectionHeader(title: l10n.sherpaEngine),
        const SizedBox(height: Spacing.sm),
        CustomizationTile(
          leading: SettingsIconBadge(
            icon: Icons.download_for_offline_outlined,
            color: theme.buttonPrimary,
          ),
          title: l10n.sherpaModelsTitle,
          subtitle: subtitle,
          onTap: () => context.push(Routes.sherpaModels),
        ),
      ],
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

class _SherpaSpeakerSheet extends StatefulWidget {
  const _SherpaSpeakerSheet({required this.model, required this.selectedId});

  final SherpaModel model;
  final String? selectedId;

  @override
  State<_SherpaSpeakerSheet> createState() => _SherpaSpeakerSheetState();
}

class _SherpaSpeakerSheetState extends State<_SherpaSpeakerSheet> {
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final speakers = widget.model.speakers
        .where((speaker) {
          final name = speaker.name ?? l10n.sherpaVoiceNumber(speaker.id + 1);
          return name.toLowerCase().contains(_query.toLowerCase());
        })
        .toList(growable: false);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                l10n.ttsSelectVoice,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: widget.model.speakers.length > 20,
                onChanged: (value) => setState(() => _query = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.sherpaChooseVoice,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: speakers.length,
                itemBuilder: (context, index) {
                  final speaker = speakers[index];
                  return ListTile(
                    title: Text(
                      speaker.name ?? l10n.sherpaVoiceNumber(speaker.id + 1),
                    ),
                    trailing: widget.selectedId == speaker.id.toString()
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () => Navigator.pop(context, speaker.id),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
