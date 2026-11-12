import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/direct_connections/controllers/direct_connection_editor_draft.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/models/openwebui_direct_connection.dart';
import 'package:conduit_core/features/direct_connections/providers/apple_pcc_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/apple_pcc_adapter.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_bridge.dart';
import 'package:conduit_core/features/web_search/web_search.dart';
import 'package:conduit_core/models/connection_attempt.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:intl/intl.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/account_display.dart' show directProviderName;
import '../../../core/utils/native_sheet_utils.dart';
import '../../direct_connections/controllers/direct_connection_editor_form.dart';
import '../../direct_connections/controllers/direct_connection_editor_messages.dart';
import '../../direct_connections/controllers/direct_connection_editor_workflow.dart';
import '../../direct_connections/controllers/direct_mcp_server_editor.dart';
import 'direct_connection_page_ids.dart';

/// Above this many models, context limits move to their own page so a large
/// gateway catalog doesn't bury the rest of Direct Connections.
const kDirectContextLimitsInlineLimit = 5;

/// The context lengths a model without one of its own can be given.
const List<int> kDirectContextLengthOptions = <int>[
  4096,
  8192,
  16384,
  32768,
  65536,
  131072,
  262144,
  524288,
  1048576,
];

/// What the Direct Connections pages show, as the app has it now.
@immutable
final class DirectSettingsView {
  const DirectSettingsView({
    required this.profiles,
    this.mcpServers = const AsyncData(<DirectMcpServer>[]),
    this.openWebUi = const AsyncData(null),
    this.showOpenWebUi = false,
    this.syncWithOpenWebUi = false,
    this.appleOnDevice,
    this.applePcc,
    this.applePccFallback = false,
    this.modelsWithoutContextLimit = const <Model>[],
    this.contextLengthOverrides = const <String, int>{},
    this.maxImagesPerRequest = kDefaultDirectMaxImagesPerRequest,
    this.webSearchEngine = WebSearchEngineChoice.auto,
    this.webSearchSafeSearch = SafeSearch.moderate,
    this.webSearchRegion,
    this.effectiveRegion = SearchRegion.worldwide,
  });

  /// The view as [read] finds it in the app's providers.
  factory DirectSettingsView.read(
    T Function<T>(ProviderListenable<T> provider) read,
  ) {
    // The Apple toggles default to on: only where Apple Intelligence can
    // exist are they rows.
    final apple = read(applePccPlatformSupportedProvider);
    final showOpenWebUi = read(openWebUiDirectConnectionsAvailableProvider);
    final settings = read(appSettingsProvider);
    final models =
        read(directModelDiscoveryProvider).value?.models ?? const <Model>[];
    return DirectSettingsView(
      profiles: read(directConnectionProfilesProvider),
      mcpServers: read(directMcpServersProvider),
      openWebUi: showOpenWebUi
          ? read(openWebUiDirectConnectionsProvider)
          : const AsyncData(null),
      showOpenWebUi: showOpenWebUi,
      syncWithOpenWebUi:
          read(directHistoryPolicyProvider) ==
          DirectHistoryPolicy.syncWithOpenWebUI,
      appleOnDevice: apple && read(appleOnDeviceEnabledProvider)
          ? read(appleOnDeviceStatusProvider)
          : null,
      applePcc: apple && read(applePccEnabledProvider)
          ? read(applePccStatusProvider)
          : null,
      applePccFallback: apple && read(applePccOnDeviceFallbackProvider),
      modelsWithoutContextLimit: [
        for (final model in models)
          if (directModelAdvertisedContextLength(model) == null) model,
      ],
      contextLengthOverrides: read(directContextLengthOverridesProvider),
      maxImagesPerRequest: read(directMaxImagesPerRequestProvider),
      webSearchEngine: settings.webSearchEngine,
      webSearchSafeSearch: settings.webSearchSafeSearch,
      webSearchRegion: settings.webSearchRegion,
      effectiveRegion: read(webSearchRegionProvider),
    );
  }

  final AsyncValue<List<DirectConnectionProfile>> profiles;
  final AsyncValue<List<DirectMcpServer>> mcpServers;
  final AsyncValue<OpenWebUiDirectConnectionsSnapshot?> openWebUi;

  /// Whether an Open WebUI account keeps providers of its own.
  final bool showOpenWebUi;
  final bool syncWithOpenWebUi;

  /// Each Apple model's status, or null where it is not offered.
  final AsyncValue<PlatformPccStatus>? appleOnDevice;
  final AsyncValue<PlatformPccStatus>? applePcc;
  final bool applePccFallback;
  final List<Model> modelsWithoutContextLimit;
  final Map<String, int> contextLengthOverrides;
  final int maxImagesPerRequest;
  final WebSearchEngineChoice webSearchEngine;
  final SafeSearch webSearchSafeSearch;

  /// The region picked, or null to follow the device.
  final String? webSearchRegion;

  /// The region searches use now.
  final SearchRegion effectiveRegion;

  AsyncValue<PlatformPccStatus>? appleStatus(String model) =>
      model == directAppleOnDevice ? appleOnDevice : applePcc;
}

NativeSheetItemConfig _notice(String pageId, String message) =>
    NativeSheetItemConfig(
      id: '$pageId-notice',
      title: message,
      sfSymbol: 'exclamationmark.triangle',
      kind: NativeSheetItemKind.info,
    );

NativeSheetItemConfig _addRow(String id, String title) => NativeSheetItemConfig(
  id: id,
  title: title,
  sfSymbol: 'plus.circle',
  accent: true,
);

NativeSheetItemConfig _retryRow(String id, AppLocalizations l10n) =>
    NativeSheetItemConfig(
      id: id,
      title: l10n.retry,
      sfSymbol: 'arrow.clockwise',
      accent: true,
      showsDisclosure: false,
    );

String _formatCount(AppLocalizations l10n, int count) =>
    NumberFormat.decimalPattern(l10n.localeName).format(count);

String _formatTokenCount(AppLocalizations l10n, int tokens) {
  if (tokens % (1024 * 1024) == 0) return '${tokens ~/ (1024 * 1024)}M';
  if (tokens % 1024 == 0) return '${tokens ~/ 1024}K';
  return _formatCount(l10n, tokens);
}

/// [time] in the app's language, falling back to the default locale's
/// dates where the app's has no date names loaded.
String _formatDate(
  AppLocalizations l10n,
  DateTime time, {
  bool withTime = false,
}) {
  DateFormat format(String? locale) =>
      withTime ? DateFormat.yMd(locale).add_jm() : DateFormat.yMd(locale);
  try {
    return format(l10n.localeName).format(time);
  } catch (_) {
    return format(null).format(time);
  }
}

String _appleTitle(AppLocalizations l10n, String model) =>
    model == directAppleOnDevice
    ? l10n.backendChooserAppleOnDeviceTitle
    : l10n.backendChooserApplePccTitle;

String _appleSymbol(String model) =>
    model == directAppleOnDevice ? 'iphone' : 'lock.shield';

String _appleUnavailable(AppLocalizations l10n, String model) =>
    model == directAppleOnDevice
    ? l10n.appleOnDeviceUnavailable
    : l10n.applePccUnavailable;

/// How an Apple model stands: whether it can answer, and how close it is
/// to its usage limit.
String _appleAvailability(
  AppLocalizations l10n,
  String model,
  PlatformPccStatus status,
) {
  if (status.availability != PlatformPccAvailability.available) {
    return status.message ?? _appleUnavailable(l10n, model);
  }
  return switch (status.quotaStatus) {
    PlatformPccQuotaStatus.approachingLimit => l10n.applePccQuotaApproaching,
    PlatformPccQuotaStatus.limitReached => l10n.applePccQuotaReached,
    PlatformPccQuotaStatus.belowLimit ||
    PlatformPccQuotaStatus.unknown => l10n.applePccStatusAvailable,
  };
}

/// An Apple model's status line: its availability and context limit.
String _appleSummary(
  AppLocalizations l10n,
  String model,
  AsyncValue<PlatformPccStatus> status,
) {
  final value = status.value;
  if (value == null) {
    return status.isLoading
        ? l10n.loadingShort
        : _appleUnavailable(l10n, model);
  }
  return [
    _appleAvailability(l10n, model, value),
    if (reportedApplePccContextSize(value) case final tokens?)
      l10n.directContextLimit(_formatTokenCount(l10n, tokens)),
  ].join(' · ');
}

NativeSheetItemConfig _providerRow(
  AppLocalizations l10n,
  DirectConnectionProfile profile,
  DirectConnectionEditorSource source, {
  bool compatible = true,
}) {
  final status = !compatible
      ? l10n.directConnectionUnavailableLabel
      : profile.enabled
      ? l10n.enabledLabel
      : l10n.disabledLabel;
  return NativeSheetItemConfig(
    id: directConnectionPageId(source, profile.id),
    title: profile.name,
    subtitle:
        '${directProviderName(profile, l10n)} · $status\n${profile.baseUrl}',
    sfSymbol: profile.adapterKey == kOllamaAdapterKey
        ? 'desktopcomputer'
        : 'cloud',
  );
}

/// An MCP server's address without anything secret a query may carry.
String _publicEndpoint(DirectMcpServer server) {
  final uri = server.endpointUri;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

String _engineLabel(AppLocalizations l10n, WebSearchEngineChoice choice) =>
    choice.engine?.displayName ?? l10n.webSearchEngineAuto;

String _safeSearchLabel(AppLocalizations l10n, SafeSearch level) =>
    switch (level) {
      SafeSearch.strict => l10n.webSearchSafeSearchStrict,
      SafeSearch.moderate => l10n.webSearchSafeSearchModerate,
      SafeSearch.off => l10n.webSearchSafeSearchOff,
    };

String _regionName(AppLocalizations l10n, SearchRegion region) {
  if (region.isWorldwide) return l10n.webSearchRegionWorldwide;
  for (final option in kWebSearchRegions) {
    if (option.code == region.code) return option.name;
  }
  return region.code;
}

/// A picker of the context length of [model], which reports none.
NativeSheetItemConfig _contextLimitRow(
  AppLocalizations l10n,
  Model model,
  Map<String, int> overrides,
) {
  final current = overrides[model.id] ?? kDefaultDirectContextLength;
  return NativeSheetItemConfig(
    id: directRowId('context', model.id),
    title: model.name,
    subtitle: switch (model.metadata?['profileName']) {
      final String profileName => profileName,
      _ => null,
    },
    sfSymbol: 'gauge.with.dots.needle.67percent',
    kind: NativeSheetItemKind.segment,
    value: '$current',
    options: [
      // One stored before the choices changed stays shown.
      for (final tokens in {...kDirectContextLengthOptions, current})
        NativeSheetOptionConfig(
          id: '$tokens',
          label: l10n.directContextLimit(_formatTokenCount(l10n, tokens)),
        ),
    ],
  );
}

String _contextLimitsFooter(AppLocalizations l10n, List<Model> models) {
  // A limit picked for a local Ollama model is also sent as its num_ctx.
  final listsOllamaModel = models.any(
    (model) => model.metadata?['adapterKey'] == kOllamaAdapterKey,
  );
  return listsOllamaModel
      ? '${l10n.directContextCompactionDescription}\n\n'
            '${l10n.directContextLimitOllamaNote}'
      : l10n.directContextCompactionDescription;
}

/// The Direct Connections page.
NativeSheetDetailConfig buildDirectConnectionsPage(
  AppLocalizations l10n,
  DirectSettingsView view, {
  String? notice,
}) {
  const pageId = directConnectionsPageId;
  final profiles = view.profiles;
  final mcp = view.mcpServers;
  final openWebUi = view.openWebUi;
  final snapshot = openWebUi.value;
  final records =
      snapshot?.records ?? const <OpenWebUiDirectConnectionRecord>[];
  final apple = [
    for (final model in [directAppleOnDevice, directApplePcc])
      if (view.appleStatus(model) case final status?)
        NativeSheetItemConfig(
          id: directApplePageId(model),
          title: _appleTitle(l10n, model),
          subtitle: _appleSummary(l10n, model, status),
          sfSymbol: _appleSymbol(model),
        ),
  ];
  final contextModels = view.modelsWithoutContextLimit;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.directConnectionsTitle,
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(items: [_notice(pageId, notice)]),
      if (apple.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.backendChooserAppleSectionTitle,
          items: apple,
        ),
      if (contextModels.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.directContextCompactionTitle,
          footer: _contextLimitsFooter(l10n, contextModels),
          items: contextModels.length > kDirectContextLimitsInlineLimit
              ? [
                  NativeSheetItemConfig(
                    id: directContextLimitsPageId,
                    title: l10n.directContextCompactionModelCount(
                      contextModels.length,
                    ),
                    sfSymbol: 'gauge.with.dots.needle.67percent',
                  ),
                ]
              : [
                  for (final model in contextModels)
                    _contextLimitRow(l10n, model, view.contextLengthOverrides),
                ],
        ),
      if (view.showOpenWebUi) ...[
        NativeSheetSectionConfig(
          footer: view.syncWithOpenWebUi
              ? l10n.syncDirectHistorySubtitle
              : l10n.directHistoryLocalOnlySubtitle,
          items: [
            NativeSheetItemConfig(
              id: directRowId('history-sync'),
              title: l10n.syncDirectHistory,
              sfSymbol: 'arrow.triangle.2.circlepath',
              kind: NativeSheetItemKind.toggle,
              value: view.syncWithOpenWebUi,
            ),
          ],
        ),
        NativeSheetSectionConfig(
          title: l10n.openWebUiDirectConnectionsSectionTitle,
          footer: records.isEmpty && snapshot != null
              ? l10n.openWebUiDirectProfilesEmptySubtitle
              : null,
          items: [
            if (openWebUi.isLoading && snapshot == null)
              buildNativeLoadingItem(l10n, id: '$pageId-openwebui-loading'),
            for (final record in records)
              _providerRow(
                l10n,
                record.profile,
                DirectConnectionEditorSource.openWebUi,
                compatible: record.isCompatible,
              ),
            if (openWebUi.hasError) ...[
              NativeSheetItemConfig(
                id: '$pageId-openwebui-error',
                title: l10n.openWebUiDirectConnectionsLoadFailed,
                sfSymbol: 'exclamationmark.triangle',
                kind: NativeSheetItemKind.info,
              ),
              _retryRow(directRowId('retry-openwebui'), l10n),
            ],
            _addRow(
              directConnectionPageId(
                DirectConnectionEditorSource.openWebUi,
                null,
              ),
              l10n.addDirectConnection,
            ),
          ],
        ),
      ],
      NativeSheetSectionConfig(
        title: view.showOpenWebUi
            ? l10n.deviceDirectConnectionsSectionTitle
            : l10n.directConnectionsSectionTitle,
        footer: profiles.value?.isEmpty == true
            ? l10n.directProfilesEmptySubtitle
            : null,
        items: [
          ...profiles.when(
            loading: () => [
              buildNativeLoadingItem(l10n, id: '$pageId-profiles-loading'),
            ],
            error: (error, _) => [
              NativeSheetItemConfig(
                id: '$pageId-profiles-error',
                title: l10n.directConnectionError,
                subtitle: error is FormatException
                    ? l10n.directSavedDataUnreadable
                    : l10n.directSecureStorageUnavailable,
                sfSymbol: 'exclamationmark.triangle',
                kind: NativeSheetItemKind.info,
              ),
              _retryRow(directRowId('retry-profiles'), l10n),
            ],
            data: (items) => [
              for (final profile in items)
                _providerRow(l10n, profile, DirectConnectionEditorSource.local),
              _addRow(
                directConnectionPageId(
                  DirectConnectionEditorSource.local,
                  null,
                ),
                l10n.addDirectConnection,
              ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.directMcpServersTitle,
        footer: l10n.directMcpReachabilityHelp,
        items: [
          if (mcp.hasError) ...[
            NativeSheetItemConfig(
              id: '$pageId-mcp-error',
              title: l10n.directMcpLoadFailed,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
            _retryRow(directRowId('retry-mcp'), l10n),
          ] else if (!mcp.hasValue)
            buildNativeLoadingItem(l10n, id: '$pageId-mcp-loading')
          else
            for (final server in mcp.value!)
              NativeSheetItemConfig(
                id: directMcpPageId(server.id),
                title: server.name,
                subtitle:
                    '${server.enabled ? l10n.enabledLabel : l10n.disabledLabel}'
                    '\n${_publicEndpoint(server)}',
                sfSymbol: 'puzzlepiece.extension',
              ),
          _addRow(directMcpPageId(null), l10n.directMcpAddTitle),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.attachments,
        footer: l10n.directImagesPerRequestFooter,
        items: [
          NativeSheetItemConfig(
            id: directRowId('images'),
            title: l10n.directImagesPerRequest,
            sfSymbol: 'photo',
            kind: NativeSheetItemKind.segment,
            value: '${view.maxImagesPerRequest}',
            options: [
              for (final count in {
                ...kDirectMaxImagesPerRequestOptions,
                view.maxImagesPerRequest,
              })
                NativeSheetOptionConfig(
                  id: '$count',
                  label: _formatCount(l10n, count),
                ),
            ],
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.webSearch,
        footer: switch (view.webSearchEngine.engine) {
          null => l10n.webSearchSettingsFooterAuto,
          final engine => l10n.webSearchSettingsFooterEngine(
            engine.displayName,
          ),
        },
        items: [
          NativeSheetItemConfig(
            id: directRowId('web-engine'),
            title: l10n.webSearchEngineLabel,
            sfSymbol: 'magnifyingglass',
            kind: NativeSheetItemKind.segment,
            value: view.webSearchEngine.name,
            options: [
              for (final choice in WebSearchEngineChoice.values)
                NativeSheetOptionConfig(
                  id: choice.name,
                  label: _engineLabel(l10n, choice),
                ),
            ],
          ),
          NativeSheetItemConfig(
            id: directRowId('web-safe-search'),
            title: l10n.webSearchSafeSearchLabel,
            sfSymbol: 'checkmark.shield',
            kind: NativeSheetItemKind.segment,
            value: view.webSearchSafeSearch.name,
            options: [
              for (final level in SafeSearch.values)
                NativeSheetOptionConfig(
                  id: level.name,
                  label: _safeSearchLabel(l10n, level),
                ),
            ],
          ),
          NativeSheetItemConfig(
            id: directRowId('web-region'),
            title: l10n.webSearchRegionLabel,
            subtitle: view.webSearchRegion == null
                ? '${l10n.webSearchRegionAuto} '
                      '(${_regionName(l10n, view.effectiveRegion)})'
                : _regionName(l10n, view.effectiveRegion),
            sfSymbol: 'globe',
            kind: NativeSheetItemKind.searchablePicker,
            value: view.webSearchRegion ?? kWebSearchRegionAuto,
            options: [
              NativeSheetOptionConfig(
                id: kWebSearchRegionAuto,
                label: l10n.webSearchRegionAuto,
              ),
              NativeSheetOptionConfig(
                id: SearchRegion.worldwide.code,
                label: l10n.webSearchRegionWorldwide,
              ),
              for (final option in kWebSearchRegions)
                NativeSheetOptionConfig(id: option.code, label: option.name),
            ],
          ),
        ],
      ),
    ],
  );
}

/// The pages the Direct page leads to, each filled in as it appears.
List<NativeSheetDetailConfig> directConnectionsChildPages(
  AppLocalizations l10n,
  DirectSettingsView view,
) {
  NativeSheetDetailConfig loading(String id, String title) =>
      buildNativeLoadingDetail(l10n: l10n, id: id, title: title);
  return [
    for (final model in [directAppleOnDevice, directApplePcc])
      if (view.appleStatus(model) != null)
        loading(directApplePageId(model), _appleTitle(l10n, model)),
    if (view.modelsWithoutContextLimit.length > kDirectContextLimitsInlineLimit)
      loading(directContextLimitsPageId, l10n.directContextCompactionTitle),
    if (view.showOpenWebUi) ...[
      for (final record
          in view.openWebUi.value?.records ??
              const <OpenWebUiDirectConnectionRecord>[])
        loading(
          directConnectionPageId(
            DirectConnectionEditorSource.openWebUi,
            record.profile.id,
          ),
          l10n.editDirectConnection,
        ),
      loading(
        directConnectionPageId(DirectConnectionEditorSource.openWebUi, null),
        l10n.addDirectConnection,
      ),
    ],
    for (final profile
        in view.profiles.value ?? const <DirectConnectionProfile>[])
      loading(
        directConnectionPageId(DirectConnectionEditorSource.local, profile.id),
        l10n.editDirectConnection,
      ),
    loading(
      directConnectionPageId(DirectConnectionEditorSource.local, null),
      l10n.addDirectConnection,
    ),
    for (final server in view.mcpServers.value ?? const <DirectMcpServer>[])
      loading(directMcpPageId(server.id), l10n.directMcpEditorTitle),
    loading(directMcpPageId(null), l10n.directMcpAddTitle),
  ];
}

/// The Direct pages the Accounts page leads to: Direct's own, each Apple
/// model's offered, each provider's editor and the editors adding one, each
/// filled in as it appears.
List<NativeSheetDetailConfig> directAccountsChildPages(
  AppLocalizations l10n, {
  required List<DirectConnectionProfile> profiles,
  required bool appleOnDevice,
  required bool applePcc,
}) {
  NativeSheetDetailConfig loading(String id, String title) =>
      buildNativeLoadingDetail(l10n: l10n, id: id, title: title);
  return [
    loading(directConnectionsPageId, l10n.directConnectionsTitle),
    if (appleOnDevice)
      loading(
        directApplePageId(directAppleOnDevice),
        _appleTitle(l10n, directAppleOnDevice),
      ),
    if (applePcc)
      loading(
        directApplePageId(directApplePcc),
        _appleTitle(l10n, directApplePcc),
      ),
    for (final profile in profiles)
      loading(
        directConnectionPageId(DirectConnectionEditorSource.local, profile.id),
        l10n.editDirectConnection,
      ),
    loading(
      directConnectionPageId(DirectConnectionEditorSource.local, null),
      l10n.addDirectConnection,
    ),
    loading(directConnectionAddAccountPageId, l10n.addDirectConnection),
  ];
}

/// An Apple model's page: how it stands, tapped to check again; for
/// Private Cloud Compute, whether to fall back to the on-device model and
/// how to raise its limit.
NativeSheetDetailConfig buildDirectApplePage(
  AppLocalizations l10n, {
  required String model,
  required AsyncValue<PlatformPccStatus>? status,
  required bool fallback,
  String? notice,
}) {
  final pageId = directApplePageId(model);
  final value = status?.value;
  final notes = <String>[
    if (value?.quotaResetAtMilliseconds case final milliseconds?)
      l10n.applePccQuotaResetsAt(
        _formatDate(
          l10n,
          DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal(),
          withTime: true,
        ),
      ),
    if (value?.supportsCurrentLocale == false)
      l10n.applePccCurrentLanguageUnsupported,
  ];
  final pcc = model == directApplePcc;
  return NativeSheetDetailConfig(
    id: pageId,
    title: _appleTitle(l10n, model),
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(items: [_notice(pageId, notice)]),
      NativeSheetSectionConfig(
        footer: notes.isEmpty ? null : notes.join('\n'),
        items: [
          // Tapped, it checks again.
          NativeSheetItemConfig(
            id: directRowId('apple-refresh', model),
            title: _appleTitle(l10n, model),
            subtitle: status == null
                ? _appleUnavailable(l10n, model)
                : _appleSummary(l10n, model, status),
            sfSymbol: _appleSymbol(model),
            showsDisclosure: false,
            pending: status?.isLoading ?? false,
            disabled: status == null || status.isLoading,
          ),
        ],
      ),
      if (pcc)
        NativeSheetSectionConfig(
          footer: l10n.applePccOnDeviceFallbackSubtitle,
          items: [
            NativeSheetItemConfig(
              id: directRowId('apple-fallback'),
              title: l10n.applePccOnDeviceFallback,
              sfSymbol: 'iphone',
              kind: NativeSheetItemKind.toggle,
              value: fallback,
            ),
          ],
        ),
      if (pcc && value?.canIncreaseQuota == true)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: directRowId('apple-quota'),
              title: l10n.applePccShowQuotaOptions,
              sfSymbol: 'gauge.with.dots.needle.67percent',
              accent: true,
              showsDisclosure: false,
            ),
          ],
        ),
    ],
  );
}

/// Context limits for every Direct model that doesn't report one.
NativeSheetDetailConfig buildDirectContextLimitsPage(
  AppLocalizations l10n,
  DirectSettingsView view,
) => NativeSheetDetailConfig(
  id: directContextLimitsPageId,
  title: l10n.directContextCompactionTitle,
  sections: [
    NativeSheetSectionConfig(
      footer: _contextLimitsFooter(l10n, view.modelsWithoutContextLimit),
      items: [
        for (final model in view.modelsWithoutContextLimit)
          _contextLimitRow(l10n, model, view.contextLengthOverrides),
      ],
    ),
  ],
);

List<NativeSheetOptionConfig> _providerOptions(
  AppLocalizations l10n,
  DirectConnectionEditorForm form,
) {
  final options = [
    NativeSheetOptionConfig(
      id: kOpenAiCompatibleAdapterKey,
      label: l10n.openAICompatible,
    ),
    NativeSheetOptionConfig(
      id: kOpenRouterProviderPreset,
      label: l10n.openRouterProviderName,
    ),
    NativeSheetOptionConfig(id: kOllamaAdapterKey, label: l10n.ollama),
  ];
  if (options.any((option) => option.id == form.providerPreset)) {
    return options;
  }
  // A kind of provider this version doesn't know stays shown, and can't be
  // chosen again once left.
  return [
    NativeSheetOptionConfig(
      id: form.providerPreset,
      label: form.providerPreset,
      enabled: false,
    ),
    ...options,
  ];
}

List<NativeSheetOptionConfig> _authenticationOptions(
  AppLocalizations l10n,
  DirectConnectionEditorForm form,
) => [
  NativeSheetOptionConfig(
    id: DirectAuthenticationMode.bearer.name,
    label: l10n.bearerToken,
  ),
  if (form.canSelectApiKeyHeader)
    NativeSheetOptionConfig(
      id: DirectAuthenticationMode.apiKeyHeader.name,
      label: l10n.directApiKeyHeader,
    ),
  if (form.canSelectNoAuthentication)
    NativeSheetOptionConfig(
      id: DirectAuthenticationMode.none.name,
      label: l10n.noAuthentication,
    ),
  if (form.authentication == DirectAuthenticationMode.unsupported)
    NativeSheetOptionConfig(
      id: DirectAuthenticationMode.unsupported.name,
      label: l10n.directConnectionUnavailableLabel,
      enabled: false,
    ),
];

/// What is wrong with the editor's provider, as the form last checked it,
/// or what the last save said.
String? _editorProblem(
  AppLocalizations l10n,
  DirectConnectionEditorWorkflow workflow,
) {
  final form = workflow.form;
  final problems = <String>{
    ?workflow.state.operationError,
    ?directDraftValidationMessage(l10n, form.errors.form),
    ?form.errors.profile,
    ?directDraftValidationMessage(l10n, form.errors.name),
    ?directDraftValidationMessage(l10n, form.errors.url),
    ?directDraftValidationMessage(l10n, form.errors.apiKey),
    ?directHeaderValidationMessage(l10n, form.headerError),
  };
  return problems.isEmpty ? null : problems.join('\n');
}

/// A provider's editor: whether it is on and which kind of provider it is,
/// its name, address and credentials, a row to its Advanced page, Test,
/// and Delete for a saved one. Done saves.
///
/// [running] is the action under way: Done waits while it saves, and the
/// rows while it tests or deletes.
NativeSheetDetailConfig buildDirectConnectionEditorPage(
  AppLocalizations l10n, {
  required String editorKey,
  required DirectConnectionEditorWorkflow workflow,
  DirectEditorOperation running = DirectEditorOperation.idle,
  bool edited = false,
  String? notice,
}) {
  final pageId = '$directConnectionPagePrefix$editorKey';
  final mode = workflow.mode;
  final policy = workflow.policy;
  final form = workflow.form;
  final title = mode.isNew
      ? l10n.addDirectConnection
      : l10n.editDirectConnection;
  NativeSheetDetailConfig only(NativeSheetItemConfig item) =>
      NativeSheetDetailConfig(id: pageId, title: title, items: [item]);

  switch (workflow.resourceState) {
    case DirectEditorLoadLoading():
      return only(buildNativeLoadingItem(l10n, id: '$pageId-loading'));
    case DirectEditorLoadFailure():
      return NativeSheetDetailConfig(
        id: pageId,
        title: title,
        sections: [
          NativeSheetSectionConfig(
            items: [
              _notice(pageId, l10n.openWebUiDirectConnectionsLoadFailed),
              _retryRow(directConnectionRowId('retry', editorKey), l10n),
            ],
          ),
        ],
      );
    case DirectEditorLoadData(:final resource):
      // The account that kept it signed out, or another took over.
      if ((policy.requiresOwnerValidation &&
              !workflow.resourceOwnerMatches(resource)) ||
          resource.availability ==
              DirectEditorResourceAvailability.unavailable) {
        return only(
          _notice(pageId, l10n.openWebUiDirectConnectionsUnavailable),
        );
      }
      if (resource.availability == DirectEditorResourceAvailability.missing) {
        return only(_notice(pageId, l10n.directConnectionNoLongerExists));
      }
  }

  final locked = running != DirectEditorOperation.idle;
  final unsupported =
      form.authentication == DirectAuthenticationMode.unsupported;
  final attempt = workflow.state.attempt;
  final showsApiKey =
      form.authentication == DirectAuthenticationMode.bearer ||
      form.authentication == DirectAuthenticationMode.apiKeyHeader;
  final problem = notice ?? _editorProblem(l10n, workflow);
  final testing = running == DirectEditorOperation.testing;
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: directConnectionRowId('save', editorKey),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: running == DirectEditorOperation.saving,
    edited: edited,
    announcement: problem ?? (testing ? null : attempt.message),
    sections: [
      if (problem != null)
        NativeSheetSectionConfig(items: [_notice(pageId, problem)]),
      NativeSheetSectionConfig(
        footer: policy.editsProvider
            ? l10n.directConnectionEnabledSubtitle
            : '${l10n.openWebUiDirectConnectionEditorDescription}\n\n'
                  '${l10n.openWebUiDirectConnectionProviderDescription}',
        items: [
          NativeSheetItemConfig(
            id: directConnectionRowId('enabled', editorKey),
            title: l10n.enabledLabel,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: form.enabled,
            disabled: locked,
          ),
          if (policy.editsProvider)
            NativeSheetItemConfig(
              id: directConnectionRowId('provider', editorKey),
              title: l10n.directProvider,
              sfSymbol: 'cube.box',
              kind: NativeSheetItemKind.segment,
              value: form.providerPreset,
              options: _providerOptions(l10n, form),
              disabled: locked,
            )
          else
            // An Open WebUI account's providers are all OpenAI-compatible.
            NativeSheetItemConfig(
              id: directConnectionRowId('provider', editorKey),
              title: l10n.directProvider,
              subtitle: l10n.openAICompatible,
              sfSymbol: 'cube.box',
              kind: NativeSheetItemKind.info,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: [
          if (form.isOllama)
            l10n.ollamaCloudBaseUrlDescription
          else if (form.isOpenRouter)
            l10n.directOpenRouterBaseUrlDescription
          else
            l10n.directBaseUrlDescription,
          if (form.authentication == DirectAuthenticationMode.bearer &&
              form.canSelectApiKeyHeader)
            l10n.directBearerDescription,
          if (form.authentication == DirectAuthenticationMode.apiKeyHeader)
            l10n.directApiKeyHeaderAzureOnlyDescription,
          if (unsupported) l10n.openWebUiDirectConnectionUnsupportedAuth,
        ].join('\n\n'),
        items: [
          if (policy.editsName)
            NativeSheetItemConfig(
              id: directConnectionRowId('name', editorKey),
              title: l10n.directConnectionName,
              sfSymbol: 'tag',
              kind: NativeSheetItemKind.textField,
              value: form.name.text,
              placeholder: form.isOllama
                  ? l10n.ollamaCloudDefaultName
                  : form.isOpenRouter
                  ? l10n.openRouterProviderName
                  : l10n.directDefaultConnectionName,
              disabled: locked,
            ),
          NativeSheetItemConfig(
            id: directConnectionRowId('url', editorKey),
            title: l10n.directApiBaseUrl,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: form.baseUrl.text,
            placeholder: form.isOllama
                ? l10n.ollamaCloudBaseUrlHint
                : form.isOpenRouter
                ? kOpenRouterApiBaseUrl
                : 'https://api.openai.com/v1',
            keyboard: NativeSheetKeyboard.url,
            disabled: locked,
          ),
          NativeSheetItemConfig(
            id: directConnectionRowId('auth', editorKey),
            title: l10n.directAuthentication,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.segment,
            value: form.authentication.name,
            options: _authenticationOptions(l10n, form),
            disabled: locked,
          ),
          if (showsApiKey)
            NativeSheetItemConfig(
              id: directConnectionRowId('api-key', editorKey),
              title: l10n.directApiKey,
              sfSymbol: 'key',
              kind: NativeSheetItemKind.secureTextField,
              value: form.apiKey.text,
              placeholder: (form.savedProfile?.apiKey ?? '').isNotEmpty
                  ? l10n.directConfiguredReplacePlaceholder
                  : l10n.directApiKeyPlaceholder,
              disabled: locked,
            ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: '$directConnectionAdvancedPagePrefix$editorKey',
            title: l10n.advancedSettings,
            subtitle: form.customHeaders.isEmpty
                ? null
                : '${l10n.directCustomHeaders}: ${form.customHeaders.length}',
            sfSymbol: 'gearshape',
            disabled: locked,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: directConnectionRowId('test', editorKey),
            title: l10n.testDirectConnection,
            sfSymbol: 'bolt',
            accent: true,
            showsDisclosure: false,
            pending: testing,
            disabled: locked || unsupported,
          ),
          if (attempt.isVisible && !testing)
            NativeSheetItemConfig(
              id: '$pageId-attempt',
              title: attempt.message ?? '',
              sfSymbol: attempt.phase == ConnectionAttemptPhase.connected
                  ? 'checkmark.circle'
                  : 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
        ],
      ),
      if (!mode.isNew)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: directConnectionRowId('delete', editorKey),
              title: l10n.delete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              pending: running == DirectEditorOperation.deleting,
              disabled: locked,
            ),
          ],
        ),
    ],
  );
}

/// A provider's Advanced page: which completion API it speaks, the headers
/// sent with every request, each removed from its menu, how its models are
/// named and tagged, and models it lists by hand.
NativeSheetDetailConfig buildDirectConnectionAdvancedPage(
  AppLocalizations l10n, {
  required String editorKey,
  required DirectConnectionEditorForm form,
}) {
  final pageId = '$directConnectionAdvancedPagePrefix$editorKey';
  final apiDescription = form.isOpenRouter
      ? l10n.directOpenRouterChatCompletionsDescription
      : form.openAiApiMode == DirectOpenAiApiMode.responses
      ? l10n.directResponsesDescription
      : l10n.directChatCompletionsDescription;
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.advancedSettings,
    sections: [
      // Ollama speaks its own API.
      if (!form.isOllama)
        NativeSheetSectionConfig(
          footer: form.isOpenRouter
              ? apiDescription
              : '$apiDescription\n\n${l10n.directApiVersionDescription}',
          items: [
            if (form.isOpenRouter)
              NativeSheetItemConfig(
                id: directConnectionRowId('api-mode', editorKey),
                title: l10n.directCompletionApi,
                subtitle: l10n.directChatCompletions,
                sfSymbol: 'text.bubble',
                kind: NativeSheetItemKind.info,
              )
            else ...[
              NativeSheetItemConfig(
                id: directConnectionRowId('api-mode', editorKey),
                title: l10n.directCompletionApi,
                sfSymbol: 'text.bubble',
                kind: NativeSheetItemKind.segment,
                value: form.openAiApiMode.name,
                options: [
                  NativeSheetOptionConfig(
                    id: DirectOpenAiApiMode.chatCompletions.name,
                    label: l10n.directChatCompletions,
                  ),
                  NativeSheetOptionConfig(
                    id: DirectOpenAiApiMode.responses.name,
                    label: l10n.directResponses,
                  ),
                ],
              ),
              NativeSheetItemConfig(
                id: directConnectionRowId('api-version', editorKey),
                title: l10n.directApiVersion,
                sfSymbol: 'number',
                kind: NativeSheetItemKind.textField,
                value: form.apiVersion.text,
                placeholder: '2024-10-21',
              ),
            ],
          ],
        ),
      NativeSheetSectionConfig(
        title: l10n.directCustomHeaders,
        footer: l10n.customHeadersDescription,
        items: [
          for (final header in form.customHeaders.entries)
            NativeSheetItemConfig(
              id: directConnectionRowId('header', editorKey, header.key),
              title: header.key,
              subtitle: header.value,
              sfSymbol: 'list.bullet.rectangle',
              kind: NativeSheetItemKind.info,
              rowActions: [
                NativeSheetRowAction(
                  id: directConnectionRowId(
                    'header-remove',
                    editorKey,
                    header.key,
                  ),
                  label: l10n.removeHeader,
                  sfSymbol: 'trash',
                  destructive: true,
                ),
              ],
            ),
          _addRow(
            '$directConnectionHeaderPagePrefix$editorKey',
            l10n.addHeader,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        footer:
            '${l10n.directModelIdPrefixDescription}\n\n'
            '${l10n.directModelTagsDescription}',
        items: [
          NativeSheetItemConfig(
            id: directConnectionRowId('prefix', editorKey),
            title: l10n.directModelIdPrefix,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: form.modelIdPrefix.text,
            placeholder: 'studio',
          ),
          NativeSheetItemConfig(
            id: directConnectionRowId('tags', editorKey),
            title: l10n.directModelTags,
            sfSymbol: 'tag',
            kind: NativeSheetItemKind.textField,
            value: form.tags.text,
            placeholder: 'local, private',
          ),
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.directManualModelIds,
        footer: l10n.directManualModelIdsDescription,
        items: [
          NativeSheetItemConfig(
            id: directConnectionRowId('models', editorKey),
            title: l10n.directManualModelIds,
            sfSymbol: 'cube.box',
            kind: NativeSheetItemKind.multilineTextField,
            value: form.models.text,
            placeholder: 'model-a\nmodel-b',
          ),
        ],
      ),
    ],
  );
}

/// The page adding a header to a provider: its name and value; Done adds
/// it.
NativeSheetDetailConfig buildDirectConnectionHeaderPage(
  AppLocalizations l10n, {
  required String editorKey,
  String name = '',
  String value = '',
  String? notice,
}) {
  final pageId = '$directConnectionHeaderPagePrefix$editorKey';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.addHeader,
    confirmActionId: directConnectionRowId('header-add', editorKey),
    confirmActionLabel: l10n.addHeader,
    discardPrompt: nativeDiscardPrompt(l10n),
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(items: [_notice(pageId, notice)]),
      NativeSheetSectionConfig(
        footer: l10n.customHeadersDescription,
        items: [
          NativeSheetItemConfig(
            id: directConnectionRowId('header-name', editorKey),
            title: l10n.headerName,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: name,
            placeholder: 'X-Custom-Header',
          ),
          NativeSheetItemConfig(
            id: directConnectionRowId('header-value', editorKey),
            title: l10n.headerValue,
            sfSymbol: 'text.alignleft',
            kind: NativeSheetItemKind.textField,
            value: value,
            placeholder: l10n.headerValueHint,
          ),
        ],
      ),
    ],
  );
}

/// An MCP server's editor: its name, endpoint and whether it is on; how it
/// signs in, OAuth in the browser; its headers; the tools it may run
/// without asking, each revocable from its menu; Test, and Delete for a
/// stored one. Done saves.
NativeSheetDetailConfig buildDirectMcpServerPage(
  AppLocalizations l10n, {
  required String serverKey,
  required DirectMcpServerEditor editor,
  bool loadFailed = false,
  bool edited = false,
  bool saving = false,
  bool testing = false,
}) {
  final pageId = '$directMcpPagePrefix$serverKey';
  final stored = editor.previous;
  final title = stored == null && editor.createsServer
      ? l10n.directMcpAddTitle
      : l10n.directMcpEditorTitle;
  NativeSheetDetailConfig only(NativeSheetItemConfig item) =>
      NativeSheetDetailConfig(id: pageId, title: title, items: [item]);
  if (!editor.initialized) {
    return only(
      loadFailed
          ? _notice(pageId, l10n.directMcpLoadFailed)
          : buildNativeLoadingItem(l10n, id: '$pageId-loading'),
    );
  }
  if (editor.missing) return only(_notice(pageId, l10n.directMcpMissing));

  final busy = editor.busy || saving;
  final oauthPending = editor.oauthPending;
  final tokens = stored?.oauthTokens;
  final approvals = stored?.rememberedApprovals ?? const [];
  final message = testing ? null : editor.message;
  return NativeSheetDetailConfig(
    id: pageId,
    title: title,
    confirmActionId: directMcpRowId('save', serverKey),
    confirmActionLabel: l10n.save,
    discardPrompt: nativeDiscardPrompt(l10n),
    busy: saving,
    edited: edited,
    announcement: message,
    sections: [
      NativeSheetSectionConfig(
        footer: l10n.directMcpReachabilityHelp,
        items: [
          NativeSheetItemConfig(
            id: directMcpRowId('name', serverKey),
            title: l10n.directMcpName,
            sfSymbol: 'tag',
            kind: NativeSheetItemKind.textField,
            value: editor.name.text,
            disabled: busy,
          ),
          NativeSheetItemConfig(
            id: directMcpRowId('endpoint', serverKey),
            title: l10n.directMcpEndpoint,
            sfSymbol: 'link',
            kind: NativeSheetItemKind.textField,
            value: editor.endpoint.text,
            placeholder: 'https://',
            keyboard: NativeSheetKeyboard.url,
            disabled: busy || oauthPending,
          ),
          NativeSheetItemConfig(
            id: directMcpRowId('enabled', serverKey),
            title: l10n.enabledLabel,
            sfSymbol: 'power',
            kind: NativeSheetItemKind.toggle,
            value: editor.enabled,
            disabled: busy,
          ),
        ],
      ),
      NativeSheetSectionConfig(
        footer: tokens == null || editor.authMode != DirectMcpAuthMode.oauth
            ? null
            : l10n.directMcpOAuthConnectionDetails(
                Uri.parse(tokens.authorizationServerIssuer).host,
                tokens.grantedScope ?? l10n.directMcpOAuthNoScopes,
              ),
        items: [
          NativeSheetItemConfig(
            id: directMcpRowId('auth', serverKey),
            title: l10n.directMcpAuthMode,
            sfSymbol: 'lock',
            kind: NativeSheetItemKind.segment,
            value: editor.authMode.name,
            options: [
              NativeSheetOptionConfig(
                id: DirectMcpAuthMode.none.name,
                label: l10n.directMcpAuthNone,
              ),
              NativeSheetOptionConfig(
                id: DirectMcpAuthMode.bearer.name,
                label: l10n.directMcpAuthBearer,
              ),
              NativeSheetOptionConfig(
                id: DirectMcpAuthMode.oauth.name,
                label: l10n.directMcpAuthOAuth,
              ),
            ],
            disabled: busy || oauthPending,
          ),
          if (editor.authMode == DirectMcpAuthMode.bearer)
            NativeSheetItemConfig(
              id: directMcpRowId('token', serverKey),
              title: l10n.directMcpBearerToken,
              sfSymbol: 'key',
              kind: NativeSheetItemKind.secureTextField,
              value: editor.token.text,
              disabled: busy,
            ),
          if (editor.authMode == DirectMcpAuthMode.oauth) ...[
            // While the browser is out, the row that sent it there calls
            // it back.
            if (oauthPending)
              NativeSheetItemConfig(
                id: directMcpRowId('oauth-cancel', serverKey),
                title: l10n.cancel,
                sfSymbol: 'xmark.circle',
                accent: true,
                showsDisclosure: false,
                pending: true,
              )
            else
              NativeSheetItemConfig(
                id: directMcpRowId('oauth-connect', serverKey),
                title: tokens == null
                    ? l10n.directMcpOAuthConnect
                    : l10n.directMcpOAuthReconnect,
                sfSymbol: 'globe',
                accent: true,
                showsDisclosure: false,
                disabled: busy,
              ),
            if (tokens != null && !oauthPending)
              NativeSheetItemConfig(
                id: directMcpRowId('oauth-disconnect', serverKey),
                title: l10n.directMcpOAuthDisconnect,
                sfSymbol: 'xmark.circle',
                destructive: true,
                showsDisclosure: false,
                disabled: busy,
              ),
          ],
        ],
      ),
      NativeSheetSectionConfig(
        title: l10n.directMcpCustomHeaders,
        footer: l10n.customHeadersDescription,
        items: [
          for (final header in editor.headerEntries)
            NativeSheetItemConfig(
              id: directMcpRowId('header', serverKey, header.key),
              title: header.key,
              subtitle: header.value,
              sfSymbol: 'list.bullet.rectangle',
              kind: NativeSheetItemKind.info,
              rowActions: [
                if (!busy)
                  NativeSheetRowAction(
                    id: directMcpRowId('header-remove', serverKey, header.key),
                    label: l10n.removeHeader,
                    sfSymbol: 'trash',
                    destructive: true,
                  ),
              ],
            ),
          NativeSheetItemConfig(
            id: '$directMcpHeaderPagePrefix$serverKey',
            title: l10n.addHeader,
            sfSymbol: 'plus.circle',
            accent: true,
            disabled: busy,
          ),
        ],
      ),
      if (approvals.isNotEmpty)
        NativeSheetSectionConfig(
          title: l10n.directMcpRememberedApprovalsTitle,
          footer: l10n.directMcpRememberedApprovalsSubtitle,
          items: [
            for (final approval in approvals)
              NativeSheetItemConfig(
                id: directMcpRowId('approval', serverKey, approval.digest),
                title: approval.displayName,
                subtitle:
                    '${approval.remoteToolName} · '
                    '${_formatDate(l10n, approval.createdAt.toLocal())}',
                sfSymbol: 'checkmark.shield',
                kind: NativeSheetItemKind.info,
                rowActions: [
                  if (!busy && !oauthPending)
                    NativeSheetRowAction(
                      id: directMcpRowId(
                        'approval-revoke',
                        serverKey,
                        approval.digest,
                      ),
                      label: l10n.directMcpRememberedApprovalRevoke,
                      sfSymbol: 'xmark.circle',
                      destructive: true,
                    ),
                ],
              ),
            NativeSheetItemConfig(
              id: directMcpRowId('approvals-revoke-all', serverKey),
              title: l10n.directMcpRememberedApprovalsRevokeAll,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: busy || oauthPending,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: directMcpRowId('test', serverKey),
            title: l10n.directMcpTestConnection,
            sfSymbol: 'bolt',
            accent: true,
            showsDisclosure: false,
            pending: testing,
            disabled: busy,
          ),
          if (message != null)
            NativeSheetItemConfig(
              id: '$pageId-message',
              title: message,
              sfSymbol: 'info.circle',
              kind: NativeSheetItemKind.info,
            ),
        ],
      ),
      if (stored != null)
        NativeSheetSectionConfig(
          items: [
            NativeSheetItemConfig(
              id: directMcpRowId('delete', serverKey),
              title: l10n.delete,
              sfSymbol: 'trash',
              destructive: true,
              showsDisclosure: false,
              disabled: busy,
            ),
          ],
        ),
    ],
  );
}

/// The page adding a header to an MCP server: its name and value, checked
/// as a provider's are; Done adds it.
NativeSheetDetailConfig buildDirectMcpHeaderPage(
  AppLocalizations l10n, {
  required String serverKey,
  String name = '',
  String value = '',
  String? notice,
}) {
  final pageId = '$directMcpHeaderPagePrefix$serverKey';
  return NativeSheetDetailConfig(
    id: pageId,
    title: l10n.addHeader,
    confirmActionId: directMcpRowId('header-add', serverKey),
    confirmActionLabel: l10n.addHeader,
    discardPrompt: nativeDiscardPrompt(l10n),
    announcement: notice,
    sections: [
      if (notice != null)
        NativeSheetSectionConfig(items: [_notice(pageId, notice)]),
      NativeSheetSectionConfig(
        footer: l10n.customHeadersDescription,
        items: [
          NativeSheetItemConfig(
            id: directMcpRowId('header-name', serverKey),
            title: l10n.headerName,
            sfSymbol: 'textformat',
            kind: NativeSheetItemKind.textField,
            value: name,
            placeholder: 'X-Custom-Header',
          ),
          NativeSheetItemConfig(
            id: directMcpRowId('header-value', serverKey),
            title: l10n.headerValue,
            sfSymbol: 'text.alignleft',
            kind: NativeSheetItemKind.textField,
            value: value,
            placeholder: l10n.headerValueHint,
          ),
        ],
      ),
    ],
  );
}
