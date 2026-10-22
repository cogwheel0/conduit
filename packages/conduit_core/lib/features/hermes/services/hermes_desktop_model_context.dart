part of 'hermes_desktop_api_service.dart';

extension _HermesDesktopModelContext on HermesDesktopApiService {
  Future<HermesModelContext> _readModelContext({
    String? sessionId,
    bool refresh = false,
    bool followGlobal = false,
  }) async {
    final binding = sessionId == null ? null : await _resume(sessionId);
    final profile = binding == null
        ? config.desktopProfile
        : _sessionProfiles[binding.storedId] ?? config.desktopProfile;
    final key =
        'model-context:${jsonEncode([profile, binding?.storedId, followGlobal])}';
    return _metadata.read(key, () async {
      await _ensureConnected();
      final scope = {
        'profile': profile,
        if (binding != null && !followGlobal) 'session_id': binding.runtimeId,
      };
      final results = await Future.wait([
        _rpc.request<Object?>(
          'model.options',
          params: {...scope, 'explicit_only': true},
        ),
        _rpc.request<Object?>(
          'config.get',
          params: {...scope, 'key': 'reasoning'},
        ),
        _rpc.request<Object?>('config.get', params: {...scope, 'key': 'fast'}),
      ]);
      final inventory = _object(results[0]);
      var model = validateHermesBoundedString(
        inventory['model'],
        maxCharacters: 256,
      );
      var provider = validateHermesBoundedString(
        inventory['provider'],
        maxCharacters: 256,
      );
      // Older gateways can omit the active global route from model.options.
      // Only that compatibility case needs the heavier config read.
      if ((binding == null || followGlobal) &&
          profile == config.desktopProfile &&
          (model == null || provider == null)) {
        final global = await agentSettings();
        final raw = global.config['model'];
        final route = raw is Map ? raw : const {};
        model ??= validateHermesBoundedString(
          route['default'] ??
              route['model'] ??
              global.model['model'] ??
              (raw is String ? raw : null),
          maxCharacters: 256,
        );
        provider ??= validateHermesBoundedString(
          route['provider'] ?? global.model['provider'],
          maxCharacters: 256,
        );
      }
      final models = List<HermesDesktopModelOption>.unmodifiable(
        parseHermesDesktopConfiguredModels(inventory)
            .map(HermesDesktopModelOption.fromJson)
            .where(
              (o) =>
                  validateHermesOpaqueIdentifier(o.id) != null &&
                  validateHermesOpaqueIdentifier(o.provider) != null,
            ),
      );
      final selected = models
          .where((o) => o.id == model && o.provider == provider)
          .firstOrNull;
      final reasoning = _object(results[1]);
      return HermesModelContext(
        profile: profile,
        models: models,
        settings: HermesSessionReasoningSettings(
          modelId: model,
          provider: provider,
          model: selected?.name ?? model,
          effort: validateHermesBoundedString(
            reasoning['value'],
            maxCharacters: 64,
          ),
          display: switch (reasoning['display']) {
            'show' => true,
            'hide' => false,
            _ => null,
          },
          fast: _object(results[2])['value'] == 'fast',
          supportsFast: selected?.supportsFast ?? false,
          reasoningAvailable: selected?.reasoningAvailable,
          canDisableReasoning: selected?.canDisableReasoning,
          supportedEfforts: selected?.supportedEfforts,
        ),
      );
    }, refresh: refresh);
  }
}
