import 'dart:io' show Platform;

import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/utility_components.dart';
import '../widgets/customization_tile.dart';
import '../widgets/settings_page_scaffold.dart';

const _noVoiceProviderId = 'none';

/// The Direct connections that can be the Voice provider.
List<DirectConnectionProfile> voiceProviderCandidates(WidgetRef ref) =>
    (ref.watch(directConnectionProfilesProvider).value ??
            const <DirectConnectionProfile>[])
        .where(canBeVoiceProvider)
        .toList(growable: false);

/// The Voice provider's connection name, or None.
String voiceProviderSubtitle(
  AppLocalizations l10n,
  DirectVoiceProviderSettings? settings,
  List<DirectConnectionProfile> candidates,
) {
  final profile = candidates
      .where((profile) => profile.id == settings?.profileId)
      .firstOrNull;
  return profile?.name ?? l10n.voiceProviderNone;
}

/// Picks the Direct connection, and its models, that speak and listen for
/// Direct and Apple chats.
class VoiceProviderSettingsPage extends ConsumerStatefulWidget {
  const VoiceProviderSettingsPage({super.key});

  @override
  ConsumerState<VoiceProviderSettingsPage> createState() =>
      _VoiceProviderSettingsPageState();
}

class _VoiceProviderSettingsPageState
    extends ConsumerState<VoiceProviderSettingsPage> {
  final _fields = {
    for (final field in const [
      DirectVoiceProviderField.transcriptionModel,
      DirectVoiceProviderField.speechModel,
      DirectVoiceProviderField.speechVoice,
    ])
      field: TextEditingController(),
  };
  String? _fieldsProfileId;

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Shows the stored values when the page opens or the connection changes,
  /// never while the user types.
  void _syncFields(DirectVoiceProviderSettings? settings) {
    if (settings?.profileId == _fieldsProfileId) return;
    _fieldsProfileId = settings?.profileId;
    _fields[DirectVoiceProviderField.transcriptionModel]!.text =
        settings?.transcriptionModel ?? '';
    _fields[DirectVoiceProviderField.speechModel]!.text =
        settings?.speechModel ?? '';
    _fields[DirectVoiceProviderField.speechVoice]!.text =
        settings?.speechVoice ?? '';
  }

  Future<void> _choose(DirectConnectionProfile? profile) {
    final notifier = ref.read(appSettingsProvider.notifier);
    final current = ref.read(appSettingsProvider).directVoiceProvider;
    return notifier.setDirectVoiceProvider(
      profile == null
          ? null
          : DirectVoiceProviderSettings.forConnection(
              profile,
              current: current,
            ),
    );
  }

  Future<void> _edit(DirectVoiceProviderField field, String value) async {
    final current = ref.read(appSettingsProvider).directVoiceProvider;
    if (current == null) return;
    await ref
        .read(appSettingsProvider.notifier)
        .setDirectVoiceProvider(current.withField(field, value));
  }

  Future<void> _showConnectionPicker(
    List<DirectConnectionProfile> candidates,
    String selectedId,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    DirectConnectionProfile? byId(String id) =>
        candidates.where((profile) => profile.id == id).firstOrNull;

    if (Platform.isIOS) {
      try {
        final chosen = await NativeSheetBridge.instance.presentOptionsSelector(
          title: l10n.voiceProviderConnection,
          selectedOptionId: selectedId,
          options: [
            NativeSheetOptionConfig(
              id: _noVoiceProviderId,
              label: l10n.voiceProviderNone,
            ),
            for (final profile in candidates)
              NativeSheetOptionConfig(
                id: profile.id,
                label: profile.name,
                subtitle: profile.baseUrl,
              ),
          ],
          rethrowErrors: true,
        );
        if (chosen != null) await _choose(byId(chosen));
        return;
      } catch (_) {}
      if (!mounted) return;
    }

    await showAdaptiveSelectionSheet<void>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: l10n.voiceProviderConnection,
        itemCount: candidates.length + 1,
        itemBuilder: (context, index) {
          final profile = index == 0 ? null : candidates[index - 1];
          return AdaptiveSelectionTile(
            title: profile?.name ?? l10n.voiceProviderNone,
            subtitle: profile?.baseUrl,
            selected: (profile?.id ?? _noVoiceProviderId) == selectedId,
            onTap: () async {
              await _choose(profile);
              if (!sheetContext.mounted) return;
              Navigator.of(sheetContext).pop();
            },
          );
        },
      ),
    );
  }

  Widget _field(
    DirectVoiceProviderField field, {
    required String label,
    required String hint,
  }) => AccessibleFormField(
    key: ValueKey<String>('voice-provider-${field.name}'),
    label: label,
    hint: hint,
    controller: _fields[field],
    onChanged: (value) => _edit(field, value),
    autocorrect: false,
    textInputAction: TextInputAction.next,
    iosSettingsRow: Platform.isIOS,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final settings = ref.watch(
      appSettingsProvider.select((settings) => settings.directVoiceProvider),
    );
    final candidates = voiceProviderCandidates(ref);
    final chosen = candidates.any(
      (profile) => profile.id == settings?.profileId,
    );
    _syncFields(chosen ? settings : null);

    return UtilityPageScaffold.settings(
      title: l10n.voiceProviderTitle,
      children: [
        InsetGroupedSection(
          footer: candidates.isEmpty
              ? l10n.voiceProviderNoConnections
              : l10n.voiceProviderDescription,
          child: CustomizationTile(
            leading: SettingsIconBadge(
              icon: UiUtils.platformIcon(
                ios: CupertinoIcons.waveform,
                android: Icons.graphic_eq,
              ),
              color: theme.buttonPrimary,
            ),
            title: l10n.voiceProviderConnection,
            subtitle: voiceProviderSubtitle(l10n, settings, candidates),
            onTap: candidates.isEmpty
                ? null
                : () => _showConnectionPicker(
                    candidates,
                    chosen ? settings!.profileId : _noVoiceProviderId,
                  ),
          ),
        ),
        if (chosen) ...[
          settingsSectionGap,
          InsetGroupedSection(
            title: l10n.sttSettings,
            child: _field(
              DirectVoiceProviderField.transcriptionModel,
              label: l10n.voiceProviderTranscriptionModel,
              hint: 'whisper-1',
            ),
          ),
          settingsSectionGap,
          InsetGroupedSection(
            title: l10n.ttsSettings,
            footer: l10n.voiceProviderModelsHint,
            child: Column(
              children: [
                _field(
                  DirectVoiceProviderField.speechModel,
                  label: l10n.voiceProviderSpeechModel,
                  hint: 'tts-1',
                ),
                _field(
                  DirectVoiceProviderField.speechVoice,
                  label: l10n.voice,
                  hint: 'alloy',
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
