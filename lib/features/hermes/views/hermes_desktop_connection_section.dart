import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/utility_components.dart';
import '../controllers/hermes_connection_controller.dart';
import '../models/hermes_config.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_desktop_connection_coordinator.dart';
import '../services/hermes_desktop_api_service.dart';
import 'hermes_dashboard_auth_page.dart';

class HermesDesktopConnectionSection extends ConsumerStatefulWidget {
  const HermesDesktopConnectionSection({
    super.key,
    required this.controller,
    required this.saveSettings,
    required this.testConnection,
  });

  final HermesConnectionController controller;
  final Future<bool> Function() saveSettings;
  final Future<void> Function() testConnection;

  @override
  ConsumerState<HermesDesktopConnectionSection> createState() =>
      _HermesDesktopConnectionSectionState();
}

class _HermesDesktopConnectionSectionState
    extends ConsumerState<HermesDesktopConnectionSection> {
  static const _desktopConnection = HermesDesktopConnectionCoordinator();
  final _headerName = TextEditingController();
  final _headerValue = TextEditingController();
  List<String> _profiles = const [];
  String? _profilesError;
  String? _headerError;
  bool _profilesLoading = false;
  bool _showAccessHeaders = false;
  String? _lastOrigin;
  String? _lastProfileIdentity;
  final Object _credentialIdentitySalt = Object();
  int _recommendationEpoch = 0;
  int _profileEpoch = 0;

  HermesConnectionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _showAccessHeaders = _controller.accessHeaders.isNotEmpty;
    _lastOrigin = HermesConfig.connectionOrigin(_controller.url.text);
    _lastProfileIdentity = _authDraftIdentity(
      _controller.buildDraft(ref.read(hermesConfigProvider)).config,
    );
    _controller.addListener(_handleDraftChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_recommendAuthForNewConnection());
      unawaited(_loadProfiles());
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_handleDraftChanged);
    _headerName.dispose();
    _headerValue.dispose();
    super.dispose();
  }

  void _handleDraftChanged() {
    final origin = HermesConfig.connectionOrigin(_controller.url.text);
    if (origin != _lastOrigin) {
      _lastOrigin = origin;
      _recommendationEpoch++;
      unawaited(_recommendAuthForNewConnection(force: true));
    }
    final identity = _authDraftIdentity(
      _controller.buildDraft(ref.read(hermesConfigProvider)).config,
    );
    if (identity != _lastProfileIdentity) {
      _lastProfileIdentity = identity;
      _profileEpoch++;
      setState(() {
        _profiles = const [];
        _profilesError = null;
      });
      unawaited(_loadProfiles(force: true));
    }
  }

  String _authDraftIdentity(HermesConfig config) {
    final headers = config.accessHeaders.entries.toList()
      ..sort(
        (left, right) =>
            left.key.toLowerCase().compareTo(right.key.toLowerCase()),
      );
    final legacyMarker =
        config.desktopAuthKind == HermesDesktopAuthKind.legacyToken
        ? Object.hash(
            _credentialIdentitySalt,
            config.desktopCredentials?.legacyToken,
          )
        : 0;
    return '${HermesConfig.connectionOrigin(config.baseUrl)}\u0000'
        '${config.desktopAuthKind.name}\u0000'
        '$legacyMarker\u0000'
        '${headers.map((entry) => '${entry.key.toLowerCase()}=${entry.value}').join('\u0000')}';
  }

  Future<void> _loadProfiles({bool force = false}) async {
    if (_profilesLoading && !force) return;
    final draft = _controller.buildDraft(ref.read(hermesConfigProvider));
    if (HermesConfig.connectionOrigin(draft.config.baseUrl) == null) {
      if (!mounted) return;
      setState(() => _profilesError = 'Enter the Hermes server URL first.');
      return;
    }
    final identity = _authDraftIdentity(draft.config);
    final epoch = ++_profileEpoch;
    if (!mounted) return;
    setState(() {
      _profilesLoading = true;
      _profilesError = null;
    });
    try {
      final saved = ref.read(hermesConfigProvider);
      final live = ref.read(hermesApiServiceProvider);
      final profiles = await _desktopConnection.profiles(
        draft.config.copyWith(enabled: true),
        service: switch (live) {
          final HermesDesktopApiService service
              when hermesDesktopConnectionMatches(saved, draft.config) =>
            service,
          _ => null,
        },
        onCredentialsChanged: (credentials) async {
          final current = ref.read(hermesConfigProvider);
          if (!hermesDesktopConnectionMatches(current, draft.config)) {
            throw StateError(
              'Save the Hermes server before refreshing its sign-in.',
            );
          }
          await ref
              .read(hermesConfigProvider.notifier)
              .setDesktopNativeTokens(credentials.nativeTokens);
        },
      );
      final current = _controller
          .buildDraft(ref.read(hermesConfigProvider))
          .config;
      if (!mounted ||
          epoch != _profileEpoch ||
          _authDraftIdentity(current) != identity) {
        return;
      }
      if (profiles.isNotEmpty &&
          !profiles.contains(_controller.desktopProfile)) {
        _controller.setDesktopProfile(
          profiles.contains('default') ? 'default' : profiles.first,
        );
      }
      setState(() {
        _profiles = profiles;
        _profilesError = profiles.isEmpty
            ? 'No Hermes profiles were returned.'
            : null;
      });
    } catch (_) {
      final current = _controller
          .buildDraft(ref.read(hermesConfigProvider))
          .config;
      if (mounted &&
          epoch == _profileEpoch &&
          _authDraftIdentity(current) == identity) {
        setState(() {
          _profilesError = 'Sign in, then refresh the profile list.';
        });
      }
    } finally {
      if (mounted && epoch == _profileEpoch) {
        setState(() => _profilesLoading = false);
      }
    }
  }

  Future<void> _recommendAuthForNewConnection({bool force = false}) async {
    final saved = ref.read(hermesConfigProvider);
    if (!force && saved.mode == HermesBackendMode.desktopGateway) return;
    final draft = _controller.buildDraft(saved).config.copyWith(enabled: true);
    if (HermesConfig.connectionOrigin(draft.baseUrl) == null) return;
    final identity = _authDraftIdentity(draft);
    final epoch = ++_recommendationEpoch;
    try {
      final recommended = await _desktopConnection.recommendedAuth(draft);
      final current = _controller
          .buildDraft(ref.read(hermesConfigProvider))
          .config
          .copyWith(enabled: true);
      if (mounted &&
          epoch == _recommendationEpoch &&
          _authDraftIdentity(current) == identity) {
        _controller.setDesktopAuthKind(recommended);
      }
    } catch (_) {
      // Connection testing will surface the actionable server error.
    }
  }

  void _addAccessHeader() {
    final name = _headerName.text.trim();
    if (name.isEmpty) return;
    final error = _controller.setAccessHeaders({
      ..._controller.accessHeaders,
      name: _headerValue.text,
    });
    setState(() {
      _headerError = error;
      if (error == null) {
        _headerName.clear();
        _headerValue.clear();
        if (_controller.desktopAuthKind == HermesDesktopAuthKind.nativePkce) {
          _controller.setDesktopAuthKind(HermesDesktopAuthKind.dashboardCookie);
        }
      }
    });
  }

  void _removeAccessHeader(String name) {
    _controller.setAccessHeaders({..._controller.accessHeaders}..remove(name));
    setState(() => _headerError = null);
  }

  Future<void> _signInNative() async {
    if (!await widget.saveSettings()) return;
    final saved = ref.read(hermesConfigProvider);
    if (saved.mode != HermesBackendMode.desktopGateway) return;
    try {
      final live = ref.read(hermesApiServiceProvider);
      await _desktopConnection.signInNative(
        saved.copyWith(enabled: true),
        onCredentialsChanged: (credentials) => ref
            .read(hermesConfigProvider.notifier)
            .setDesktopNativeTokens(credentials.nativeTokens),
        service: live is HermesDesktopApiService ? live : null,
      );
      if (mounted) {
        await _loadProfiles();
        await widget.testConnection();
      }
    } catch (error) {
      DebugLogger.warning(
        'Native Hermes sign-in failed',
        scope: 'hermes/desktop/auth',
        data: {'errorType': error.runtimeType.toString()},
      );
      _controller.reportFailure(
        'Hermes sign-in failed or was cancelled. Check that native PKCE is enabled and try again.',
      );
    }
  }

  Future<void> _signInDashboard() async {
    if (!await widget.saveSettings() || !mounted) return;
    final config = ref.read(hermesConfigProvider);
    final signedIn = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            HermesDashboardAuthPage(config: config.copyWith(enabled: true)),
      ),
    );
    if (mounted && signedIn == true) {
      ref.invalidate(hermesDesktopModelsProvider);
      await _loadProfiles();
      await widget.testConnection();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final gatewayStopped =
        ref
            .watch(hermesServerStatusProvider)
            .asData
            ?.value['gateway_running'] ==
        false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (gatewayStopped) ...[
          UtilityStatusBanner(
            message: l10n.hermesGatewayStopped,
            tone: UtilityStatusTone.warning,
          ),
          SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
        ],
        InsetGroupedSection(
          title: l10n.hermesProfile,
          footer: _profilesError,
          flat: !PlatformInfo.isIOS,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveDropdownField<String>(
                value: _controller.desktopProfile,
                options: {_controller.desktopProfile, ..._profiles}
                    .map(
                      (profile) => AdaptiveDropdownOption<String>(
                        value: profile,
                        label: profile,
                      ),
                    )
                    .toList(growable: false),
                onChanged: _controller.operation.isBusy
                    ? null
                    : _controller.setDesktopProfile,
                decoration: InputDecoration(labelText: l10n.hermesProfileLabel),
                nativeTitle: l10n.hermesProfile,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                text: l10n.hermesRefreshProfiles,
                isSecondary: true,
                isLoading: _profilesLoading,
                onPressed: _profilesLoading ? null : _loadProfiles,
              ),
            ],
          ),
        ),
        SizedBox(height: PlatformInfo.isIOS ? Spacing.md : Spacing.lg),
        InsetGroupedSection(
          title: l10n.hermesDesktopAuthentication,
          footer:
              _controller.desktopAuthKind ==
                  HermesDesktopAuthKind.dashboardCookie
              ? l10n.hermesDashboardAuthHelp
              : null,
          flat: !PlatformInfo.isIOS,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdaptiveSegmentedControl(
                key: const ValueKey<String>('hermes-desktop-auth-selector'),
                labels: [
                  l10n.hermesAuthLegacy,
                  l10n.hermesAuthNative,
                  l10n.hermesAuthDashboard,
                ],
                selectedIndex: _controller.desktopAuthKind.index,
                enabled: !_controller.operation.isBusy,
                onValueChanged: (index) => _controller.setDesktopAuthKind(
                  HermesDesktopAuthKind.values[index],
                ),
              ),
              if (_controller.desktopAuthKind ==
                  HermesDesktopAuthKind.nativePkce) ...[
                const SizedBox(height: Spacing.md),
                ConduitButton(
                  key: const ValueKey<String>('hermes-native-sign-in'),
                  text: l10n.hermesNativeSignIn,
                  isSecondary: true,
                  isFullWidth: true,
                  onPressed: _controller.operation.isBusy
                      ? null
                      : _signInNative,
                ),
              ],
              if (_controller.desktopAuthKind ==
                  HermesDesktopAuthKind.dashboardCookie) ...[
                const SizedBox(height: Spacing.md),
                ConduitButton(
                  key: const ValueKey<String>('hermes-dashboard-sign-in'),
                  text: l10n.hermesDashboardSignIn,
                  isSecondary: true,
                  isFullWidth: true,
                  onPressed: _controller.operation.isBusy
                      ? null
                      : _signInDashboard,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        UtilityDisclosureSection(
          key: const ValueKey<String>('hermes-access-headers-disclosure'),
          title: l10n.hermesGatewayAccessHeaders,
          subtitle: l10n.hermesGatewayAccessHeadersHelp,
          leading: Icon(
            context.usesCupertinoChrome
                ? CupertinoIcons.gear_alt
                : Icons.tune_rounded,
            color: theme.iconSecondary,
            size: IconSize.medium,
          ),
          expanded: _showAccessHeaders,
          onChanged: (value) => setState(() => _showAccessHeaders = value),
          flat: !PlatformInfo.isIOS,
          useNativeSurface: PlatformInfo.isIOS,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AccessibleFormField(
                label: 'Header name',
                controller: _headerName,
                autocorrect: false,
                errorText: _headerError,
              ),
              const SizedBox(height: Spacing.sm),
              AccessibleFormField(
                label: 'Header value',
                controller: _headerValue,
                obscureText: true,
                autocorrect: false,
              ),
              const SizedBox(height: Spacing.sm),
              ConduitButton(
                text: 'Add header',
                isSecondary: true,
                onPressed:
                    _controller.accessHeaders.length >=
                        HermesConfig.maxAccessHeaders
                    ? null
                    : _addAccessHeader,
              ),
              for (final entry in _controller.accessHeaders.entries)
                UtilityRow(
                  title: entry.key,
                  subtitle: '••••••',
                  trailing: ConduitIconButton(
                    icon: Icons.close,
                    tooltip: 'Remove header',
                    onPressed: () => _removeAccessHeader(entry.key),
                    isCompact: true,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
