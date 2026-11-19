import 'dart:async';

import 'package:conduit_core/features/chat/server_speech/direct_voice_provider_settings.dart';
import 'package:conduit_core/features/chat/services/quick_pill_catalog.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/support/support_links.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/models/toggle_filter.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/persistence/account_scoped_preferences.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/utils/model_system_prompt.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

import 'event_bus.dart';
import 'settled.dart';

/// The rest of `settings.*`: core's `AppSettings` (what the phone's Chats,
/// Personalization, Data & Connection, Audio and Voice Provider pages
/// change), the Open WebUI account's own system prompt, models' prompts,
/// and what those pages offer to choose from.
///
/// Every write goes through the same `AppSettingsNotifier` setter the phone
/// calls, so the stored keys, the per-account scoping and the clean-ups a
/// setter does (choosing the server engine forgets the device voice) are
/// the phone's. `settings.changed` follows the notifier, whoever changed it.
final class CoreSettingsService {
  CoreSettingsService(this._container, {EventBus? events}) : _events = events {
    if (events != null) {
      _announced = settingsDto(_container.read(appSettingsProvider));
      _container.listen<AppSettings>(
        appSettingsProvider,
        (_, _) => _announceIfChanged(),
      );
    }
  }

  final ProviderContainer _container;
  final EventBus? _events;

  /// What the windows were last told the settings are.
  AppSettingsDto? _announced;

  /// `settings.changed`, once per change the windows can see. Called by
  /// [set] too: core's settings compare equal across a transport change
  /// alone, so the provider does not notify for it.
  void _announceIfChanged() {
    final events = _events;
    if (events == null) return;
    final now = settingsDto(_container.read(appSettingsProvider));
    if (now == _announced) return;
    _announced = now;
    events.emit(ConduitEventSpecs.settingsChanged, null);
  }

  AppSettingsNotifier get _notifier =>
      _container.read(appSettingsProvider.notifier);

  AppSettings get _settings => _container.read(appSettingsProvider);

  /// The fields of [AppSettingsDto] a patch may `clear`.
  static const Set<String> clearable = <String>{
    'inlineMessageActions',
    'defaultModel',
    'openRouterImageGenerationModel',
    'voiceLocaleId',
    'sttLanguageCode',
    'ttsVoice',
    'ttsVoiceName',
    'ttsServerVoiceId',
    'ttsServerVoiceName',
    'directVoiceProvider',
  };

  static const Set<String> _callModes = <String>{'auto', 'standard'};
  static const Set<String> _sttPreferences = <String>{
    'deviceOnly',
    'serverOnly',
  };
  static const Set<String> _ttsEngines = <String>{'device', 'server'};
  static const Set<String> _transports = <String>{'ws', 'polling'};

  AppSettingsDto get() => settingsDto(_container.read(appSettingsProvider));

  /// [settings] on the wire.
  static AppSettingsDto settingsDto(AppSettings settings) => AppSettingsDto(
    computerEnabled: settings.computerEnabled,
    quickPills: List<String>.of(settings.quickPills),
    inlineMessageActions: settings.inlineMessageActions == null
        ? null
        : List<String>.of(settings.inlineMessageActions!),
    sendOnEnter: settings.sendOnEnter,
    showComposerNotesButton: settings.showComposerNotesButton,
    showModelNameInComposer: settings.showModelNameInComposer,
    temporaryChatByDefault: settings.temporaryChatByDefault,
    citationShowTitles: settings.citationShowTitles,
    citationBackground: settings.citationBackground,
    advancedFeaturesEnabled: settings.advancedFeaturesEnabled,
    defaultModel: settings.defaultModel,
    openRouterImageGenerationModel: settings.openRouterImageGenerationModel,
    socketTransportMode: settings.socketTransportMode,
    voiceCallMode: settings.voiceCallMode.name,
    sttPreference: settings.sttPreference.name,
    voiceLocaleId: settings.voiceLocaleId,
    sttLanguageCode: settings.sttLanguageCode,
    voiceSilenceDuration: settings.voiceSilenceDuration,
    voiceBargeInEnabled: settings.voiceBargeInEnabled,
    ttsEngine: settings.ttsEngine.name,
    ttsVoice: settings.ttsVoice,
    ttsVoiceName: settings.ttsVoiceName,
    ttsServerVoiceId: settings.ttsServerVoiceId,
    ttsServerVoiceName: settings.ttsServerVoiceName,
    ttsSpeed: settings.ttsSpeed,
    directVoiceProvider: switch (settings.directVoiceProvider) {
      null => null,
      final p => DirectVoiceProviderDto(
        profileId: p.profileId,
        transcriptionModel: p.transcriptionModel,
        speechModel: p.speechModel,
        speechVoice: p.speechVoice,
        realtimeModel: p.realtimeModel,
        realtimeVoice: p.realtimeVoice,
        realtimeInstructions: p.realtimeInstructions,
      ),
    },
    messageActions: messageActionIds,
    defaultInlineMessageActions: defaultInlineMessageActions,
  );

  /// Applies [patch]: every value is checked before any is written, so a
  /// bad one changes nothing.
  Future<AppSettingsDto> set(AppSettingsPatch patch) async {
    _validate(patch);
    // The whole patch is for the account in use when it was sent: core
    // picks an account's keys as each setter starts, so each starts only
    // while that account still is.
    // Both the sign-in and the account itself: switching between accounts
    // that are not signed in keeps the session epoch.
    final account = _container.read(openWebUiAuthSessionEpochProvider);
    final accountId = currentPreferenceAccountId();
    AppSettingsNotifier n() {
      if (!identical(
            account,
            _container.read(openWebUiAuthSessionEpochProvider),
          ) ||
          accountId != currentPreferenceAccountId()) {
        throw const RpcError(
          code: ConduitErrorCodes.sessionExpired,
          debugMessage: 'the account changed while the settings were saved',
        );
      }
      return _notifier;
    }

    final clear = patch.clear.toSet();
    bool cleared(String field) => clear.contains(field);

    if (patch.computerEnabled case final v?) await n().setComputerEnabled(v);
    if (patch.quickPills case final v?) {
      await n().setQuickPills(
        <String>{
          for (final id in v)
            if (id.trim().isNotEmpty) id.trim(),
        }.toList(),
      );
    }
    if (cleared('inlineMessageActions')) {
      await n().setInlineMessageActions(null);
    } else if (patch.inlineMessageActions case final v?) {
      await n().setInlineMessageActions(v);
    }
    if (patch.sendOnEnter case final v?) await n().setSendOnEnter(v);
    if (patch.showComposerNotesButton case final v?) {
      await n().setShowComposerNotesButton(v);
    }
    if (patch.showModelNameInComposer case final v?) {
      await n().setShowModelNameInComposer(v);
    }
    if (patch.temporaryChatByDefault case final v?) {
      await n().setTemporaryChatByDefault(v);
    }
    if (patch.citationShowTitles case final v?) {
      await n().setCitationShowTitles(v);
    }
    if (patch.citationBackground case final v?) {
      await n().setCitationBackground(v);
    }
    if (patch.advancedFeaturesEnabled case final v?) {
      await n().setAdvancedFeaturesEnabled(v);
    }
    if (cleared('defaultModel')) {
      await n().setDefaultModel(null);
    } else if (patch.defaultModel case final v?) {
      await n().setDefaultModel(v.trim());
    }
    if (cleared('openRouterImageGenerationModel')) {
      await n().setOpenRouterImageGenerationModel(null);
    } else if (patch.openRouterImageGenerationModel case final v?) {
      await n().setOpenRouterImageGenerationModel(v);
    }
    if (patch.socketTransportMode case final v?) {
      await n().setSocketTransportMode(v);
    }
    if (patch.voiceCallMode case final v?) {
      await n().setVoiceCallMode(VoiceCallMode.values.byName(v));
    }
    if (patch.sttPreference case final v?) {
      await n().setSttPreference(SttPreference.values.byName(v));
    }
    if (cleared('voiceLocaleId')) {
      await n().setVoiceLocaleId(null);
    } else if (patch.voiceLocaleId case final v?) {
      await n().setVoiceLocaleId(v);
    }
    if (cleared('sttLanguageCode')) {
      await n().setSttLanguageCode(null);
    } else if (patch.sttLanguageCode case final v?) {
      await n().setSttLanguageCode(v);
    }
    if (patch.voiceSilenceDuration case final v?) {
      // The phone's slider: 100 ms steps between core's bounds.
      final stepped = (v / 100).round() * 100;
      await n().setVoiceSilenceDuration(
        stepped.clamp(
          SettingsService.minVoiceSilenceDurationMs,
          SettingsService.maxVoiceSilenceDurationMs,
        ),
      );
    }
    if (patch.voiceBargeInEnabled case final v?) {
      await n().setVoiceBargeInEnabled(v);
    }
    if (patch.ttsEngine case final v?) {
      await n().setTtsEngineSelection(TtsEngine.values.byName(v));
    }
    // A voice given wins over clearing its name; a name alone renames the
    // voice chosen (checked in [_validate]).
    if (patch.ttsVoice case final v?) {
      await n().setTtsDeviceVoiceSelection(
        v,
        cleared('ttsVoiceName') ? null : (patch.ttsVoiceName ?? v),
      );
    } else if (cleared('ttsVoice')) {
      await n().setTtsDeviceVoiceSelection(null, null);
    } else if (cleared('ttsVoiceName')) {
      await n().setTtsDeviceVoiceSelection(_settings.ttsVoice, null);
    } else if (patch.ttsVoiceName case final name?) {
      await n().setTtsDeviceVoiceSelection(_settings.ttsVoice, name);
    }
    if (patch.ttsServerVoiceId case final v?) {
      await n().setTtsServerVoiceSelection(
        v,
        cleared('ttsServerVoiceName') ? null : (patch.ttsServerVoiceName ?? v),
      );
    } else if (cleared('ttsServerVoiceId')) {
      await n().setTtsServerVoiceSelection(null, null);
    } else if (cleared('ttsServerVoiceName')) {
      await n().setTtsServerVoiceSelection(_settings.ttsServerVoiceId, null);
    } else if (patch.ttsServerVoiceName case final name?) {
      await n().setTtsServerVoiceSelection(_settings.ttsServerVoiceId, name);
    }
    if (patch.ttsSpeed case final v?) {
      await n().setTtsSpeed(nearestTtsSpeed(v));
    }
    if (cleared('directVoiceProvider')) {
      await n().setDirectVoiceProvider(null);
    } else if (patch.directVoiceProvider case final p?) {
      await n().setDirectVoiceProvider(_voiceProvider(p));
    }
    _announceIfChanged();
    return get();
  }

  void _validate(AppSettingsPatch patch) {
    Never bad(String message) => throw RpcError(
      code: ConduitErrorCodes.invalidParams,
      debugMessage: message,
    );
    for (final field in patch.clear) {
      if (!clearable.contains(field)) bad('cannot clear "$field"');
    }
    if (patch.inlineMessageActions case final actions?) {
      for (final id in actions) {
        if (!messageActionIds.contains(id)) bad('no message action "$id"');
      }
    }
    void oneOf(String? value, Set<String> allowed, String field) {
      if (value != null && !allowed.contains(value)) {
        bad('$field cannot be "$value"');
      }
    }

    oneOf(patch.voiceCallMode, _callModes, 'voiceCallMode');
    oneOf(patch.sttPreference, _sttPreferences, 'sttPreference');
    oneOf(patch.ttsEngine, _ttsEngines, 'ttsEngine');
    oneOf(patch.socketTransportMode, _transports, 'socketTransportMode');
    if (patch.defaultModel case final id? when id.trim().isEmpty) {
      bad('defaultModel is empty; clear it to pick one automatically');
    }
    if (patch.directVoiceProvider case final p?
        when p.profileId.trim().isEmpty) {
      bad('directVoiceProvider needs a connection');
    }
    if (patch.ttsSpeed case final speed? when !speed.isFinite || speed <= 0) {
      bad('ttsSpeed must be positive');
    }
    // A voice's name is the name of a voice: alone, it names the one chosen.
    final clear = patch.clear.toSet();
    // Choosing the server engine forgets the device voice first, so a name
    // in the same patch would name no voice.
    final keepsDeviceVoice = patch.ttsEngine != TtsEngine.server.name;
    if (patch.ttsVoiceName != null &&
        patch.ttsVoice == null &&
        !clear.contains('ttsVoice') &&
        (!keepsDeviceVoice || (_settings.ttsVoice?.isEmpty ?? true))) {
      bad('ttsVoiceName needs a device voice');
    }
    if (patch.ttsServerVoiceName != null &&
        patch.ttsServerVoiceId == null &&
        !clear.contains('ttsServerVoiceId') &&
        (_settings.ttsServerVoiceId?.isEmpty ?? true)) {
      bad('ttsServerVoiceName needs a server voice');
    }
  }

  /// [dto] as core keeps it: a blank field is no value, as the phone's
  /// form leaves it (instructions keep their own spacing).
  static DirectVoiceProviderSettings _voiceProvider(DirectVoiceProviderDto p) {
    String? clean(String? v) {
      final trimmed = v?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    }

    final instructions = p.realtimeInstructions;
    return DirectVoiceProviderSettings(
      profileId: p.profileId.trim(),
      transcriptionModel: clean(p.transcriptionModel),
      speechModel: clean(p.speechModel),
      speechVoice: clean(p.speechVoice),
      realtimeModel: clean(p.realtimeModel),
      realtimeVoice: clean(p.realtimeVoice),
      realtimeInstructions: instructions == null || instructions.trim().isEmpty
          ? null
          : instructions,
    );
  }

  // ---- The account's own settings on its server ----

  Future<AccountSettingsDto> getAccount() async {
    if (_container.read(apiServiceProvider) == null) {
      return const AccountSettingsDto();
    }
    final settings = await readSettled(
      _container,
      personalizationSettingsProvider.future,
    );
    return AccountSettingsDto(
      available: true,
      systemPrompt: settings.systemPrompt,
    );
  }

  Future<AccountSettingsDto> setAccount(AccountSettingsPatch patch) async {
    _requireApi();
    if (patch.systemPrompt case final prompt?) {
      final trimmed = prompt.trim();
      final updated = await _container
          .read(personalizationSettingsProvider.notifier)
          .setSystemPrompt(trimmed.isEmpty ? null : trimmed);
      return AccountSettingsDto(
        available: true,
        systemPrompt: updated.systemPrompt,
      );
    }
    return getAccount();
  }

  // ---- Models' own prompts (Prompt Overrides) ----

  Future<ModelPrompt> modelPrompt(ModelPromptRef ref) =>
      _modelPrompt(_requireApi(), ref);

  Future<ModelPrompt> _modelPrompt(ApiService api, ModelPromptRef ref) async {
    final detail = await api.getModelDetails(ref.modelId);
    if (detail == null) return ModelPrompt(modelId: ref.modelId);
    return ModelPrompt(
      modelId: ref.modelId,
      editable: true,
      writable: modelRecordWritable(detail),
      prompt: modelSystemPromptOf(detail) ?? '',
    );
  }

  Future<ModelPrompt> setModelPrompt(ModelPromptEdit edit) async {
    // Checked and written under one account: a switch while the record is
    // read writes nothing, to either account.
    final session = _container.read(openWebUiAuthSessionEpochProvider);
    final api = _requireApi();
    final current = await _modelPrompt(
      api,
      ModelPromptRef(modelId: edit.modelId),
    );
    if (!identical(
          session,
          _container.read(openWebUiAuthSessionEpochProvider),
        ) ||
        !identical(api, _container.read(apiServiceProvider))) {
      throw const RpcError(
        code: ConduitErrorCodes.sessionExpired,
        debugMessage: 'the account changed',
      );
    }
    if (!current.editable || !current.writable) {
      throw RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: current.editable
            ? 'no write access to ${edit.modelId}'
            : '${edit.modelId} has no editable server record',
      );
    }
    await api.updateModelSystemPrompt(edit.modelId, edit.prompt);
    // As the phone does after saving: the model list carries the prompt.
    unawaited(
      _container.read(modelsProvider.notifier).refresh().catchError((_) {}),
    );
    return _modelPrompt(api, ModelPromptRef(modelId: edit.modelId));
  }

  // ---- What the pages offer ----

  /// The quick pills on offer: the server's tools and the default model's
  /// toggle filters (the phone uses the chat's selected model; Settings on
  /// the desktop belongs to no chat).
  Future<QuickPillOptions> quickPills() async {
    var tools = const <Tool>[];
    final filters = <ToggleFilter>[];
    if (_container.read(apiServiceProvider) != null) {
      try {
        tools = await readSettled(_container, toolsListProvider.future);
      } on Object {
        tools = const <Tool>[];
      }
      try {
        final model = await readSettled(
          _container,
          defaultModelProvider.future,
        ).timeout(const Duration(seconds: 5));
        filters.addAll(model?.filters ?? const []);
      } on Object {
        // No default model yet: no filters to offer.
      }
    }
    return QuickPillOptions(
      options: <QuickPillOption>[
        for (final pill in quickPillCandidates(tools: tools, filters: filters))
          QuickPillOption(
            id: pill.id,
            kind: pill.kind.name,
            name: pill.name,
            targetId: pill.targetId,
          ),
      ],
    );
  }

  Future<VoiceProviderOptions> voiceProviders() async {
    final profiles = await readSettled(
      _container,
      directConnectionProfilesProvider.future,
    );
    return VoiceProviderOptions(
      connections: <VoiceProviderOption>[
        for (final profile in profiles)
          if (canBeVoiceProvider(profile))
            VoiceProviderOption(id: profile.id, name: profile.name),
      ],
    );
  }

  Future<AboutInfo> about() async {
    const links = AboutInfo(
      repositoryUrl: conduitRepositoryUrl,
      buyMeACoffeeUrl: buyMeACoffeeUrl,
      githubSponsorsUrl: githubSponsorsUrl,
    );
    if (_container.read(apiServiceProvider) == null) return links;
    try {
      final info = await readSettled(
        _container,
        serverAboutInfoProvider.future,
      ).timeout(const Duration(seconds: 10));
      if (info == null) return links.copyWith(server: true);
      return links.copyWith(
        server: true,
        serverName: info.name.trim().isEmpty ? null : info.name,
        serverVersion: info.version.trim().isEmpty ? null : info.version,
        latestVersion: info.latestVersion,
      );
    } on Object {
      // Unreachable or not saying: About shows that it is unavailable.
      return links.copyWith(server: true);
    }
  }

  ApiService _requireApi() =>
      _container.read(apiServiceProvider) ??
      (throw const RpcError(
        code: ConduitErrorCodes.unauthenticated,
        debugMessage: 'no Open WebUI account is in use',
      ));
}
