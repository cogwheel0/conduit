import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/models/model.dart';
import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/platform/conduit_platform_apis.g.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/adaptive_selection_sheet.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../models/direct_connection_profile.dart';
import '../models/openwebui_direct_connection.dart';
import '../providers/direct_connection_providers.dart';
import '../services/direct_chat_bridge.dart';

const List<int> _directContextLengthOptions = <int>[
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

const String openWebUiDirectConnectionSourceQueryValue = 'openwebui';

Widget _buildDirectConnectionsScaffold(
  BuildContext context, {
  required bool isOnboarding,
  required List<Widget> children,
  Widget bottomAction = const SizedBox.shrink(),
}) {
  final l10n = AppLocalizations.of(context)!;
  if (isOnboarding) {
    return UtilityPageScaffold.auth(
      title: l10n.backendChooserDirectTitle,
      backgroundColor: PlatformInfo.isIOS
          ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
          : null,
      backNavigation: UtilityBackNavigation(
        label: l10n.back,
        buttonKey: const ValueKey<String>('direct-onboarding-back-button'),
        onPressed: () => context.go(Routes.backendChooser),
      ),
      bottomAction: bottomAction,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
  return UtilityPageScaffold.settings(
    title: l10n.directConnectionsTitle,
    backgroundColor: PlatformInfo.isIOS
        ? CupertinoColors.systemGroupedBackground.resolveFrom(context)
        : null,
    children: children,
  );
}

class DirectConnectionsPage extends ConsumerStatefulWidget {
  const DirectConnectionsPage({super.key, this.isOnboarding = false});

  final bool isOnboarding;

  @override
  ConsumerState<DirectConnectionsPage> createState() =>
      _DirectConnectionsPageState();
}

class _DirectConnectionsPageState extends ConsumerState<DirectConnectionsPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refreshOpenWebUiConnections());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshOpenWebUiConnections());
    }
  }

  Future<void> _refreshOpenWebUiConnections() async {
    if (!mounted || !ref.read(openWebUiDirectConnectionsAvailableProvider)) {
      return;
    }
    try {
      await ref.read(openWebUiDirectConnectionsProvider.notifier).reload();
    } catch (_) {
      // The controller publishes its error state for the inline retry UI.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final profiles = ref.watch(directConnectionProfilesProvider);
    final openWebUiConnections = ref.watch(openWebUiDirectConnectionsProvider);
    final showOpenWebUi = ref.watch(
      openWebUiDirectConnectionsAvailableProvider,
    );
    final effectiveProfiles = ref.watch(
      effectiveDirectConnectionProfilesProvider,
    );
    final historyPolicy = ref.watch(directHistoryPolicyProvider);
    final appleOnDeviceEnabled = ref.watch(appleOnDeviceEnabledProvider);
    final appleOnDeviceStatus = appleOnDeviceEnabled
        ? ref.watch(appleOnDeviceStatusProvider)
        : null;
    final applePccEnabled = ref.watch(applePccEnabledProvider);
    final applePccStatus = applePccEnabled
        ? ref.watch(applePccStatusProvider)
        : null;
    final applePccOnDeviceFallback = ref.watch(
      applePccOnDeviceFallbackProvider,
    );
    final directModels =
        ref.watch(directModelDiscoveryProvider).value?.models ??
        const <Model>[];
    final modelsWithoutContextLimit = directModels
        .where((model) => directModelAdvertisedContextLength(model) == null)
        .toList(growable: false);
    final contextLengthOverrides = ref.watch(
      directContextLengthOverridesProvider,
    );

    return profiles.when(
      loading: () => _buildDirectConnectionsScaffold(
        context,
        isOnboarding: widget.isOnboarding,
        children: const [
          SizedBox(height: Spacing.xxl),
          Center(child: CircularProgressIndicator.adaptive()),
        ],
        bottomAction: ConduitButton(
          text: l10n.finishDirectSetup,
          isFullWidth: true,
          isLoading: true,
        ),
      ),
      error: (error, _) => _buildDirectConnectionsScaffold(
        context,
        isOnboarding: widget.isOnboarding,
        children: [
          DirectConnectionsError(
            message: _friendlyLoadError(l10n, error),
            onRetry: () =>
                ref.read(directConnectionProfilesProvider.notifier).reload(),
          ),
        ],
      ),
      data: (items) => DirectConnectionsContent(
        profiles: items,
        appleOnDeviceStatus: appleOnDeviceStatus,
        applePccStatus: applePccStatus,
        applePccOnDeviceFallback: applePccOnDeviceFallback,
        onApplePccFallbackChanged: (enabled) => ref
            .read(applePccOnDeviceFallbackProvider.notifier)
            .setEnabled(enabled),
        onRefreshAppleOnDevice: () =>
            ref.invalidate(appleOnDeviceStatusProvider),
        onRefreshApplePcc: () => ref.invalidate(applePccStatusProvider),
        onShowApplePccQuotaOptions: () async {
          final shown = await ref
              .read(applePccAdapterProvider)
              .showQuotaIncreaseSuggestion();
          ref.invalidate(applePccStatusProvider);
          if (!shown && context.mounted) {
            UiUtils.showMessage(context, l10n.applePccUnavailable);
          }
        },
        modelsWithoutContextLimit: modelsWithoutContextLimit,
        contextLengthOverrides: contextLengthOverrides,
        onContextLengthChanged: (modelId, contextLength) => unawaited(
          ref
              .read(directContextLengthOverridesProvider.notifier)
              .set(modelId, contextLength),
        ),
        openWebUiConnections: openWebUiConnections,
        showOpenWebUi: showOpenWebUi,
        showHistorySync: showOpenWebUi,
        syncWithOpenWebUi:
            historyPolicy == DirectHistoryPolicy.syncWithOpenWebUI,
        isOnboarding: widget.isOnboarding,
        onSyncChanged: (sync) {
          ref
              .read(directHistoryPolicyProvider.notifier)
              .setPolicy(
                sync
                    ? DirectHistoryPolicy.syncWithOpenWebUI
                    : DirectHistoryPolicy.localOnly,
              );
        },
        onAdd: () => _openEditor(context, 'new'),
        onAddOpenWebUi: () => _openEditor(context, 'new', isOpenWebUi: true),
        onEdit: (id) => _openEditor(context, id),
        onEditOpenWebUi: (id) => _openEditor(context, id, isOpenWebUi: true),
        onRetryOpenWebUi: () => unawaited(_refreshOpenWebUiConnections()),
        onFinishOnboarding:
            (effectiveProfiles.value?.any((profile) => profile.isUsable) ??
                false)
            ? () async {
                await ref
                    .read(preferredBackendProvider.notifier)
                    .set(PreferredBackend.direct);
                if (context.mounted) context.go(Routes.chat);
              }
            : null,
      ),
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    String id, {
    bool isOpenWebUi = false,
  }) async {
    await context.pushNamed(
      RouteNames.directConnectionEditor,
      pathParameters: {'id': id},
      queryParameters: {
        if (widget.isOnboarding) 'onboarding': 'true',
        if (isOpenWebUi) 'source': openWebUiDirectConnectionSourceQueryValue,
      },
      extra: const NativeSheetNavigationOrigin(),
    );
  }
}

class DirectConnectionsContent extends StatelessWidget {
  const DirectConnectionsContent({
    super.key,
    required this.profiles,
    this.openWebUiConnections = const AsyncValue.data(null),
    this.showOpenWebUi = false,
    this.showHistorySync = false,
    required this.syncWithOpenWebUi,
    required this.isOnboarding,
    required this.onSyncChanged,
    required this.onAdd,
    required this.onEdit,
    this.onAddOpenWebUi,
    this.onEditOpenWebUi,
    this.onRetryOpenWebUi,
    this.onFinishOnboarding,
    this.appleOnDeviceStatus,
    this.applePccStatus,
    this.applePccOnDeviceFallback = false,
    this.onApplePccFallbackChanged,
    this.onRefreshAppleOnDevice,
    this.onRefreshApplePcc,
    this.onShowApplePccQuotaOptions,
    this.modelsWithoutContextLimit = const <Model>[],
    this.contextLengthOverrides = const <String, int>{},
    this.onContextLengthChanged,
  });

  final List<DirectConnectionProfile> profiles;
  final AsyncValue<OpenWebUiDirectConnectionsSnapshot?> openWebUiConnections;
  final bool showOpenWebUi;
  final bool showHistorySync;
  final bool syncWithOpenWebUi;
  final bool isOnboarding;
  final ValueChanged<bool> onSyncChanged;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final VoidCallback? onAddOpenWebUi;
  final ValueChanged<String>? onEditOpenWebUi;
  final VoidCallback? onRetryOpenWebUi;
  final VoidCallback? onFinishOnboarding;
  final AsyncValue<PlatformPccStatus>? appleOnDeviceStatus;
  final AsyncValue<PlatformPccStatus>? applePccStatus;
  final bool applePccOnDeviceFallback;
  final ValueChanged<bool>? onApplePccFallbackChanged;
  final VoidCallback? onRefreshAppleOnDevice;
  final VoidCallback? onRefreshApplePcc;
  final VoidCallback? onShowApplePccQuotaOptions;
  final List<Model> modelsWithoutContextLimit;
  final Map<String, int> contextLengthOverrides;
  final void Function(String modelId, int contextLength)?
  onContextLengthChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasAppleModels =
        appleOnDeviceStatus != null || applePccStatus != null;
    final content = <Widget>[
      if (hasAppleModels) ...[
        SettingsSectionHeader(title: l10n.backendChooserAppleSectionTitle),
        const SizedBox(height: Spacing.sm),
        if (appleOnDeviceStatus != null)
          _AppleModelSection(
            status: appleOnDeviceStatus!,
            onDevice: true,
            onRefresh: onRefreshAppleOnDevice,
          ),
        if (appleOnDeviceStatus != null && applePccStatus != null)
          const SizedBox(height: Spacing.sm),
        if (applePccStatus != null)
          _AppleModelSection(
            status: applePccStatus!,
            onDevice: false,
            onDeviceFallback: applePccOnDeviceFallback,
            onFallbackChanged: onApplePccFallbackChanged,
            onRefresh: onRefreshApplePcc,
            onShowQuotaOptions: onShowApplePccQuotaOptions,
          ),
        const SizedBox(height: Spacing.xl),
      ],
      if (modelsWithoutContextLimit.isNotEmpty &&
          onContextLengthChanged != null) ...[
        _DirectContextCompactionSection(
          models: modelsWithoutContextLimit,
          contextLengthOverrides: contextLengthOverrides,
          onChanged: onContextLengthChanged!,
        ),
        const SizedBox(height: Spacing.xl),
      ],
      if (showHistorySync) ...[
        InsetGroupedList(
          useNativeSurface: PlatformInfo.isIOS,
          footer: PlatformInfo.isIOS
              ? (syncWithOpenWebUi
                    ? l10n.syncDirectHistorySubtitle
                    : l10n.directHistoryLocalOnlySubtitle)
              : null,
          children: [
            UtilityRow(
              title: l10n.syncDirectHistory,
              subtitle: PlatformInfo.isIOS
                  ? null
                  : syncWithOpenWebUi
                  ? l10n.syncDirectHistorySubtitle
                  : l10n.directHistoryLocalOnlySubtitle,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              preserveTrailingSemantics: true,
              trailing: AdaptiveSwitch(
                value: syncWithOpenWebUi,
                onChanged: onSyncChanged,
              ),
              onTap: () => onSyncChanged(!syncWithOpenWebUi),
            ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
      ],
      if (showOpenWebUi) ...[
        _OpenWebUiDirectConnectionSection(
          connections: openWebUiConnections,
          onAdd: onAddOpenWebUi ?? onAdd,
          onEdit: onEditOpenWebUi ?? onEdit,
          onRetry: onRetryOpenWebUi,
          flat: isOnboarding,
        ),
        const SizedBox(height: Spacing.xl),
      ],
      _DirectConnectionSection(
        title: showOpenWebUi
            ? l10n.deviceDirectConnectionsSectionTitle
            : l10n.directConnectionsSectionTitle,
        profiles: profiles,
        sourceLabel: l10n.deviceDirectConnectionSourceLabel,
        emptyTitle: l10n.directProfilesEmptyTitle,
        emptySubtitle: l10n.directProfilesEmptySubtitle,
        onAdd: onAdd,
        onEdit: onEdit,
        flat: isOnboarding,
      ),
    ];

    return _buildDirectConnectionsScaffold(
      context,
      isOnboarding: isOnboarding,
      children: content,
      bottomAction: ConduitButton(
        key: const ValueKey<String>('finish-direct-onboarding-button'),
        text: l10n.finishDirectSetup,
        isFullWidth: true,
        onPressed: onFinishOnboarding,
      ),
    );
  }
}

class _AppleModelSection extends StatelessWidget {
  const _AppleModelSection({
    required this.status,
    required this.onDevice,
    this.onDeviceFallback = false,
    this.onFallbackChanged,
    this.onRefresh,
    this.onShowQuotaOptions,
  });

  final AsyncValue<PlatformPccStatus> status;
  final bool onDevice;
  final bool onDeviceFallback;
  final ValueChanged<bool>? onFallbackChanged;
  final VoidCallback? onRefresh;
  final VoidCallback? onShowQuotaOptions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final value = status.value;
    final details = <String>[];
    final notes = <String>[];
    if (status.isLoading && value == null) {
      details.add(l10n.loadingShort);
    } else if (value == null) {
      details.add(
        onDevice ? l10n.appleOnDeviceUnavailable : l10n.applePccUnavailable,
      );
    } else {
      details.add(_availabilityLabel(l10n, value));
      if (value.contextSize case final tokens?) {
        details.add(l10n.applePccContextSize(_formatTokenCount(tokens)));
      }
      if (value.quotaResetAtMilliseconds case final milliseconds?) {
        final reset = DateTime.fromMillisecondsSinceEpoch(milliseconds)
            .toLocal();
        final material = MaterialLocalizations.of(context);
        final formatted =
            '${material.formatShortDate(reset)} '
            '${material.formatTimeOfDay(TimeOfDay.fromDateTime(reset))}';
        notes.add(l10n.applePccQuotaResetsAt(formatted));
      }
      if (value.supportsCurrentLocale == false) {
        notes.add(l10n.applePccCurrentLanguageUnsupported);
      }
    }

    return InsetGroupedList(
      useNativeSurface: PlatformInfo.isIOS,
      footer: notes.isEmpty ? null : notes.join('\n'),
      children: [
        UtilityRow(
          key: ValueKey<String>(
            onDevice ? 'apple-on-device-status-row' : 'apple-pcc-status-row',
          ),
          leading: Icon(
            onDevice
                ? (PlatformInfo.isIOS
                      ? CupertinoIcons.device_phone_portrait
                      : Icons.smartphone_rounded)
                : (PlatformInfo.isIOS
                      ? CupertinoIcons.cloud_fill
                      : Icons.cloud_rounded),
            color: context.conduitTheme.buttonPrimary,
          ),
          title: onDevice
              ? l10n.backendChooserAppleOnDeviceTitle
              : l10n.backendChooserApplePccTitle,
          subtitle: details.join(' · '),
          subtitleMaxLines: 2,
          titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
          trailing: status.isLoading
              ? const SizedBox.square(
                  dimension: IconSize.medium,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                )
              : onRefresh == null
              ? null
              : Icon(
                  PlatformInfo.isIOS
                      ? CupertinoIcons.refresh
                      : Icons.refresh_rounded,
                  color: context.conduitTheme.buttonPrimary,
                ),
          onTap: status.isLoading ? null : onRefresh,
        ),
        if (!onDevice)
          UtilityRow(
            key: const ValueKey<String>('apple-pcc-fallback-row'),
            title: l10n.applePccOnDeviceFallback,
            subtitle: l10n.applePccOnDeviceFallbackSubtitle,
            preserveTrailingSemantics: true,
            trailing: AdaptiveSwitch(
              value: onDeviceFallback,
              onChanged: onFallbackChanged,
            ),
            onTap: onFallbackChanged == null
                ? null
                : () => onFallbackChanged!(!onDeviceFallback),
          ),
        if (!onDevice &&
            value?.canIncreaseQuota == true &&
            onShowQuotaOptions != null)
          UtilityRow(
            key: const ValueKey<String>('apple-pcc-quota-options-row'),
            title: l10n.applePccShowQuotaOptions,
            showChevron: true,
            onTap: onShowQuotaOptions,
          ),
      ],
    );
  }

  String _availabilityLabel(AppLocalizations l10n, PlatformPccStatus value) {
    if (value.availability != PlatformPccAvailability.available) {
      return value.message ??
          (onDevice ? l10n.appleOnDeviceUnavailable : l10n.applePccUnavailable);
    }
    return switch (value.quotaStatus) {
      PlatformPccQuotaStatus.approachingLimit => l10n.applePccQuotaApproaching,
      PlatformPccQuotaStatus.limitReached => l10n.applePccQuotaReached,
      PlatformPccQuotaStatus.belowLimit ||
      PlatformPccQuotaStatus.unknown => l10n.applePccStatusAvailable,
    };
  }
}

class _DirectContextCompactionSection extends StatelessWidget {
  const _DirectContextCompactionSection({
    required this.models,
    required this.contextLengthOverrides,
    required this.onChanged,
  });

  final List<Model> models;
  final Map<String, int> contextLengthOverrides;
  final void Function(String modelId, int contextLength) onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedList(
      title: l10n.directContextCompactionTitle,
      footer: l10n.directContextCompactionDescription,
      useNativeSurface: PlatformInfo.isIOS,
      children: [
        for (final model in models)
          UtilityRow(
            key: ValueKey<String>('direct-context-limit-${model.id}'),
            title: model.name,
            subtitle: [
              if (model.metadata?['profileName'] case final String profileName)
                profileName,
              l10n.applePccContextSize(
                _formatTokenCount(
                  contextLengthOverrides[model.id] ??
                      kDefaultDirectContextLength,
                ),
              ),
            ].join(' · '),
            titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
            showChevron: true,
            onTap: () => _showPicker(context, model),
          ),
      ],
    );
  }

  Future<void> _showPicker(BuildContext context, Model model) async {
    final l10n = AppLocalizations.of(context)!;
    final current =
        contextLengthOverrides[model.id] ?? kDefaultDirectContextLength;
    final selected = await showAdaptiveSelectionSheet<int>(
      context: context,
      builder: (sheetContext) => AdaptiveSelectionSheet(
        title: model.name,
        description: l10n.directContextCompactionPickerDescription,
        itemCount: _directContextLengthOptions.length,
        itemBuilder: (context, index) {
          final value = _directContextLengthOptions[index];
          return AdaptiveSelectionTile(
            title: l10n.applePccContextSize(_formatTokenCount(value)),
            selected: value == current,
            onTap: () => Navigator.of(sheetContext).pop(value),
          );
        },
      ),
    );
    if (selected != null) onChanged(model.id, selected);
  }
}

String _formatTokenCount(int tokens) {
  if (tokens % (1024 * 1024) == 0) return '${tokens ~/ (1024 * 1024)}M';
  if (tokens % 1024 == 0) return '${tokens ~/ 1024}K';
  return tokens.toString();
}

class DirectConnectionsError extends StatelessWidget {
  const DirectConnectionsError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        const SizedBox(height: Spacing.xl),
        Text(
          l10n.directConnectionError,
          textAlign: TextAlign.center,
          style: theme.headingSmall?.copyWith(color: theme.textPrimary),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.lg),
        ConduitButton(
          text: l10n.retry,
          icon: Icons.refresh,
          onPressed: onRetry,
        ),
      ],
    );
  }
}

class _OpenWebUiDirectConnectionSection extends StatelessWidget {
  const _OpenWebUiDirectConnectionSection({
    required this.connections,
    required this.onAdd,
    required this.onEdit,
    this.onRetry,
    this.flat = false,
  });

  final AsyncValue<OpenWebUiDirectConnectionsSnapshot?> connections;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final VoidCallback? onRetry;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final snapshot = connections.value;
    final records =
        snapshot?.records ?? const <OpenWebUiDirectConnectionRecord>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DirectConnectionSectionHeader(
          title: l10n.openWebUiDirectConnectionsSectionTitle,
          onAdd: records.isNotEmpty ? onAdd : null,
        ),
        const SizedBox(height: Spacing.sm),
        if (connections.isLoading && snapshot == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Spacing.xl),
            child: Center(child: CircularProgressIndicator.adaptive()),
          )
        else if (connections.hasError && snapshot == null)
          _OpenWebUiDirectConnectionsError(onRetry: onRetry)
        else if (records.isEmpty) ...[
          _DirectConnectionsEmptyState(
            title: l10n.openWebUiDirectProfilesEmptyTitle,
            subtitle: l10n.openWebUiDirectProfilesEmptySubtitle,
            onAdd: onAdd,
            flat: flat,
          ),
          if (connections.hasError) ...[
            const SizedBox(height: Spacing.sm),
            _OpenWebUiDirectConnectionsError(onRetry: onRetry),
          ],
        ] else ...[
          _DirectConnectionListSurface(
            flat: flat,
            children: [
              for (var index = 0; index < records.length; index++)
                _DirectConnectionTile(
                  profile: records[index].profile,
                  sourceLabel: l10n.openWebUiDirectConnectionSourceLabel,
                  isCompatible: records[index].isCompatible,
                  showDivider: index != records.length - 1,
                  onTap: () => onEdit(records[index].profile.id),
                ),
            ],
          ),
          if (connections.hasError) ...[
            const SizedBox(height: Spacing.sm),
            _OpenWebUiDirectConnectionsError(onRetry: onRetry),
          ],
        ],
      ],
    );
  }
}

class _DirectConnectionSection extends StatelessWidget {
  const _DirectConnectionSection({
    required this.title,
    required this.profiles,
    required this.sourceLabel,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.onAdd,
    required this.onEdit,
    this.flat = false,
  });

  final String title;
  final List<DirectConnectionProfile> profiles;
  final String sourceLabel;
  final String emptyTitle;
  final String emptySubtitle;
  final VoidCallback onAdd;
  final ValueChanged<String> onEdit;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DirectConnectionSectionHeader(
          title: title,
          onAdd: profiles.isNotEmpty ? onAdd : null,
        ),
        const SizedBox(height: Spacing.sm),
        if (profiles.isEmpty)
          _DirectConnectionsEmptyState(
            title: emptyTitle,
            subtitle: emptySubtitle,
            onAdd: onAdd,
            flat: flat,
          )
        else
          _DirectConnectionListSurface(
            flat: flat,
            children: [
              for (var index = 0; index < profiles.length; index++)
                _DirectConnectionTile(
                  profile: profiles[index],
                  sourceLabel: sourceLabel,
                  showDivider: index != profiles.length - 1,
                  onTap: () => onEdit(profiles[index].id),
                ),
            ],
          ),
      ],
    );
  }
}

class _DirectConnectionSectionHeader extends StatelessWidget {
  const _DirectConnectionSectionHeader({required this.title, this.onAdd});

  final String title;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Expanded(child: SettingsSectionHeader(title: title)),
              if (onAdd != null) ...[
                const SizedBox(width: Spacing.sm),
                if (PlatformInfo.isIOS)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
                    minimumSize: const Size(0, TouchTarget.minimum),
                    onPressed: onAdd,
                    child: Text(
                      l10n.addDirectConnection,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: theme.buttonPrimary,
                      ),
                    ),
                  )
                else if (constraints.maxWidth < 330)
                  ConduitIconButton(
                    icon: Icons.add,
                    tooltip: l10n.addDirectConnection,
                    onPressed: onAdd,
                    isCompact: true,
                    isCircular: false,
                    backgroundColor: theme.surfaceContainer,
                    iconColor: theme.buttonPrimary,
                  )
                else
                  ConduitButton(
                    text: l10n.addDirectConnection,
                    icon: Icons.add,
                    isCompact: true,
                    isSecondary: true,
                    onPressed: onAdd,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _OpenWebUiDirectConnectionsError extends StatelessWidget {
  const _OpenWebUiDirectConnectionsError({this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    return InsetGroupedSection(
      child: Row(
        children: [
          Icon(Icons.sync_problem_outlined, color: theme.error),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              l10n.openWebUiDirectConnectionsLoadFailed,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: Spacing.sm),
            ConduitButton(
              text: l10n.retry,
              isCompact: true,
              isSecondary: true,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

class _DirectConnectionsEmptyState extends StatelessWidget {
  const _DirectConnectionsEmptyState({
    required this.title,
    required this.subtitle,
    required this.onAdd,
    this.flat = false,
  });

  final String title;
  final String subtitle;
  final VoidCallback onAdd;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final content = UtilityRow(
      title: title,
      subtitle: subtitle,
      titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
      trailing: Icon(
        context.usesCupertinoChrome
            ? CupertinoIcons.add_circled
            : Icons.add_circle_outline,
        color: context.conduitTheme.buttonPrimary,
        size: IconSize.medium,
      ),
      onTap: onAdd,
    );
    if (flat && !PlatformInfo.isIOS) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: content,
      );
    }
    return InsetGroupedList(
      useNativeSurface: PlatformInfo.isIOS,
      children: [content],
    );
  }
}

class _DirectConnectionTile extends StatelessWidget {
  const _DirectConnectionTile({
    required this.profile,
    required this.sourceLabel,
    required this.onTap,
    this.isCompatible = true,
    this.showDivider = false,
  });

  final DirectConnectionProfile profile;
  final String sourceLabel;
  final bool isCompatible;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final isOllama = profile.adapterKey == kOllamaAdapterKey;
    final provider = isOllama ? l10n.ollama : l10n.openAICompatible;
    final status = !isCompatible
        ? l10n.directConnectionUnavailableLabel
        : profile.enabled
        ? l10n.enabledLabel
        : l10n.disabledLabel;

    if (PlatformInfo.isIOS) {
      return UtilityRow(
        title: profile.name,
        subtitle: '$provider · $status\n${profile.baseUrl}',
        subtitleMaxLines: 2,
        titleFontWeight: FontWeight.w400,
        showChevron: true,
        onTap: onTap,
      );
    }

    return UtilitySelectionRow(
      leading: SettingsIconBadge(
        icon: isOllama
            ? UiUtils.platformIcon(
                ios: CupertinoIcons.desktopcomputer,
                android: Icons.computer_outlined,
              )
            : UiUtils.platformIcon(
                ios: CupertinoIcons.cloud,
                android: Icons.cloud_outlined,
              ),
        color: profile.enabled && isCompatible
            ? theme.buttonPrimary
            : theme.iconSecondary,
      ),
      title: profile.name,
      subtitle: '$provider · $status\n${profile.baseUrl}',
      selected: false,
      showSelectionIndicator: false,
      showDivider: showDivider,
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            sourceLabel,
            style: theme.bodySmall?.copyWith(color: theme.textTertiary),
          ),
          const SizedBox(height: Spacing.xs),
          Icon(
            context.usesCupertinoChrome
                ? CupertinoIcons.chevron_forward
                : Icons.chevron_right,
            color: theme.iconSecondary,
            size: IconSize.small,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _DirectConnectionListSurface extends StatelessWidget {
  const _DirectConnectionListSurface({
    required this.children,
    this.flat = false,
  });

  final List<Widget> children;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    if (flat && !PlatformInfo.isIOS) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
        child: Column(children: children),
      );
    }
    return InsetGroupedList(
      useNativeSurface: PlatformInfo.isIOS,
      children: children,
    );
  }
}

String _friendlyLoadError(AppLocalizations l10n, Object error) {
  if (error is FormatException) {
    return l10n.directSavedDataUnreadable;
  }
  return l10n.directSecureStorageUnavailable;
}
