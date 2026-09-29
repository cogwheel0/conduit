import 'dart:io';

import 'package:conduit_ddgs/conduit_ddgs.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/web_search/models/web_search_preferences.dart';
import 'package:conduit_core/features/web_search/services/on_device_web_tools.dart';
import 'package:conduit_core/features/web_search/services/web_page_fetcher.dart';
import 'package:conduit_core/services/settings_service.dart';

/// One search client for the app's lifetime, so an engine that answered
/// with a captcha stays cooled down across chats instead of being retried
/// on every turn.
final onDeviceWebSearchProvider = Provider<Ddgs>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return Ddgs(client: client);
});

final webPageFetcherProvider = Provider<WebPageFetcher>(
  (ref) => WebPageFetcher(),
);

/// `Platform.localeName`, e.g. `en_GB`. Overridden in tests.
final deviceLocaleNameProvider = Provider<String>((ref) => Platform.localeName);

/// The region on-device searches use, from settings or the device locale.
final webSearchRegionProvider = Provider<SearchRegion>((ref) {
  final stored = ref.watch(
    appSettingsProvider.select((settings) => settings.webSearchRegion),
  );
  return resolveWebSearchRegion(stored, ref.watch(deviceLocaleNameProvider));
});

typedef OnDeviceWebToolSessionFactory = OnDeviceWebToolSession Function({
  required WebToolBudget budget,
  Iterable<String> userProvidedUrls,
  Future<void>? cancel,
});

/// Builds the web tools for one Direct model turn with the user's current
/// engine, region and safe-search settings.
final onDeviceWebToolSessionFactoryProvider =
    Provider<OnDeviceWebToolSessionFactory>((ref) {
      return ({
        required WebToolBudget budget,
        Iterable<String> userProvidedUrls = const [],
        Future<void>? cancel,
      }) {
        final settings = ref.read(appSettingsProvider);
        return OnDeviceWebToolSession(
          search: ref.read(onDeviceWebSearchProvider),
          fetcher: ref.read(webPageFetcherProvider),
          engine: settings.webSearchEngine,
          region: ref.read(webSearchRegionProvider),
          safeSearch: settings.webSearchSafeSearch,
          budget: budget,
          userProvidedUrls: userProvidedUrls,
          cancel: cancel,
        );
      };
    });
