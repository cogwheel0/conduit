import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'package:conduit_core/features/tools/providers/tools_providers.dart';

import '../../features/chat/providers/text_to_speech_provider.dart';

import 'package:conduit_core/features/chat/models/model_selector_layout.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show
        captureOpenWebUiReasoningPickTarget,
        chatDataControlsEntryVisibleProvider,
        selectReasoningEffortForModel;
import 'package:conduit_core/features/chat/providers/reasoning_effort_provider.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/theme/tweakcn_themes.dart';

import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/tool.dart';

import '../network/image_header_utils.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show scheduledTasksEntryVisibleProvider;
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart'
    show currentUserProvider2;
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart'
    show calendarAvailableProvider;
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart'
    show personalConnectionsEntryVisibleProvider;
import 'package:conduit_core/features/notifications/providers/notification_target_providers.dart'
    show notificationTargetsAvailableProvider, notificationTargetsProvider;
import 'package:conduit_core/navigation/routes.dart'
    show permittedWorkspaceSections;
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart'
    show workspaceCapabilitiesProvider;

import 'package:conduit_core/utils/debug_logger.dart';

import '../utils/model_icon_utils.dart';
import '../utils/model_logos.dart';

import 'package:conduit_core/utils/model_sort_utils.dart';

import '../utils/native_sheet_utils.dart';
import 'native_sheet_avatar_bytes_hydrator.dart';
import 'native_sheet_bridge.dart';
import '../../shared/services/navigation_service.dart';

import 'package:conduit_core/services/settings_service.dart';

import '../../shared/theme/theme_providers.dart';
import '../../shared/services/app_package_info.dart';
import '../utils/account_display.dart';

final nativeSheetHydrationServiceProvider =
    Provider<NativeSheetHydrationService>(NativeSheetHydrationService.new);

final nativeSheetAvatarBytesHydratorProvider =
    Provider<NativeSheetAvatarBytesHydrator>(
      (_) => NativeSheetAvatarBytesHydrator(),
    );

@visibleForTesting
class NativeSheetHydrationGeneration {
  int _current = 0;

  int begin() => ++_current;

  bool isActive(int generation) => generation == _current;

  void finish(int generation) {
    if (isActive(generation)) {
      _current += 1;
    }
  }
}

@visibleForTesting
class NativeSheetPresentationAdmission {
  bool _active = false;

  bool tryBegin() {
    if (_active) return false;
    _active = true;
    return true;
  }

  void finish() => _active = false;
}

/// Reads a provider once; both `Ref.read` and `WidgetRef.read` fit.
typedef NativeSheetProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Which root rows the signed-in account is offered right now, read from the
/// providers the Flutter Settings page watches.
NativeProfileRootVisibility readNativeProfileRootVisibility(
  NativeSheetProviderReader read,
) => NativeProfileRootVisibility(
  showCalendar: read(calendarAvailableProvider),
  canManageWorkspace: read(workspaceCapabilitiesProvider).maybeWhen(
    data: (value) => permittedWorkspaceSections(value).isNotEmpty,
    orElse: () => false,
  ),
  showScheduledTasks: read(scheduledTasksEntryVisibleProvider),
  showPersonalConnections: read(personalConnectionsEntryVisibleProvider),
  showChatDataControls: read(chatDataControlsEntryVisibleProvider),
);

/// The native Settings root on screen and the account it was built for.
final class _NativeProfileRoot {
  const _NativeProfileRoot({
    required this.account,
    required this.api,
    required this.userId,
  });

  final NativeProfileRootAccount? account;
  final Object? api;
  final String? userId;
}

@visibleForTesting
ReasoningEffortPolicy nativeModelSelectorReasoningEffortPolicy(
  bool hydrated,
  ReasoningEffortPolicy hydratedPolicy,
) => hydrated ? hydratedPolicy : ReasoningEffortPolicy.unsupported;

@visibleForTesting
({ReasoningEffortPolicy policy, String value})
nativeHydratedServerReasoningEffort({
  required Model model,
  required ServerModelReasoningEffort detail,
  String? personalizationEffort,
  String? localEffort,
}) {
  final modelEffort = detail.value ?? modelConfiguredReasoningEffort(model);
  final policy = model.supportsReasoningEffort || modelEffort != null
      ? ReasoningEffortPolicy.generic
      : ReasoningEffortPolicy.unsupported;
  return (
    policy: policy,
    value:
        policy.effectiveConfiguredEffort(
          localEffort ?? modelEffort ?? personalizationEffort,
        ) ??
        kAutomaticReasoningEffort,
  );
}

class NativeSheetHydrationService {
  NativeSheetHydrationService(this._ref) {
    final sheetEvents = NativeSheetBridge.instance.events.listen((event) {
      if (event is NativeSheetDismissed) _appearanceDetailPresented = false;
    });
    _ref.onDispose(sheetEvents.cancel);
    // The native sheet keeps the rows it was handed, so a language chosen
    // inside it left every label in the old language until the sheet was
    // reopened. Hand it rows built in the new language.
    _ref.listen<Locale?>(appLocaleProvider, (previous, next) {
      if (previous == next || !_appearanceDetailPresented) return;
      unawaited(_rehydrateAppearanceAfterLocaleChange());
    });
  }

  final Ref _ref;
  bool _appearanceDetailPresented = false;
  MemoryOwner? _memoryOwner;
  _NativeProfileRoot? _profileRoot;
  final NativeSheetHydrationGeneration _notificationsHydration =
      NativeSheetHydrationGeneration();
  final NativeSheetHydrationGeneration _modelSelectorHydration =
      NativeSheetHydrationGeneration();
  final NativeSheetPresentationAdmission _modelSelectorPresentation =
      NativeSheetPresentationAdmission();

  /// The account the native memory list on screen was built for. Actions taken
  /// in that list are sent for this account, so a list left open across an
  /// account switch cannot change the new account's memories.
  MemoryOwner? get memoryOwner => _memoryOwner;

  /// Records the native Settings root that was just presented, with the
  /// account it was built for, so [refreshProfileRoot] can rebuild it.
  void rememberProfileRoot(NativeProfileRootAccount? account) {
    _profileRoot = _NativeProfileRoot(
      account: account,
      api: _ref.read(apiServiceProvider),
      userId: _ref.read(currentUserProvider2)?.id,
    );
  }

  /// Rebuilds the rows of the open native Settings root, for when something
  /// it shows (Advanced, the language) changed while it was up. Nothing is
  /// sent once another account has taken over: the sheet on screen belongs to
  /// the one it was built for. Returns whether the sheet took the new rows.
  Future<bool> refreshProfileRoot() async {
    final root = _profileRoot;
    if (root == null) return false;
    if (!identical(_ref.read(apiServiceProvider), root.api) ||
        _ref.read(currentUserProvider2)?.id != root.userId) {
      _profileRoot = null;
      return false;
    }
    final ctx = NavigationService.context;
    if (ctx == null || !ctx.mounted) return false;
    final l10n = AppLocalizations.of(ctx);
    if (l10n == null) return false;
    final applied = await NativeSheetBridge.instance.applyDetailPatch(
      detailId: NativeSheetRoutes.profileMenu,
      title: nativeSettingsTitle(l10n),
      items: const [],
      sections: buildNativeProfileRootSections(
        l10n,
        account: root.account,
        visibility: readNativeProfileRootVisibility(_ref.read),
        otherAccounts: otherSavedAccountsForNativeSheet(
          _ref.read(openWebUiAccountsProvider).value,
          l10n,
        ),
      ),
    );
    // The sheet is gone (or never took a root patch); stop rebuilding it.
    if (!applied && identical(_profileRoot, root)) _profileRoot = null;
    return applied;
  }

  Future<List<Model>> loadModels({bool refreshOnError = true}) async {
    final modelsAsync = _ref.read(modelsProvider);
    if (modelsAsync.hasValue) {
      return modelsAsync.requireValue;
    }
    if (modelsAsync.hasError && refreshOnError) {
      await _ref.read(modelsProvider.notifier).refresh();
    }
    return _ref.read(modelsProvider.future);
  }

  Future<String?> presentModelSelector(
    BuildContext context, {
    required String title,
    required List<Model> models,
    String? selectedModelId,
    List<NativeSheetModelOption> leadingOptions =
        const <NativeSheetModelOption>[],
    bool allowsPinning = false,
    bool rethrowErrors = true,
  }) async {
    // Native permits only one selector at a time. Reject overlap before a
    // second call can advance the hydration generation and silence progressive
    // avatar updates for the selector that is already visible.
    if (!_modelSelectorPresentation.tryBegin()) return null;
    int? hydrationGeneration;
    ProviderSubscription<AsyncValue<ServerModelReasoningEffort>>?
    effortSubscription;
    try {
      final api = _ref.read(apiServiceProvider);
      final container = ProviderScope.containerOf(context, listen: false);
      final l10n = AppLocalizations.of(context);
      final pinnedModelIds = allowsPinning
          ? _ref.read(effectivePinnedModelIdsProvider)
          : const <String>[];
      final orderedModels = allowsPinning
          ? sortModelsWithPinnedOrder(models, pinnedModelIds)
          : List<Model>.of(models, growable: false);
      final canTogglePinnedModels =
          allowsPinning && _ref.read(canTogglePinnedModelsProvider);
      final hasOpenWebUiAccount = _ref.read(openWebUiAccountAvailableProvider);
      final localDefaultModelId = _ref.read(appSettingsProvider).defaultModel;
      final defaultModelId = hasOpenWebUiAccount
          ? _ref
                    .read(personalizationSettingsProvider)
                    .asData
                    ?.value
                    .defaultModelId ??
                localDefaultModelId
          : localDefaultModelId;
      final layout = buildModelSelectorLayout(
        models: orderedModels,
        pinnedModelIds: pinnedModelIds,
        defaultModelId: defaultModelId,
      );
      final effortModel = orderedModels
          .where((model) => model.id == selectedModelId)
          .firstOrNull;
      // Present without waiting on the reasoning-effort probe. The sheet
      // already hydrates that row progressively, and blocking here made every
      // open feel unresponsive on a cold cache (#692).
      Future<ServerModelReasoningEffort>? effortHydration;
      var effortHydrated = effortModel == null;
      if (effortModel != null) {
        // Native has no Flutter watcher. Keep the completed probe available
        // while the sheet is open so a pick passes the setter's policy check.
        effortSubscription = _ref.listen(
          serverModelReasoningEffortProvider(effortModel),
          (_, _) {},
        );
        final effortAsync = _ref.read(
          serverModelReasoningEffortProvider(effortModel),
        );
        effortHydrated = effortAsync.hasValue;
        if (!effortHydrated) {
          effortHydration = _ref.read(
            serverModelReasoningEffortProvider(effortModel).future,
          );
        }
      }
      final effortPolicy = nativeModelSelectorReasoningEffortPolicy(
        effortHydrated,
        reasoningEffortPolicyForModel(_ref.read, effortModel),
      );
      final allowsCustomEffort = effortPolicy.allowsCustom;
      final effortOptions = effortPolicy.options;

      Uint8List? hermesAvatarBytes;
      if (orderedModels.any(isHermesModel)) {
        try {
          final data = await rootBundle.load(kHermesModelAvatarAsset);
          hermesAvatarBytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } catch (_) {
          DebugLogger.warning(
            'hermes-model-avatar-load-failed',
            scope: 'native-sheet/models',
          );
        }
        if (!context.mounted) return null;
      }

      // The native sheet can't draw SVG, so bundled model logos go over as
      // PNG bytes, rendered once per logo in the current theme's ink.
      // Rendered in parallel and cached across openings, so only the first
      // opening with a new logo waits for it.
      final logoInk = context.conduitTheme.textPrimary;
      final logoIds = {
        for (final model in orderedModels)
          ?modelLogoIdFromUrl(resolveModelIconUrlForModel(api, model)),
      };
      final rendered = await Future.wait(
        logoIds.map((id) => rasterizeModelLogo(id, color: logoInk)),
      );
      final logoBytes = Map.fromIterables(logoIds, rendered);
      if (!context.mounted) return null;

      final modelOptions = [
        ...leadingOptions,
        ...orderedModels.map((model) {
          if (isHermesModel(model)) {
            return NativeSheetModelOption(
              id: model.id,
              name: model.name,
              subtitle: model.description,
              avatarBytes: hermesAvatarBytes,
              tags: model.modelTags,
            );
          }
          final avatarUrl = resolveModelIconUrlForModel(api, model);
          // A system symbol is UIKit's to draw, so hand the native sheet the
          // symbol name instead of an image reference it cannot fetch.
          final symbolName = nativeSymbolNameFromUrl(avatarUrl);
          if (symbolName != null) {
            return NativeSheetModelOption(
              id: model.id,
              name: model.name,
              subtitle: model.description,
              sfSymbol: symbolName,
              tags: model.modelTags,
            );
          }
          final logoId = modelLogoIdFromUrl(avatarUrl);
          if (logoId != null) {
            return NativeSheetModelOption(
              id: model.id,
              name: model.name,
              subtitle: model.description,
              avatarBytes: logoBytes[logoId],
              tags: model.modelTags,
            );
          }
          final avatarHeaders = avatarUrl == null
              ? const <String, String>{}
              : buildImageHeadersForUrlFromContainer(container, avatarUrl) ??
                    const <String, String>{};
          return NativeSheetModelOption(
            id: model.id,
            name: model.name,
            subtitle: model.description,
            avatarUrl: avatarUrl,
            avatarHeaders: avatarHeaders,
            tags: model.modelTags,
          );
        }),
      ];

      // Present immediately. Same-server custom-TLS URLs are withheld from
      // native URLSession because it cannot inherit Dart's TLS identity/trust;
      // those rows use initials until Dart progressively supplies bytes.
      final bridge = NativeSheetBridge.instance;
      final avatarHydrator = _ref.read(nativeSheetAvatarBytesHydratorProvider);
      final nativePresentationOptions = avatarHydrator
          .prepareForNativePresentation(api: api, options: modelOptions);
      final activeHydrationGeneration = _modelSelectorHydration.begin();
      hydrationGeneration = activeHydrationGeneration;
      final presentationId = const Uuid().v4();
      // The chat and account a pick made in this sheet is for, fixed as the
      // sheet opens: the native sheet outlives a chat or account switch.
      final reasoningPickTarget = captureOpenWebUiReasoningPickTarget(_ref);
      final result = bridge.presentModelSelector(
        presentationId: presentationId,
        title: title,
        selectedModelId: selectedModelId,
        pinnedModelIds: pinnedModelIds,
        featuredModelIds: <String>[
          ...leadingOptions.map((option) => option.id),
          ...layout.featured.map((model) => model.id),
        ],
        pinTitle: allowsPinning ? l10n?.pin : null,
        unpinTitle: allowsPinning ? l10n?.unpin : null,
        moreModelsTitle: l10n?.moreModels ?? 'More models',
        searchModelsTitle: l10n?.searchModels ?? 'Search models',
        reasoningEffortTitle: l10n?.reasoningEffort ?? 'Effort',
        reasoningEffortValue: effortModel == null || !effortHydrated
            ? kAutomaticReasoningEffort
            : reasoningEffortForModel(_ref.read, effortModel),
        reasoningEffortOptions: effortOptions,
        reasoningEffortLabels: <String, String>{
          kAutomaticReasoningEffort:
              l10n?.ollamaThinkingAutomatic ?? 'Automatic',
          'low': l10n?.reasoningEffortLow ?? 'Low',
          'medium': l10n?.reasoningEffortMedium ?? 'Medium',
          'high': l10n?.reasoningEffortHigh ?? 'High',
          'light': l10n?.reasoningEffortLight ?? 'Light',
          'moderate': l10n?.reasoningEffortModerate ?? 'Moderate',
          'deep': l10n?.reasoningEffortDeep ?? 'Deep',
          'minimal': l10n?.reasoningEffortMinimal ?? 'Minimal',
          'xhigh': l10n?.reasoningEffortExtraHigh ?? 'Extra high',
          'max': l10n?.reasoningEffortMaximum ?? 'Maximum',
          'none': l10n?.reasoningEffortNone ?? 'None',
        },
        allowsCustomReasoningEffort: allowsCustomEffort,
        customReasoningEffortTitle:
            l10n?.customReasoningEffort ?? 'Custom effort',
        customReasoningEffortHint:
            l10n?.customReasoningEffortHint ?? 'Enter effort',
        onTogglePinned: canTogglePinnedModels
            ? (modelId) => _ref
                  .read(personalizationSettingsProvider.notifier)
                  .togglePinnedModel(modelId)
            : null,
        onReasoningEffortChanged: effortModel == null || !effortPolicy.visible
            ? null
            : (value) => selectReasoningEffortForModel(
                _ref,
                effortModel,
                value,
                target: reasoningPickTarget,
              ),
        models: nativePresentationOptions,
        rethrowErrors: rethrowErrors,
      );
      final lateEffortModel = effortHydrated ? null : effortModel;
      final lateEffortHydration = effortHydrated ? null : effortHydration;
      if (lateEffortModel != null && lateEffortHydration != null) {
        unawaited(
          lateEffortHydration
              .then((detail) async {
                if (!detail.canUsePersonalizationFallback ||
                    !context.mounted ||
                    !_modelSelectorHydration.isActive(
                      activeHydrationGeneration,
                    ) ||
                    !identical(_ref.read(apiServiceProvider), api)) {
                  return;
                }
                final hydrated = nativeHydratedServerReasoningEffort(
                  model: lateEffortModel,
                  detail: detail,
                  personalizationEffort: _ref
                      .read(personalizationSettingsProvider)
                      .asData
                      ?.value
                      .reasoningEffort,
                  localEffort: localReasoningEffortForModel(
                    _ref.read,
                    lateEffortModel,
                  ),
                );
                await bridge.updateModelSelectorReasoningEffort(
                  presentationId: presentationId,
                  value: hydrated.value,
                  options: hydrated.policy.options,
                  allowsCustom: hydrated.policy.allowsCustom,
                  onReasoningEffortChanged: hydrated.policy.visible
                      ? (value) => selectReasoningEffortForModel(
                          _ref,
                          lateEffortModel,
                          value,
                          target: reasoningPickTarget,
                        )
                      : null,
                );
              })
              .catchError((Object error, StackTrace stackTrace) {
                DebugLogger.error(
                  'native-model-effort-progressive-hydration-failed',
                  scope: 'native-sheet/model-effort-hydration',
                  error: error,
                  stackTrace: stackTrace,
                );
              }),
        );
      }
      unawaited(
        avatarHydrator
            .hydrateModelOptions(
              api: api,
              options: modelOptions,
              maxWait: const Duration(seconds: 5),
              onProgress: (models) {
                if (_modelSelectorHydration.isActive(
                  activeHydrationGeneration,
                )) {
                  unawaited(
                    bridge.updateModelSelectorModels(
                      avatarHydrator.prepareForNativePresentation(
                        api: api,
                        options: models,
                      ),
                      presentationId: presentationId,
                    ),
                  );
                }
              },
              isActive: () =>
                  context.mounted &&
                  _modelSelectorHydration.isActive(activeHydrationGeneration) &&
                  identical(_ref.read(apiServiceProvider), api),
            )
            .catchError((Object error, StackTrace stackTrace) {
              DebugLogger.error(
                'native-model-avatar-progressive-hydration-failed',
                scope: 'native-sheet/model-avatar-hydration',
                error: error,
                stackTrace: stackTrace,
              );
              return nativePresentationOptions;
            }),
      );
      return await result;
    } finally {
      if (hydrationGeneration != null) {
        _modelSelectorHydration.finish(hydrationGeneration);
      }
      effortSubscription?.close();
      _modelSelectorPresentation.finish();
    }
  }

  /// The rows read their strings from the app's localizations, which switch on
  /// the frame that follows the locale change, so wait for that frame first.
  Future<void> _rehydrateAppearanceAfterLocaleChange() async {
    try {
      await WidgetsBinding.instance.endOfFrame;
      await hydrateDetail(NativeSheetRoutes.appearance);
      await refreshProfileRoot();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-sheet-locale-rehydrate-failed',
        scope: 'native-sheet/hydration',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> hydrateDetail(String detailId) async {
    final ctx = NavigationService.context;
    if (ctx == null || !ctx.mounted) return;
    final l10n = AppLocalizations.of(ctx);
    if (l10n == null) return;

    if (detailId.startsWith('model-prompt:')) {
      await _hydrateNativeModelPromptDetail(ctx, detailId, l10n);
      return;
    }

    switch (detailId) {
      case NativeSheetRoutes.accountSettings:
        await _hydrateNativeAccountSettingsDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.appearance:
      case NativeSheetRoutes.chats:
      case NativeSheetRoutes.dataConnection:
        if (detailId == NativeSheetRoutes.appearance) {
          _appearanceDetailPresented = true;
        }
        await _hydrateNativeSignalStyleSettingsDetails(ctx, l10n);
        return;
      case NativeSheetRoutes.aiMemory:
        await _hydrateNativeAiMemoryDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.voice:
        await _hydrateNativeVoiceDetail(l10n);
        return;
      case NativeSheetRoutes.helpAbout:
        await _hydrateNativeAboutDetail(
          ctx,
          l10n,
          detailId: NativeSheetRoutes.helpAbout,
        );
        return;
      case NativeSheetRoutes.about:
        await _hydrateNativeAboutDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.personalization:
        await _hydrateNativePersonalizationDetail(ctx, l10n);
        return;
      case NativeSheetRoutes.notificationSettings:
        await _hydrateNativeNotificationsDetail(l10n);
        return;
      case 'advanced-prompt-overrides':
        await _hydrateNativeAdvancedPromptDetail(ctx, l10n);
        return;
      case 'default-model':
        await _hydrateNativeDefaultModelDetail(ctx, l10n);
        return;
      case 'default-image-generation-model':
        await _hydrateNativeOpenRouterImageGenerationModelDetail(ctx, l10n);
        return;
      case 'memory-manage':
        await _hydrateNativeMemoryManageDetail(ctx, l10n);
        return;
      case 'quick-pills':
        await _hydrateNativeQuickPillsDetail(ctx, l10n);
        return;
      case 'system-prompt':
        await _hydrateNativeSystemPromptDetail(ctx, l10n);
        return;
      case 'personalization-memory':
        await _hydrateNativeMemoryDetail(ctx, l10n);
        return;
    }
  }

  Future<void> _hydrateNativeAboutDetail(
    BuildContext context,
    AppLocalizations l10n, {
    String detailId = NativeSheetRoutes.about,
  }) async {
    try {
      // Hermes-only has no Open WebUI server, so skip the server lookup and omit
      // the server name/version rows entirely.
      final hermesOnly = _ref.read(hermesOnlyModeProvider);
      final packageInfo = await _ref.read(packageInfoProvider.future);
      final about = hermesOnly
          ? null
          : await _ref.read(serverAboutInfoProvider.future);
      if (!context.mounted) return;

      final appVersionLabel = packageInfo.buildNumber.isEmpty
          ? packageInfo.version
          : '${packageInfo.version} (${packageInfo.buildNumber})';
      final serverName = about?.name ?? l10n.serverInfoUnavailable;
      final serverVersion = about == null
          ? l10n.serverInfoUnavailable
          : about.latestVersion != null &&
                about.latestVersion!.trim().isNotEmpty &&
                about.latestVersion!.trim() != about.version.trim()
          ? '${about.version} · ${l10n.latestVersionLabel}: ${about.latestVersion}'
          : about.version;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: detailId,
          title: l10n.aboutApp,
          items: buildNativeAboutItems(
            l10n,
            appVersion: appVersionLabel,
            serverName: hermesOnly ? null : serverName,
            serverVersion: hermesOnly ? null : serverVersion,
          ),
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-about-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        detailId,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeAccountSettingsDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final about = await _ref.read(serverAboutInfoProvider.future);
      if (!context.mounted) return;
      final passwordChangeEnabled = about?.enablePasswordChangeForm ?? true;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.accountSettings,
          title: l10n.accountSettingsTitle,
          items: [
            if (passwordChangeEnabled)
              NativeSheetItemConfig(
                id: 'password',
                title: l10n.changePasswordTitle,
                subtitle: l10n.passwordChangeDescription,
                sfSymbol: 'lock',
              )
            else
              NativeSheetItemConfig(
                id: 'password-unavailable',
                title: l10n.changePasswordTitle,
                subtitle: l10n.passwordChangeUnavailable,
                sfSymbol: 'lock.slash',
                kind: NativeSheetItemKind.info,
              ),
          ],
        ),
        detailSheets: passwordChangeEnabled
            ? [
                buildNativePasswordDetail(
                  l10n,
                  passwordChangeEnabled: true,
                  subtitle: l10n.passwordFieldsRequired,
                ),
              ]
            : const [],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-account-settings-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.accountSettings,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativePersonalizationDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = _ref.read(personalizationSettingsProvider.future);
      final modelsFuture = _ref.read(modelsProvider.future);
      final settings = await settingsFuture;
      final models = await modelsFuture;
      final memoriesPermitted = await _ref.read(
        memoriesPermittedProvider.future,
      );
      if (!context.mounted) return;

      final hasOpenWebUiAccount = _ref.read(openWebUiAccountAvailableProvider);
      final appSettings = _ref.read(appSettingsProvider);
      final openRouterImageGenerationModelItem =
          buildNativeOpenRouterImageGenerationModelItem(
            l10n,
            models: models,
            selectedModelId: appSettings.openRouterImageGenerationModel,
          );
      final defaultModelSubtitle =
          resolveNativeSheetModelName(models, appSettings.defaultModel) ??
          l10n.autoSelectDescription;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.personalization,
          title: l10n.personalization,
          items: [
            NativeSheetItemConfig(
              id: 'default-model',
              title: l10n.defaultModel,
              subtitle: defaultModelSubtitle,
              sfSymbol: 'wand.and.stars',
            ),
            ?openRouterImageGenerationModelItem,
            NativeSheetItemConfig(
              id: 'system-prompt',
              title: l10n.yourSystemPrompt,
              subtitle: nativeSheetPreviewText(l10n, settings.systemPrompt),
              sfSymbol: 'person.crop.circle.badge.checkmark',
            ),
            if (memoriesPermitted)
              NativeSheetItemConfig(
                id: 'personalization-memory',
                title: l10n.memoryTitle,
                subtitle: settings.memoryEnabled
                    ? l10n.memoryEnabledDescription
                    : l10n.memoryDisabledDescription,
                sfSymbol: 'bookmark',
              ),
            if (hasOpenWebUiAccount)
              NativeSheetItemConfig(
                id: 'advanced-prompt-overrides',
                title: l10n.promptOverridesTitle,
                subtitle: models.isEmpty
                    ? l10n.noAccessibleModelsFound
                    : l10n.accessibleModelsCount(models.length),
                sfSymbol: 'cube.box',
              ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'default-model',
            title: l10n.defaultModel,
            subtitle: l10n.autoSelectDescription,
          ),
          if (openRouterImageGenerationModelItem != null)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'default-image-generation-model',
              title: l10n.defaultImageGenerationModel,
              subtitle: l10n.defaultImageGenerationModelDescription,
            ),
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'system-prompt',
            title: l10n.yourSystemPrompt,
            subtitle: l10n.yourSystemPromptDescription,
          ),
          if (memoriesPermitted)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'personalization-memory',
              title: l10n.memoryTitle,
              subtitle: settings.memoryEnabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
            ),
          if (hasOpenWebUiAccount)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'advanced-prompt-overrides',
              title: l10n.promptOverridesTitle,
              subtitle: l10n.advancedPromptOverridesDescription,
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-personalization-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.personalization,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeAiMemoryDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = _ref.read(personalizationSettingsProvider.future);
      final settings = await settingsFuture;
      final memoriesPermitted = await _ref.read(
        memoriesPermittedProvider.future,
      );
      if (!context.mounted) return;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.aiMemory,
          title: nativeAiMemoryTitle(l10n),
          sections: [
            NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: 'system-prompt',
                  title: l10n.yourSystemPrompt,
                  subtitle: nativeSheetPreviewText(l10n, settings.systemPrompt),
                  sfSymbol: 'text.bubble',
                ),
                if (memoriesPermitted)
                  NativeSheetItemConfig(
                    id: 'personalization-memory',
                    title: l10n.memoryTitle,
                    subtitle: settings.memoryEnabled
                        ? l10n.enabled
                        : l10n.disabled,
                    sfSymbol: 'bookmark',
                  ),
              ],
            ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'system-prompt',
            title: l10n.yourSystemPrompt,
            subtitle: l10n.yourSystemPromptDescription,
          ),
          if (memoriesPermitted)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'personalization-memory',
              title: l10n.memoryTitle,
              subtitle: settings.memoryEnabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-ai-memory-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.aiMemory,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  /// Whether the Webhook destinations row belongs in the native Notifications
  /// sheet: Advanced is on and the account may use them. The row is the only
  /// thing waiting on the permission lookup, which is bounded so the local
  /// toggles are never held up by a slow server.
  Future<bool> _showNativeNotificationTargets() async {
    if (!_ref.read(appSettingsProvider).advancedFeaturesEnabled) return false;
    try {
      await Future.wait<Object?>([
        _ref.read(userPermissionsProvider.future),
        _ref.read(backendConfigProvider.future),
      ]).timeout(const Duration(seconds: 2));
    } catch (_) {
      // An unread permission leaves the row out; the toggles still show.
    }
    return _ref.read(notificationTargetsAvailableProvider);
  }

  /// How many webhook destinations the account has, or null when the list
  /// could not be read in time; the row then shows no count.
  Future<int?> _nativeNotificationTargetsCount() async {
    try {
      final data = await _ref
          .read(notificationTargetsProvider.future)
          .timeout(const Duration(seconds: 2));
      return data.targets.length;
    } catch (_) {
      return null;
    }
  }

  /// The toggle groups of the native Notifications sheet. They read only
  /// local settings.
  List<NativeSheetSectionConfig> _nativeNotificationToggleSections(
    AppLocalizations l10n,
  ) {
    final s = _ref.read(appSettingsProvider);
    final masterItem = NativeSheetItemConfig(
      id: 'notifications-enabled',
      title: l10n.notificationsEnabledTitle,
      subtitle: s.notificationsEnabled
          ? l10n.notificationsEnabledDescription
          : l10n.notificationRequiresMaster,
      sfSymbol: 'bell',
      kind: NativeSheetItemKind.toggle,
      value: s.notificationsEnabled,
    );
    final deliveryItems = <NativeSheetItemConfig>[
      NativeSheetItemConfig(
        id: 'notification-in-app-banner',
        title: l10n.notificationInAppBannerTitle,
        subtitle: l10n.notificationInAppBannerDescription,
        sfSymbol: 'rectangle.topthird.inset.filled',
        kind: s.notificationsEnabled
            ? NativeSheetItemKind.toggle
            : NativeSheetItemKind.info,
        value: s.notificationInAppBanner,
      ),
      NativeSheetItemConfig(
        id: 'notification-system',
        title: l10n.notificationSystemTitle,
        subtitle: l10n.notificationSystemDescription,
        sfSymbol: 'bell.badge',
        kind: s.notificationsEnabled
            ? NativeSheetItemKind.toggle
            : NativeSheetItemKind.info,
        value: s.notificationSystem,
      ),
    ];
    final soundItems = <NativeSheetItemConfig>[
      NativeSheetItemConfig(
        id: 'notification-sound',
        title: l10n.notificationSoundTitle,
        subtitle: l10n.notificationSoundDescription,
        sfSymbol: 'speaker.wave.2',
        kind: s.notificationsEnabled
            ? NativeSheetItemKind.toggle
            : NativeSheetItemKind.info,
        value: s.notificationSound,
      ),
      NativeSheetItemConfig(
        id: 'notification-sound-always',
        title: l10n.notificationSoundAlwaysTitle,
        subtitle: s.notificationsEnabled && !s.notificationSound
            ? l10n.notificationRequiresSound
            : l10n.notificationSoundAlwaysDescription,
        sfSymbol: 'speaker.wave.3',
        kind: s.notificationsEnabled && s.notificationSound
            ? NativeSheetItemKind.toggle
            : NativeSheetItemKind.info,
        value: s.notificationSoundAlways,
      ),
    ];
    final contentItems = <NativeSheetItemConfig>[
      NativeSheetItemConfig(
        id: 'notification-chat',
        title: l10n.notificationChatTitle,
        subtitle: l10n.notificationChatDescription,
        sfSymbol: 'bubble.left.and.bubble.right',
        kind: s.notificationsEnabled
            ? NativeSheetItemKind.toggle
            : NativeSheetItemKind.info,
        value: s.notificationChatEnabled,
      ),
      NativeSheetItemConfig(
        id: 'notification-channel',
        title: l10n.notificationChannelTitle,
        subtitle: l10n.notificationChannelDescription,
        sfSymbol: 'number',
        kind: s.notificationsEnabled
            ? NativeSheetItemKind.toggle
            : NativeSheetItemKind.info,
        value: s.notificationChannelEnabled,
      ),
    ];
    return [
      NativeSheetSectionConfig(items: [masterItem]),
      NativeSheetSectionConfig(items: deliveryItems),
      NativeSheetSectionConfig(items: soundItems),
      NativeSheetSectionConfig(items: contentItems),
    ];
  }

  /// Shows the local toggles at once, then adds the Webhook destinations group
  /// once the bounded permission and list reads settle.
  Future<void> _hydrateNativeNotificationsDetail(AppLocalizations l10n) async {
    final generation = _notificationsHydration.begin();
    try {
      final api = _ref.read(apiServiceProvider);
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.notificationSettings,
          title: l10n.notificationsTitle,
          sections: _nativeNotificationToggleSections(l10n),
        ),
      );
      if (!await _showNativeNotificationTargets()) return;
      final count = await _nativeNotificationTargetsCount();
      // A newer opening of this page, or another account, owns it now.
      if (!_notificationsHydration.isActive(generation) ||
          !identical(_ref.read(apiServiceProvider), api) ||
          !_ref.read(notificationTargetsAvailableProvider)) {
        return;
      }
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.notificationSettings,
          title: l10n.notificationsTitle,
          sections: [
            // Rebuilt, so a toggle flipped while the count loaded shows as is.
            ..._nativeNotificationToggleSections(l10n),
            buildNativeNotificationTargetsSection(l10n, count: count),
          ],
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-notifications-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.notificationSettings,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeVoiceDetail(AppLocalizations l10n) async {
    final appSettings = _ref.read(appSettingsProvider);
    var ttsVoices = const <Map<String, dynamic>>[];
    try {
      final ttsService = _ref.read(textToSpeechServiceProvider);
      await ttsService.updateSettings(engine: appSettings.ttsEngine);
      ttsVoices = await ttsService.getAvailableVoices();
    } catch (error, stackTrace) {
      DebugLogger.warning(
        'native-tts-voices-load-failed',
        scope: 'native-sheet',
        data: {'error': error, 'stackTrace': stackTrace},
      );
    }
    final nativeAudio = buildNativeAudioSheetParts(
      l10n,
      appSettings,
      ttsVoices: ttsVoices,
    );
    await _applyNativeDetail(
      NativeSheetDetailConfig(
        id: NativeSheetRoutes.voice,
        title: l10n.voice,
        sections: nativeAudio.mainSections,
      ),
      detailSheets: [nativeAudio.voicePickerDetail],
    );
  }

  Future<void> _applyNativeAppearanceDetail(AppLocalizations l10n) async {
    try {
      final themeMode = _ref.read(appThemeModeProvider);
      final appLocale = _ref.read(appLocaleProvider);
      final activePalette = _ref.read(appThemePaletteProvider);
      final currentLanguageTag = appLocale?.toLanguageTag() ?? 'system';
      final themeItems = <NativeSheetItemConfig>[
        NativeSheetItemConfig(
          id: 'theme-light',
          title: l10n.colorScheme,
          sfSymbol: 'moon.stars',
          kind: NativeSheetItemKind.segment,
          value: themeMode.name,
          options: [
            NativeSheetOptionConfig(id: 'system', label: l10n.system),
            NativeSheetOptionConfig(id: 'light', label: l10n.themeLight),
            NativeSheetOptionConfig(id: 'dark', label: l10n.themeDark),
          ],
        ),
        NativeSheetItemConfig(
          id: 'theme-palette',
          title: l10n.themePalette,
          sfSymbol: 'paintpalette',
          kind: NativeSheetItemKind.searchablePicker,
          value: activePalette.id,
          options: [
            for (final theme in TweakcnThemes.all)
              NativeSheetOptionConfig(id: theme.id, label: theme.label(l10n)),
          ],
        ),
      ];
      final languageItem = NativeSheetItemConfig(
        id: 'language',
        title: l10n.appLanguage,
        sfSymbol: 'globe',
        kind: NativeSheetItemKind.searchablePicker,
        value: currentLanguageTag,
        options: nativeLanguageDropdownOptions(l10n),
      );
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.appearance,
          title: nativeAppearanceTitle(l10n),
          sections: [
            NativeSheetSectionConfig(items: themeItems),
            NativeSheetSectionConfig(items: [languageItem]),
          ],
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-appearance-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.appearance,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeSignalStyleSettingsDetails(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    // Appearance reads only local settings, so it is applied before anything
    // that waits on the server, and a failed models or tools request cannot
    // replace it (and the language picker) with an error row.
    await _applyNativeAppearanceDetail(l10n);
    try {
      final hasOpenWebUiAccount = _ref.read(openWebUiAccountAvailableProvider);
      final modelsFuture = _ref.read(modelsProvider.future);
      final models = await modelsFuture;
      final tools = hasOpenWebUiAccount
          ? await _ref.read(toolsListProvider.future)
          : const <Tool>[];
      if (!context.mounted) return;

      final appSettings = _ref.read(appSettingsProvider);
      final openRouterImageGenerationModelItem =
          buildNativeOpenRouterImageGenerationModelItem(
            l10n,
            models: models,
            selectedModelId: appSettings.openRouterImageGenerationModel,
          );
      final transportAvail = _ref.read(socketTransportOptionsProvider);
      final selectedModel = _ref.read(selectedModelProvider);
      final socketService = _ref.read(socketServiceProvider);

      var effectiveTransport = appSettings.socketTransportMode;
      if (!transportAvail.allowPolling && effectiveTransport == 'polling') {
        effectiveTransport = 'ws';
      } else if (!transportAvail.allowWebsocketOnly &&
          effectiveTransport == 'ws') {
        effectiveTransport = 'polling';
      }
      final transportLabel = effectiveTransport == 'polling'
          ? l10n.transportModePolling
          : l10n.transportModeWs;
      final filters = selectedModel?.filters ?? const [];
      final allowedQuickIds = <String>{
        'web',
        'image',
        ...tools.map((tool) => tool.id),
        ...filters.map((filter) => 'filter:${filter.id}'),
      };
      final selectedQuickPills = appSettings.quickPills
          .where((id) => allowedQuickIds.contains(id))
          .toList();
      final quickActionsTitle = nativeQuickActionsTitle(l10n);
      final quickPillsSubtitle = l10n.quickActionsSelectedCount(
        selectedQuickPills.length,
      );
      final defaultModelSubtitle =
          resolveNativeSheetModelName(models, appSettings.defaultModel) ??
          l10n.autoSelect;
      final modelItems = <NativeSheetItemConfig>[
        NativeSheetItemConfig(
          id: 'default-model',
          title: l10n.defaultModel,
          subtitle: defaultModelSubtitle,
          sfSymbol: 'wand.and.stars',
        ),
        ?openRouterImageGenerationModelItem,
        if (hasOpenWebUiAccount)
          NativeSheetItemConfig(
            id: 'quick-pills',
            title: quickActionsTitle,
            subtitle: quickPillsSubtitle,
            sfSymbol: 'bolt',
          ),
      ];
      final behaviorItems = _nativeChatBehaviorItems(l10n, appSettings);
      final promptOverridesItem = hasOpenWebUiAccount
          ? NativeSheetItemConfig(
              id: 'advanced-prompt-overrides',
              title: l10n.promptOverridesTitle,
              subtitle: l10n.advancedPromptOverridesDescription,
              sfSymbol: 'cube.box',
            )
          : null;
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.chats,
          title: nativeChatsTitle(l10n),
          sections: [
            NativeSheetSectionConfig(items: modelItems),
            NativeSheetSectionConfig(items: behaviorItems),
            if (promptOverridesItem != null)
              NativeSheetSectionConfig(items: [promptOverridesItem]),
            // Advanced stays last and on its own, as on the Flutter page: it
            // changes what the rest of the app shows, not how chats behave.
            _nativeChatAdvancedSection(l10n, appSettings),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'default-model',
            title: l10n.defaultModel,
            subtitle: l10n.autoSelectDescription,
          ),
          if (openRouterImageGenerationModelItem != null)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'default-image-generation-model',
              title: l10n.defaultImageGenerationModel,
              subtitle: l10n.defaultImageGenerationModelDescription,
            ),
          if (hasOpenWebUiAccount)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'quick-pills',
              title: quickActionsTitle,
              subtitle: quickPillsSubtitle,
            ),
          if (hasOpenWebUiAccount)
            buildNativeLoadingDetail(
              l10n: l10n,
              id: 'advanced-prompt-overrides',
              title: l10n.promptOverridesTitle,
              subtitle: l10n.advancedPromptOverridesDescription,
            ),
        ],
      );

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.dataConnection,
          title: nativeDataConnectionTitle(l10n),
          items: [
            if (transportAvail.allowPolling &&
                transportAvail.allowWebsocketOnly)
              NativeSheetItemConfig(
                id: 'transport-mode',
                title: l10n.transportMode,
                subtitle: transportLabel,
                sfSymbol: 'network',
                kind: NativeSheetItemKind.segment,
                value: effectiveTransport == 'ws' ? 'ws' : 'polling',
                options: [
                  NativeSheetOptionConfig(
                    id: 'polling',
                    label: l10n.transportModePolling,
                  ),
                  NativeSheetOptionConfig(
                    id: 'ws',
                    label: l10n.transportModeWs,
                  ),
                ],
              )
            else
              NativeSheetItemConfig(
                id: 'transport-fixed',
                title: l10n.transportMode,
                subtitle: transportLabel,
                sfSymbol: 'network',
                kind: NativeSheetItemKind.info,
              ),
            NativeSheetItemConfig(
              id: 'disable-haptics-streaming',
              title: l10n.disableHapticsWhileStreaming,
              subtitle: l10n.disableHapticsWhileStreamingDescription,
              sfSymbol: 'waveform.path',
              kind: NativeSheetItemKind.toggle,
              value: appSettings.disableHapticsWhileStreaming,
            ),
            if (socketService != null)
              NativeSheetItemConfig(
                id: 'socket-health',
                title: l10n.connectionHealth,
                subtitle: nativeSocketHealthSummary(
                  l10n,
                  socketService.currentHealth,
                ),
                sfSymbol: 'waveform.path.ecg',
              ),
          ],
        ),
        detailSheets: [
          if (socketService != null)
            NativeSheetDetailConfig(
              id: 'socket-health',
              title: l10n.connectionHealth,
              subtitle: nativeSocketHealthSummary(
                l10n,
                socketService.currentHealth,
              ),
              items: nativeSocketHealthItems(l10n, socketService.currentHealth),
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-signal-style-settings-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      // The behavior rows read only local settings, so they stay next to the
      // error instead of being replaced by it.
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: NativeSheetRoutes.chats,
          title: nativeChatsTitle(l10n),
          sections: [
            NativeSheetSectionConfig(
              items: _nativeChatBehaviorItems(
                l10n,
                _ref.read(appSettingsProvider),
              ),
            ),
            NativeSheetSectionConfig(
              items: [
                NativeSheetItemConfig(
                  id: '${NativeSheetRoutes.chats}-error',
                  title: l10n.unableToLoadOpenWebuiSettings,
                  sfSymbol: 'exclamationmark.triangle',
                  kind: NativeSheetItemKind.info,
                ),
              ],
            ),
            _nativeChatAdvancedSection(l10n, _ref.read(appSettingsProvider)),
          ],
        ),
      );
      await _patchNativeDetailError(
        NativeSheetRoutes.dataConnection,
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  List<NativeSheetItemConfig> _nativeChatBehaviorItems(
    AppLocalizations l10n,
    AppSettings appSettings,
  ) {
    return [
      NativeSheetItemConfig(
        id: 'send-on-enter',
        title: l10n.sendOnEnter,
        subtitle: l10n.sendOnEnterDescription,
        sfSymbol: 'paperplane',
        kind: NativeSheetItemKind.toggle,
        value: appSettings.sendOnEnter,
      ),
      NativeSheetItemConfig(
        id: 'temporary-chat-default',
        title: l10n.temporaryChatByDefault,
        subtitle: l10n.temporaryChatByDefaultDescription,
        sfSymbol: 'clock.arrow.circlepath',
        kind: NativeSheetItemKind.toggle,
        value: appSettings.temporaryChatByDefault,
      ),
      NativeSheetItemConfig(
        id: nativeCitationShowTitlesId,
        title: l10n.citationShowTitles,
        subtitle: l10n.citationShowTitlesDescription,
        sfSymbol: 'link',
        kind: NativeSheetItemKind.toggle,
        value: appSettings.citationShowTitles,
      ),
    ];
  }

  /// The Advanced group of the native Chats page: the toggle alone, with a
  /// footer that says what it reveals.
  NativeSheetSectionConfig _nativeChatAdvancedSection(
    AppLocalizations l10n,
    AppSettings appSettings,
  ) {
    return NativeSheetSectionConfig(
      footer: l10n.advancedFeaturesFooter,
      items: [
        NativeSheetItemConfig(
          id: nativeAdvancedFeaturesId,
          title: l10n.advancedFeatures,
          subtitle: l10n.advancedFeaturesDescription,
          sfSymbol: 'gearshape.2',
          kind: NativeSheetItemKind.toggle,
          value: appSettings.advancedFeaturesEnabled,
        ),
      ],
    );
  }

  Future<void> _hydrateNativeDefaultModelDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final models = await _ref.read(modelsProvider.future);
      if (!context.mounted) return;
      final appSettings = _ref.read(appSettingsProvider);
      await _applyNativeDetail(
        buildNativeDefaultModelDetail(
          l10n,
          models: models,
          selectedModelId: appSettings.defaultModel,
        ),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-default-model-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError('default-model', l10n.failedToLoadModels);
    }
  }

  Future<void> _hydrateNativeOpenRouterImageGenerationModelDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    final value =
        _ref.read(appSettingsProvider).openRouterImageGenerationModel ?? '';
    if (!context.mounted) return;
    await _applyNativeDetail(
      buildNativeOpenRouterImageGenerationModelDetail(l10n, value: value),
    );
  }

  Future<void> _hydrateNativeAdvancedPromptDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final models = await _ref.read(modelsProvider.future);
      if (!context.mounted) return;
      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: 'advanced-prompt-overrides',
          title: l10n.promptOverridesTitle,
          subtitle: models.isEmpty
              ? l10n.noAccessibleModelsFound
              : l10n.accessibleModelsCount(models.length),
          items: models.isEmpty
              ? [
                  NativeSheetItemConfig(
                    id: 'advanced-prompt-empty',
                    title: l10n.noAccessibleModelsFound,
                    sfSymbol: 'exclamationmark.triangle',
                    kind: NativeSheetItemKind.info,
                  ),
                ]
              : [
                  for (final model in models)
                    NativeSheetItemConfig(
                      id: 'model-prompt:${Uri.encodeComponent(model.id)}',
                      title: model.name,
                      sfSymbol: 'cpu',
                    ),
                ],
        ),
        detailSheets: buildNativeModelPromptLoadingDetails(l10n, models),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-advanced-prompt-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'advanced-prompt-overrides',
        l10n.unableToLoadModels,
      );
    }
  }

  Future<void> _hydrateNativeSystemPromptDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settings = await _ref.read(personalizationSettingsProvider.future);
      if (!context.mounted) return;
      await _applyNativeDetail(
        buildNativeSystemPromptDetail(l10n, value: settings.systemPrompt ?? ''),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-system-prompt-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'system-prompt',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeMemoryDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final settingsFuture = _ref.read(personalizationSettingsProvider.future);
      final memoriesFuture = _ref.read(userMemoriesProvider.future);
      final settings = await settingsFuture;
      final memories = await memoriesFuture;
      if (!context.mounted) return;
      if (!await _ref.read(memoriesPermittedProvider.future)) {
        await _patchNativeDetailError(
          'personalization-memory',
          l10n.unableToLoadOpenWebuiSettings,
        );
        return;
      }

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: 'personalization-memory',
          title: l10n.memoryTitle,
          subtitle: settings.memoryEnabled
              ? l10n.memoryEnabledDescription
              : l10n.memoryDisabledDescription,
          items: [
            NativeSheetItemConfig(
              id: 'memory-enabled',
              title: l10n.memoryTitle,
              subtitle: settings.memoryEnabled
                  ? l10n.memoryEnabledDescription
                  : l10n.memoryDisabledDescription,
              sfSymbol: 'bookmark',
              kind: NativeSheetItemKind.toggle,
              value: settings.memoryEnabled,
            ),
            NativeSheetItemConfig(
              id: 'memory-manage',
              title: l10n.manageMemories,
              subtitle: l10n.savedMemoriesCount(memories.length),
              sfSymbol: 'rectangle.stack',
            ),
          ],
        ),
        detailSheets: [
          buildNativeLoadingDetail(
            l10n: l10n,
            id: 'memory-manage',
            title: l10n.manageMemories,
            subtitle: l10n.savedMemoriesCount(memories.length),
          ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-memory-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'personalization-memory',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeMemoryManageDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final notifier = _ref.read(userMemoriesProvider.notifier);
      // The list is built for the account that is signed in as it loads. If
      // another one has taken over by the time it arrives, the list is not
      // shown.
      final owner = notifier.captureOwner();
      final memories = await _ref.read(userMemoriesProvider.future);
      final permitted = await _ref.read(memoriesPermittedProvider.future);
      if (!context.mounted) return;
      if (owner == null || !notifier.isCurrentOwner(owner) || !permitted) {
        _memoryOwner = null;
        await _patchNativeDetailError(
          'memory-manage',
          l10n.unableToLoadOpenWebuiSettings,
        );
        return;
      }
      _memoryOwner = owner;
      final advanced = _ref.read(appSettingsProvider).advancedFeaturesEnabled;

      await _applyNativeDetail(
        NativeSheetDetailConfig(
          id: 'memory-manage',
          title: l10n.manageMemories,
          subtitle: l10n.savedMemoriesCount(memories.length),
          items: [
            buildNativeMemoryAddItem(l10n, advanced: advanced),
            if (memories.isEmpty)
              NativeSheetItemConfig(
                id: 'memory-empty-info',
                title: l10n.noMemoriesSaved,
                sfSymbol: 'note.text',
                kind: NativeSheetItemKind.info,
              )
            else ...[
              for (final memory in memories)
                NativeSheetItemConfig(
                  id: 'memory-edit:${Uri.encodeComponent(memory.id)}',
                  title: truncateNativeSheetMemory(memory.content),
                  subtitle: nativeSheetMemoryUpdatedSubtitle(l10n, memory),
                  sfSymbol: 'quote.bubble',
                ),
              NativeSheetItemConfig(
                id: 'memory-clear-all',
                title: l10n.clearAllMemories,
                subtitle: l10n.clearAllMemoriesDescription,
                sfSymbol: 'clear',
                destructive: true,
              ),
            ],
          ],
        ),
        detailSheets: [
          if (!advanced) buildNativeMemoryAddDetail(l10n),
          ...buildNativeMemoryEditDetails(l10n, memories, advanced: advanced),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-memory-manage-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'memory-manage',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeQuickPillsDetail(
    BuildContext context,
    AppLocalizations l10n,
  ) async {
    try {
      final tools = await _ref.read(toolsListProvider.future);
      if (!context.mounted) return;
      final quickActionsTitle = nativeQuickActionsTitle(l10n);
      final appSettings = _ref.read(appSettingsProvider);
      final selectedModel = _ref.read(selectedModelProvider);
      final filters = selectedModel?.filters ?? const [];
      final allowedIds = <String>{
        'web',
        'image',
        ...tools.map((tool) => tool.id),
        ...filters.map((filter) => 'filter:${filter.id}'),
      };
      final selected = appSettings.quickPills
          .where((id) => allowedIds.contains(id))
          .toSet();

      await NativeSheetBridge.instance.applyDetailPatch(
        detailId: 'quick-pills',
        clearSubtitle: true,
        items: [
          NativeSheetItemConfig(
            id: 'quick-pill:web',
            title: l10n.web,
            sfSymbol: 'magnifyingglass',
            kind: NativeSheetItemKind.toggle,
            value: selected.contains('web'),
          ),
          NativeSheetItemConfig(
            id: 'quick-pill:image',
            title: l10n.imageGen,
            sfSymbol: 'photo',
            kind: NativeSheetItemKind.toggle,
            value: selected.contains('image'),
          ),
          for (final tool in tools)
            NativeSheetItemConfig(
              id: 'quick-pill:${tool.id}',
              title: tool.name,
              sfSymbol: 'puzzlepiece.extension',
              kind: NativeSheetItemKind.toggle,
              value: selected.contains(tool.id),
            ),
          for (final filter in filters)
            NativeSheetItemConfig(
              id: 'quick-pill:filter:${filter.id}',
              title: filter.name,
              sfSymbol: 'sparkles',
              kind: NativeSheetItemKind.toggle,
              value: selected.contains('filter:${filter.id}'),
            ),
          if (selected.isNotEmpty)
            NativeSheetItemConfig(
              id: 'quick-pills-clear',
              title: l10n.clear,
              subtitle: quickActionsTitle,
              sfSymbol: 'xmark.circle',
              destructive: true,
            ),
        ],
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'native-quick-pills-hydration-failed',
        scope: 'native-sheet',
        error: error,
        stackTrace: stackTrace,
      );
      await _patchNativeDetailError(
        'quick-pills',
        l10n.unableToLoadOpenWebuiSettings,
      );
    }
  }

  Future<void> _hydrateNativeModelPromptDetail(
    BuildContext context,
    String detailId,
    AppLocalizations l10n,
  ) async {
    final encodedModel = detailId.substring('model-prompt:'.length);
    final modelId = Uri.decodeComponent(encodedModel);

    Future<void> patchFailure() async {
      await NativeSheetBridge.instance.applyDetailPatch(
        detailId: detailId,
        clearSubtitle: true,
        items: [
          NativeSheetItemConfig(
            id: 'model-prompt-error:$encodedModel',
            title: l10n.unableToLoadModels,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      );
    }

    final api = _ref.read(apiServiceProvider);
    if (api == null) {
      await patchFailure();
      return;
    }

    final detail = await api.getModelDetails(modelId);
    if (!context.mounted) return;
    if (detail == null) {
      await NativeSheetBridge.instance.applyDetailPatch(
        detailId: detailId,
        clearSubtitle: true,
        items: [
          NativeSheetItemConfig(
            id: 'model-prompt-error:$encodedModel',
            title: l10n.modelNoEditableServerRecord,
            sfSymbol: 'exclamationmark.triangle',
            kind: NativeSheetItemKind.info,
          ),
        ],
      );
      return;
    }

    final writeAccess = detail['write_access'] == true;
    var prompt = '';
    final params = detail['params'];
    if (params is Map && params['system'] is String) {
      prompt = (params['system'] as String).trim();
    }

    final items = writeAccess
        ? [
            NativeSheetItemConfig(
              id: 'model-system-prompt:$encodedModel',
              title: l10n.enterSystemPrompt,
              sfSymbol: 'text.bubble',
              kind: NativeSheetItemKind.multilineTextField,
              value: prompt,
              placeholder: l10n.enterSystemPrompt,
            ),
          ]
        : [
            NativeSheetItemConfig(
              id: 'model-prompt-readonly:$encodedModel',
              title: l10n.modelNoWriteAccessDescription,
              subtitle: prompt.isEmpty ? '—' : prompt,
              sfSymbol: 'lock',
              kind: NativeSheetItemKind.info,
            ),
          ];

    await NativeSheetBridge.instance.applyDetailPatch(
      detailId: detailId,
      subtitle: l10n.modelSystemPromptEditorDescription,
      items: items,
    );
  }

  Future<void> _patchNativeDetailError(String detailId, String title) {
    return NativeSheetBridge.instance.applyDetailPatch(
      detailId: detailId,
      clearSubtitle: true,
      items: [
        NativeSheetItemConfig(
          id: '$detailId-error',
          title: title,
          sfSymbol: 'exclamationmark.triangle',
          kind: NativeSheetItemKind.info,
        ),
      ],
    );
  }

  Future<void> _applyNativeDetail(
    NativeSheetDetailConfig detail, {
    List<NativeSheetDetailConfig> detailSheets = const [],
  }) {
    return NativeSheetBridge.instance.applyDetailPatch(
      detailId: detail.id,
      title: detail.title,
      subtitle: detail.subtitle,
      clearSubtitle: detail.subtitle == null,
      items: detail.items,
      sections: detail.sections,
      detailSheets: detailSheets,
    );
  }
}
