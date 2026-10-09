import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:conduit_core/providers/backend_mode_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import '../../../shared/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/hermes_connection_controller.dart';
import '../widgets/hermes_connection_switcher.dart';

import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_connection_profile.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_connection_service.dart';

import 'hermes_desktop_connection_section.dart';
import 'hermes_settings_sections.dart';

/// Editor for one saved Hermes connection: name, server URL, credentials, and
/// a connection test. For the active connection it also shows the server's
/// capabilities and management sections.
class HermesSettingsPage extends ConsumerStatefulWidget {
  const HermesSettingsPage({
    super.key,
    this.isOnboarding = false,
    this.connectionId,
    this.onFinished,
  });

  /// When true, the page is shown as a first-run setup step for the active
  /// connection (or the first one): the enable toggle is implicit, and a
  /// "Connect" button completes onboarding into the app.
  final bool isOnboarding;

  /// Saved connection to edit; null adds a new one. Ignored in onboarding.
  final String? connectionId;

  /// Set when the editor is part of the account sheet rather than a page: it
  /// brings no page of its own, leaves the server's management to the page,
  /// and this is called, rather than going back, once the connection is
  /// saved -- a new one also tested and put in use -- or deleted.
  final VoidCallback? onFinished;

  @override
  ConsumerState<HermesSettingsPage> createState() => _HermesSettingsPageState();
}

class _HermesSettingsPageState extends ConsumerState<HermesSettingsPage> {
  HermesConnectionController? _connectionController;

  /// Stored settings and secrets of an inactive connection, the baseline its
  /// drafts are built against. The active connection reads the live state.
  HermesConfig? _stored;
  int _storedReloads = 0;
  bool _loadFailed = false;
  bool _switching = false;

  /// Work in flight that can rotate this inactive connection's stored tokens,
  /// as listing its profiles does. A switch waits for it, or it would load
  /// the tokens being replaced, and the replacements would then be refused
  /// because the connection had become active. (A test keeps the editor
  /// busy, which already holds the switch back.)
  final Set<Future<void>> _tokenWork = {};

  @override
  void initState() {
    super.initState();
    final active = ref.read(hermesConfigProvider);
    final target = widget.isOnboarding
        ? active.connectionId
        : widget.connectionId;
    if (target == null) {
      _attach(widget.isOnboarding ? active : const HermesConfig());
    } else if (target == active.connectionId) {
      _attach(active);
    } else {
      unawaited(_loadStored(target));
    }
  }

  void _attach(HermesConfig initial) {
    final profile = ref
        .read(hermesConnectionsProvider)
        .where((profile) => profile.id == initial.connectionId)
        .firstOrNull;
    _connectionController = HermesConnectionController(
      initialConfig: initial,
      initialNameSource: profile?.nameSource,
      gateway: ref.read(hermesConnectionGatewayProvider),
    )..addListener(_handleConnectionChanged);
  }

  Future<void> _loadStored(String connectionId) async {
    try {
      final stored = await ref
          .read(hermesConfigProvider.notifier)
          .savedConnectionConfig(connectionId);
      if (!mounted) return;
      setState(() {
        _stored = stored;
        _attach(stored);
      });
    } catch (error) {
      DebugLogger.warning(
        'connection-load-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// Loads an inactive connection, or the stored baseline of the one being
  /// edited, again after reading it failed, retrying a secure-storage outage
  /// first since it blocks every read.
  Future<void> _retryLoad() async {
    final id = _connectionController?.connectionId ?? widget.connectionId;
    if (id == null) return;
    setState(() => _loadFailed = false);
    if (ref.read(hermesSecretsErrorProvider) != null) {
      await ref.read(hermesConfigProvider.notifier).retrySecrets();
      if (!mounted) return;
    }
    if (_connectionController == null) {
      await _loadStored(id);
    } else {
      await _refreshStored();
    }
  }

  void _handleConnectionChanged() {
    if (mounted) setState(() {});
  }

  void _trackTokenWork(Future<void> work) {
    final settled = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tokenWork.add(settled);
    unawaited(settled.whenComplete(() => _tokenWork.remove(settled)));
  }

  HermesConnectionController get _controller => _connectionController!;

  bool get _embedded => widget.onFinished != null;

  /// Opened in the account sheet to add a connection. It stays the adding
  /// form after a Connect that saved the connection but failed to put it in
  /// use, so the next Connect finishes the job rather than only saving.
  bool get _addingInSheet => _embedded && widget.connectionId == null;

  /// Whether this editor's connection is the active one.
  bool get _editsActive {
    final id = _controller.connectionId;
    return widget.isOnboarding ||
        (id != null && id == ref.read(hermesConfigProvider).connectionId);
  }

  /// Whether the persisted baseline for this editor is loaded. An inactive
  /// connection's baseline must come from storage: comparing a draft against
  /// an empty one would read as an origin change and drop its secrets.
  bool get _baselineReady =>
      _editsActive || _controller.connectionId == null || _stored != null;

  /// The persisted state drafts compare against (origin changes, configured
  /// secrets).
  HermesConfig _saved() {
    if (_editsActive) return ref.read(hermesConfigProvider);
    if (_controller.connectionId == null) return const HermesConfig();
    return _stored ?? HermesConfig(connectionId: _controller.connectionId);
  }

  HermesConnectionMessages _messages(AppLocalizations l10n) =>
      HermesConnectionMessages(
        connecting: l10n.connecting,
        connected: l10n.connectedToServer,
        saved: l10n.saved,
        unreachable: l10n.couldNotConnectGeneric,
        persistenceFailed: l10n.directConnectionSaveFailed,
        activationFailed: l10n.hermesOnboardingFailed,
      );

  Future<void> _finishOnboarding() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final l10n = AppLocalizations.of(context)!;
    final result = await _controller.finishOnboarding(
      saved: _saved(),
      messages: _messages(l10n),
    );
    if (!mounted) return;
    if (result.outcome == HermesConnectionOutcome.success) {
      context.go(Routes.chat);
    }
  }

  void _leaveOnboarding() {
    _controller.cancelPendingOnboarding();
    context.go(Routes.backendChooser);
  }

  @override
  void dispose() {
    _connectionController?.removeListener(_handleConnectionChanged);
    _connectionController?.dispose();
    super.dispose();
  }

  Future<bool> _saveSettings() async {
    if (!_baselineReady) return false;
    final l10n = AppLocalizations.of(context)!;
    final saved = await _controller.save(_saved(), messages: _messages(l10n));
    // A save still completes after the page closes; there is nothing to reload.
    if (saved && mounted) await _refreshStored();
    return saved;
  }

  /// Reloads the stored baseline after an inactive connection was saved or
  /// its stored state changed.
  Future<void> _refreshStored() async {
    if (!mounted) return;
    final id = _controller.connectionId;
    final reload = ++_storedReloads;
    if (id == null || _editsActive) {
      if (mounted) {
        setState(() {
          _stored = null;
          _loadFailed = false;
        });
      }
      return;
    }
    try {
      final stored = await ref
          .read(hermesConfigProvider.notifier)
          .savedConnectionConfig(id);
      // Reloads can overlap and finish out of order; keep the latest read.
      if (mounted && reload == _storedReloads) {
        setState(() {
          _stored = stored;
          _loadFailed = false;
        });
      }
    } catch (error) {
      DebugLogger.warning(
        'connection-reload-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
      // A stale baseline still guards a save; without one, Save and Test
      // stay off, so say why and offer to read it again.
      if (mounted && reload == _storedReloads && _stored == null) {
        setState(() => _loadFailed = true);
      }
    }
  }

  /// Why a connection or its stored baseline is missing, and a way to read
  /// it again.
  List<Widget> _loadFailure(AppLocalizations l10n) => [
    UtilityStatusBanner(
      message: l10n.hermesSecretsUnavailable,
      tone: UtilityStatusTone.warning,
    ),
    const SizedBox(height: Spacing.md),
    ConduitButton(
      key: const ValueKey<String>('hermes-retry-load-connection'),
      text: l10n.retry,
      isSecondary: true,
      onPressed: _retryLoad,
    ),
  ];

  /// Desktop sign-in needs the live connection: save the draft, then make
  /// this connection the active one.
  Future<bool> _prepareSignIn() async {
    if (!await _saveSettings() || !mounted) return false;
    return _editsActive || await _useConnection();
  }

  Future<bool> _useConnection() async {
    final id = _controller.connectionId;
    if (id == null || _switching) return false;
    setState(() => _switching = true);
    await Future.wait(_tokenWork.toList());
    if (!mounted) return false;
    final switched = await switchHermesConnection(context, ref, id);
    if (mounted) {
      setState(() {
        _switching = false;
        if (switched) _stored = null;
      });
    }
    return switched;
  }

  Future<void> _delete() async {
    final id = _controller.connectionId;
    if (id == null) return;
    final l10n = AppLocalizations.of(context)!;
    final name =
        ref
            .read(hermesConnectionsProvider)
            .where((profile) => profile.id == id)
            .firstOrNull
            ?.name ??
        kHermesDefaultConnectionName;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.hermesDeleteConnectionTitle,
      message: l10n.hermesDeleteConnectionMessage(name),
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    // The deletion and the preference after it finish even if the page
    // closes meanwhile, when its ref is gone.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(hermesConfigProvider.notifier).deleteConnection(id);
      // With nothing left to connect to, a Hermes-only install goes back to
      // the backend chooser instead of keeping a stale preference.
      if (container.read(hermesConnectionsProvider).isEmpty &&
          container.read(preferredBackendProvider) == PreferredBackend.hermes) {
        await container
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.unset);
      }
      if (!mounted) return;
      if (_embedded) {
        widget.onFinished!();
      } else {
        unawaited(Navigator.of(context).maybePop());
      }
    } catch (error) {
      DebugLogger.warning(
        'connection-delete-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      AdaptiveSnackBar.show(
        context,
        message: l10n.hermesDeleteConnectionFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  /// The account sheet's Connect: tests the new connection, saves it, and
  /// puts it in use, turning Hermes on.
  Future<void> _connectInSheet() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final reachable = await _controller.testConnection(
      saved: _saved(),
      messages: _messages(AppLocalizations.of(context)!),
    );
    if (!reachable || !mounted || !await _saveSettings() || !mounted) return;
    if (!_editsActive && !await _useConnection()) return;
    if (!mounted) return;
    // Turned on, and the primary backend only where there was none: next to
    // Open WebUI or Direct it joins them.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await container.read(hermesConfigProvider.notifier).setEnabled(true);
      if (container.read(preferredBackendProvider) == PreferredBackend.unset) {
        await container
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.hermes);
      }
    } catch (error) {
      DebugLogger.warning(
        'connection-enable-failed',
        scope: 'hermes/connections',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: AppLocalizations.of(context)!.hermesSwitchConnectionFailed,
          type: AdaptiveSnackBarType.error,
        );
      }
      return;
    }
    if (mounted) widget.onFinished!();
  }

  Future<void> _saveInSheet() async {
    if (await _saveSettings() && mounted) widget.onFinished!();
  }

  Future<void> _testConnection() async {
    await _controller.testConnection(
      saved: _saved(),
      messages: _messages(AppLocalizations.of(context)!),
    );
    if (_editsActive) ref.invalidate(hermesServerStatusProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final controller = _connectionController;
    if (controller == null) {
      return UtilityPageScaffold.settings(
        title: l10n.hermesAgentSettingsTitle,
        children: [
          if (_loadFailed)
            ..._loadFailure(l10n)
          else
            const Padding(
              padding: EdgeInsets.all(Spacing.xl),
              child: Center(child: AdaptiveProgressIndicator()),
            ),
        ],
      );
    }
    // An editor whose connection stops being active (switched elsewhere)
    // reloads its stored baseline before it can save again.
    ref.listen<String?>(hermesActiveConnectionIdProvider, (previous, next) {
      if (previous != next && !_editsActive && _stored == null) {
        unawaited(_refreshStored());
      }
    });
    // Probing or listing profiles can rotate an inactive connection's tokens
    // in storage; a test or save must not send or write the spent ones.
    ref.listen<int>(hermesConnectionsRevisionProvider, (_, _) {
      if (!_editsActive && _stored != null) unawaited(_refreshStored());
    });
    // Rebuild when the active connection changes or its state hydrates.
    final activeConfig = ref.watch(hermesConfigProvider);
    final connectionNames = ref.watch(hermesConnectionsProvider);
    final editsActive = _editsActive;
    final config = editsActive ? activeConfig : _saved();
    final existing = controller.connectionId != null;
    final draftUsable =
        _baselineReady &&
        controller.draftIsUsable(config) &&
        !controller.operation.isBusy;
    final urlError = switch (controller.validationIssue) {
      HermesConnectionValidationIssue.invalidUrl =>
        l10n.directConnectionUrlInvalid,
      HermesConnectionValidationIssue.credentialsReentryRequired =>
        l10n.directConnectionCredentialsReentryRequired,
      null => null,
    };
    final gap = SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg);
    final nameField = AccessibleFormField(
      key: const ValueKey<String>('hermes-connection-name-field'),
      enabled: !controller.operation.isBusy,
      label: l10n.name,
      hint: HermesConnectionProfile.deriveName(controller.url.text),
      controller: controller.name,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      onChanged: (_) => controller.markNameChanged(),
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final serverUrlField = AccessibleFormField(
      key: const ValueKey<String>('hermes-server-url-field'),
      enabled: !controller.operation.isBusy,
      label: l10n.hermesServerUrlTitle,
      hint: 'http://192.168.1.10:8642',
      controller: controller.url,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      errorText: urlError,
      onChanged: (_) => controller.markUrlChanged(),
      isRequired: true,
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final apiKeyField = AccessibleFormField(
      key: const ValueKey<String>('hermes-api-key-field'),
      enabled: !controller.operation.isBusy,
      label: l10n.hermesApiKeyTitle,
      hint: config.apiKey == null || config.apiKey!.isEmpty
          ? l10n.hermesApiKeyPlaceholder
          : l10n.hermesConfiguredReplacePlaceholder,
      obscureText: true,
      controller: controller.apiKey,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      onChanged: (_) => controller.markApiKeyChanged(),
      isRequired: true,
      iosSettingsRow: PlatformInfo.isIOS,
    );
    final desktopTokenField = AccessibleFormField(
      enabled: !controller.operation.isBusy,
      label: l10n.hermesLegacySessionToken,
      hint: config.desktopCredentials?.legacyToken?.isNotEmpty == true
          ? l10n.hermesConfiguredReplacePlaceholder
          : l10n.hermesLegacySessionTokenHint,
      obscureText: true,
      controller: controller.desktopLegacyToken,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: TextInputAction.next,
      autocorrect: false,
      onChanged: (_) => controller.markDesktopLegacyTokenChanged(),
      isRequired:
          controller.desktopAuthKind == HermesDesktopAuthKind.legacyToken,
      iosSettingsRow: PlatformInfo.isIOS,
    );

    final content = <Widget>[
      // Its retry also clears a secure-storage outage, so it replaces that
      // banner rather than repeating it.
      if (_loadFailed && !_baselineReady) ...[
        ..._loadFailure(l10n),
        gap,
      ] else
        const HermesSecretsErrorBanner(),
      if (!widget.isOnboarding &&
          !_addingInSheet &&
          existing &&
          !editsActive) ...[
        InsetGroupedList(
          footer: l10n.hermesInactiveConnectionNotice,
          children: [
            UtilityRow(
              key: const ValueKey<String>('hermes-use-connection'),
              title: l10n.hermesUseConnection,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              foregroundColor: context.conduitTheme.buttonPrimary,
              enabled: !_switching && !controller.operation.isBusy,
              status: _switching
                  ? const AdaptiveProgressIndicator.activity(radius: 8)
                  : null,
              onTap: _switching ? null : _useConnection,
            ),
          ],
        ),
        gap,
      ],
      InsetGroupedSection(
        title: 'Hermes connection mode',
        flat: true,
        padding: EdgeInsets.zero,
        child: AdaptiveSegmentedControl(
          key: const ValueKey<String>('hermes-backend-mode-selector'),
          labels: const ['Responses API', 'Desktop Gateway'],
          selectedIndex: controller.mode == HermesBackendMode.responsesApi
              ? 0
              : 1,
          enabled: !controller.operation.isBusy,
          onValueChanged: (index) => controller.setMode(
            index == 0
                ? HermesBackendMode.responsesApi
                : HermesBackendMode.desktopGateway,
          ),
        ),
      ),
      gap,
      if (PlatformInfo.isIOS)
        InsetGroupedList(
          useNativeSurface: true,
          footer: widget.isOnboarding ? null : l10n.hermesConnectionNameHint,
          children: [
            if (!widget.isOnboarding) nameField,
            serverUrlField,
            if (controller.mode == HermesBackendMode.responsesApi)
              apiKeyField
            else if (controller.desktopAuthKind ==
                HermesDesktopAuthKind.legacyToken)
              desktopTokenField,
          ],
        )
      else
        InsetGroupedSection(
          title: l10n.hermesConnectionDetailsTitle,
          flat: true,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!widget.isOnboarding) ...[
                nameField,
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.xs),
                  child: Text(
                    l10n.hermesConnectionNameHint,
                    style: AppTypography.bodySmallStyle.copyWith(
                      color: context.conduitTheme.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.md),
              ],
              serverUrlField,
              if (controller.mode == HermesBackendMode.responsesApi) ...[
                const SizedBox(height: Spacing.md),
                apiKeyField,
              ] else if (controller.desktopAuthKind ==
                  HermesDesktopAuthKind.legacyToken) ...[
                const SizedBox(height: Spacing.md),
                desktopTokenField,
              ],
            ],
          ),
        ),
      if (controller.mode == HermesBackendMode.desktopGateway) ...[
        gap,
        HermesDesktopConnectionSection(
          controller: controller,
          savedConfig: _saved,
          editsActiveConnection: () => _editsActive,
          prepareSignIn: _prepareSignIn,
          testConnection: _testConnection,
          trackTokenWork: _trackTokenWork,
          signInFooter: widget.isOnboarding || editsActive
              ? null
              : l10n.hermesSignInActivatesConnection,
        ),
      ],
      gap,
      HermesTransportSection(controller: controller),
      if (controller.mode == HermesBackendMode.responsesApi) ...[
        gap,
        UtilityDisclosureSection(
          key: const ValueKey<String>('hermes-memory-key-disclosure'),
          title: l10n.hermesMemoryKeyTitle,
          subtitle: l10n.hermesMemoryKeyShortDescription,
          flat: !PlatformInfo.isIOS,
          useNativeSurface: PlatformInfo.isIOS,
          contentPadding: PlatformInfo.isIOS
              ? EdgeInsets.zero
              : const EdgeInsets.only(top: Spacing.md),
          expanded: controller.showMemoryKey,
          onChanged: controller.setShowMemoryKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AccessibleFormField(
                enabled: !controller.operation.isBusy,
                label: l10n.hermesMemoryKeyFieldLabel,
                hint: config.sessionKey == null || config.sessionKey!.isEmpty
                    ? l10n.hermesMemoryKeyPlaceholder
                    : l10n.hermesConfiguredReplacePlaceholder,
                obscureText: true,
                controller: controller.sessionKey,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                onChanged: (_) => controller.markSessionKeyChanged(),
                iosSettingsRow: PlatformInfo.isIOS,
              ),
              Padding(
                padding: PlatformInfo.isIOS
                    ? const EdgeInsets.fromLTRB(
                        Spacing.md,
                        Spacing.xs,
                        Spacing.md,
                        Spacing.md,
                      )
                    : const EdgeInsets.only(top: Spacing.sm),
                child: Text(
                  l10n.hermesMemoryKeyDescription,
                  style: AppTypography.bodySmallStyle.copyWith(
                    color: context.conduitTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      if (!widget.isOnboarding && !_embedded) ...[
        gap,
        if (PlatformInfo.isIOS)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InsetGroupedList(
                useNativeSurface: true,
                children: [
                  UtilityRow(
                    title: l10n.testDirectConnection,
                    titleFontWeight: FontWeight.w400,
                    foregroundColor: context.conduitTheme.buttonPrimary,
                    enabled: draftUsable,
                    status:
                        controller.operation ==
                            HermesConnectionOperation.testing
                        ? const CupertinoActivityIndicator(radius: 8)
                        : null,
                    onTap: draftUsable ? _testConnection : null,
                  ),
                ],
              ),
              if (controller.attempt.isVisible) ...[
                const SizedBox(height: Spacing.sm),
                ConnectionAttemptBanner(state: controller.attempt),
              ],
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConduitButton(
                text: l10n.testDirectConnection,
                isSecondary: true,
                isLoading:
                    controller.operation == HermesConnectionOperation.testing,
                isFullWidth: true,
                onPressed: draftUsable ? _testConnection : null,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                key: const ValueKey<String>('hermes-save-button'),
                text: l10n.save,
                isLoading:
                    controller.operation == HermesConnectionOperation.saving,
                isFullWidth: true,
                onPressed: draftUsable ? _saveSettings : null,
              ),
              if (controller.attempt.isVisible) ...[
                const SizedBox(height: Spacing.sm),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: ConnectionAttemptBanner(state: controller.attempt),
                ),
              ],
            ],
          ),
      ],
      if (editsActive &&
          !widget.isOnboarding &&
          !_embedded &&
          activeConfig.isUsable) ...[
        const SizedBox(height: Spacing.xl),
        const HermesCapabilitiesSection(),
        const SizedBox(height: Spacing.lg),
        const HermesToolsetsSection(),
        if (activeConfig.mode == HermesBackendMode.desktopGateway) ...[
          const SizedBox(height: Spacing.lg),
          const HermesDesktopManagementSection(),
        ],
        const SizedBox(height: Spacing.lg),
        const HermesServerStatusSection(),
      ],
      if (!widget.isOnboarding && !_addingInSheet && existing) ...[
        gap,
        InsetGroupedList(
          useNativeSurface: PlatformInfo.isIOS,
          children: [
            UtilityRow(
              key: const ValueKey<String>('hermes-delete-connection'),
              title: l10n.delete,
              titleFontWeight: PlatformInfo.isIOS ? FontWeight.w400 : null,
              destructive: true,
              enabled: !controller.operation.isBusy && !_switching,
              onTap: _delete,
            ),
          ],
        ),
      ],
    ];

    if (_embedded) {
      final busy = controller.operation.isBusy || _switching;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...content,
          const SizedBox(height: Spacing.lg),
          ConnectionAttemptBanner(state: controller.attempt),
          if (controller.attempt.isVisible) const SizedBox(height: Spacing.sm),
          ConduitButton(
            key: const ValueKey<String>('hermes-sheet-submit'),
            text: _addingInSheet ? l10n.hermesConnectAction : l10n.save,
            isFullWidth: true,
            isLoading: busy,
            onPressed: draftUsable && !busy
                ? (_addingInSheet ? _connectInSheet : _saveInSheet)
                : null,
          ),
        ],
      );
    }

    if (widget.isOnboarding) {
      return UtilityPageScaffold.auth(
        title: l10n.backendChooserHermesTitle,
        backNavigation: UtilityBackNavigation(
          label: l10n.back,
          buttonKey: const ValueKey<String>('hermes-onboarding-back-button'),
          onPressed: _leaveOnboarding,
        ),
        bottomAction: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConnectionAttemptBanner(state: controller.attempt),
            if (controller.attempt.isVisible)
              const SizedBox(height: Spacing.sm),
            ConduitButton(
              text: l10n.hermesConnectAction,
              isFullWidth: true,
              isLoading:
                  controller.operation == HermesConnectionOperation.finishing,
              onPressed: draftUsable ? _finishOnboarding : null,
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: content,
        ),
      );
    }

    final savedName = connectionNames
        .where((profile) => profile.id == controller.connectionId)
        .firstOrNull
        ?.name;
    return UtilityPageScaffold.settings(
      title: savedName ?? l10n.hermesNewConnectionTitle,
      trailing: PlatformInfo.isIOS
          ? CupertinoButton(
              key: const ValueKey<String>('hermes-save-toolbar-button'),
              padding: const EdgeInsets.symmetric(horizontal: Spacing.xs),
              minimumSize: const Size(0, TouchTarget.minimum),
              onPressed: draftUsable ? _saveSettings : null,
              child: controller.operation == HermesConnectionOperation.saving
                  ? const CupertinoActivityIndicator(radius: 8)
                  : Text(
                      l10n.save,
                      style: TextStyle(
                        color: draftUsable
                            ? context.conduitTheme.buttonPrimary
                            : context.conduitTheme.textDisabled,
                      ),
                    ),
            )
          : null,
      children: content,
    );
  }
}
