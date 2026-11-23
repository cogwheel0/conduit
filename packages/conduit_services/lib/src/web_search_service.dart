import 'package:conduit_core/features/web_search/web_search.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/riverpod.dart';

/// Implements `webSearch.*`: the engine, safe search and region of the web
/// search the app runs itself, for direct models with no search of their
/// own. The settings are the core's `AppSettings`, as on mobile, and so is
/// the region a "follow this Mac" choice resolves to.
final class WebSearchService {
  WebSearchService(this._container);

  final ProviderContainer _container;

  WebSearchSettings get() {
    final settings = _container.read(appSettingsProvider);
    return WebSearchSettings(
      engine: settings.webSearchEngine.name,
      engines: <WebSearchEngineDto>[
        for (final choice in WebSearchEngineChoice.values)
          WebSearchEngineDto(
            id: choice.name,
            name: choice.engine?.displayName ?? '',
          ),
      ],
      safeSearch: settings.webSearchSafeSearch.name,
      region: settings.webSearchRegion,
      effectiveRegion: _container.read(webSearchRegionProvider).code,
      regions: <WebSearchRegionDto>[
        WebSearchRegionDto(code: SearchRegion.worldwide.code),
        for (final option in kWebSearchRegions)
          WebSearchRegionDto(code: option.code, name: option.name),
      ],
    );
  }

  Future<WebSearchSettings> set(WebSearchSettingsPatch patch) async {
    final notifier = _container.read(appSettingsProvider.notifier);
    if (patch.engine case final engine?) {
      if (!WebSearchEngineChoice.values.any((c) => c.name == engine)) {
        throw _invalid('no engine $engine');
      }
      await notifier.setWebSearchEngine(WebSearchEngineChoice.parse(engine));
    }
    if (patch.safeSearch case final level?) {
      if (!SafeSearch.values.any((v) => v.name == level)) {
        throw _invalid('no safe search level $level');
      }
      await notifier.setWebSearchSafeSearch(parseSafeSearch(level));
    }
    if (patch.region case final code?) {
      final known =
          code == kWebSearchRegionAuto ||
          code == SearchRegion.worldwide.code ||
          kWebSearchRegions.any((option) => option.code == code);
      if (!known) throw _invalid('no region $code');
      await notifier.setWebSearchRegion(code);
    }
    return get();
  }

  static RpcError _invalid(String message) =>
      RpcError(code: ConduitErrorCodes.invalidParams, debugMessage: message);
}
