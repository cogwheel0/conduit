import 'package:conduit_core/auth/browser_sign_in/browser_sign_in_service.dart';
import 'package:conduit_core/auth/oidc/oidc.dart';
import 'package:conduit_core/models/browser_sign_in_config.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import '../utils/browser_sign_in_messages.dart';

/// Checks a config against the server: the Test button.
typedef BrowserSignInTester = Future<BrowserSignInDiagnosis> Function(
  BrowserSignInConfig config,
);

/// The settings for signing a server's accounts in through the system
/// browser: which of the server's providers, and the client registered for
/// Conduit at its identity provider. Shared by every account on the server.
///
/// Saving and removing are the caller's: a server being added keeps its
/// config on the sign-in page until its first sign-in saves the server.
class BrowserSignInSettingsSheet extends StatefulWidget {
  const BrowserSignInSettingsSheet({
    super.key,
    required this.providers,
    required this.providerLabel,
    required this.onTest,
    required this.onSave,
    this.initial,
    this.onRemove,
    this.revealIssuer = false,
  });

  /// The server's providers a browser sign-in works with, in its order.
  final List<String> providers;

  /// The name the server gives [provider].
  final String Function(String provider) providerLabel;

  final BrowserSignInTester onTest;
  final Future<void> Function(BrowserSignInConfig config) onSave;

  /// The saved config, if any.
  final BrowserSignInConfig? initial;

  /// Removes the saved config; null when there is none to remove.
  final Future<void> Function()? onRemove;

  /// Shows the issuer field from the start, as after a sign-in that could
  /// not find the identity provider.
  final bool revealIssuer;

  static Future<void> show(
    BuildContext context, {
    required List<String> providers,
    required String Function(String provider) providerLabel,
    required BrowserSignInTester onTest,
    required Future<void> Function(BrowserSignInConfig config) onSave,
    BrowserSignInConfig? initial,
    Future<void> Function()? onRemove,
    bool revealIssuer = false,
  }) => ThemedSheets.showCustom<void>(
    context: context,
    builder: (_) => BrowserSignInSettingsSheet(
      providers: providers,
      providerLabel: providerLabel,
      onTest: onTest,
      onSave: onSave,
      initial: initial,
      onRemove: onRemove,
      revealIssuer: revealIssuer,
    ),
  );

  @override
  State<BrowserSignInSettingsSheet> createState() =>
      _BrowserSignInSettingsSheetState();
}

class _BrowserSignInSettingsSheetState
    extends State<BrowserSignInSettingsSheet> {
  late final TextEditingController _clientId = TextEditingController(
    text: widget.initial?.clientId ?? '',
  );
  late final TextEditingController _issuer = TextEditingController(
    text: widget.initial?.issuer ?? '',
  );
  late String _provider = _initialProvider();
  late bool _issuerRevealed =
      widget.revealIssuer || (widget.initial?.issuer?.isNotEmpty ?? false);

  bool _busy = false;
  BrowserSignInDiagnosis? _diagnosis;
  String? _error;

  String _initialProvider() {
    final initial = widget.initial?.provider;
    if (initial != null) return initial;
    return widget.providers.isEmpty ? 'oidc' : widget.providers.first;
  }

  /// The providers to choose from: the server's, and the saved one even when
  /// the server's are not known.
  List<String> get _providers => [
    ...widget.providers,
    if (!widget.providers.contains(_provider)) _provider,
  ];

  @override
  void initState() {
    super.initState();
    _clientId.addListener(_changed);
    _issuer.addListener(_changed);
  }

  @override
  void dispose() {
    _clientId.dispose();
    _issuer.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      _diagnosis = null;
      _error = null;
    });
  }

  /// The config the fields hold, or null with [_error] set when they do not
  /// hold one.
  BrowserSignInConfig? _config() {
    final l10n = AppLocalizations.of(context)!;
    final clientId = _clientId.text.trim();
    if (clientId.isEmpty) {
      setState(() => _error = l10n.validationMissingRequired);
      return null;
    }
    final issuer = normalizeBrowserSignInIssuer(_issuer.text);
    if (issuer.isNotEmpty) {
      final uri = Uri.tryParse(issuer);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        setState(() => _error = l10n.browserSignInErrorInvalidIssuer);
        return null;
      }
    }
    return BrowserSignInConfig(
      provider: _provider,
      clientId: clientId,
      issuer: issuer.isEmpty ? null : _issuer.text.trim(),
    );
  }

  Future<void> _test() async {
    final config = _config();
    if (config == null) return;
    setState(() {
      _busy = true;
      _diagnosis = null;
      _error = null;
    });
    try {
      final diagnosis = await widget.onTest(config);
      if (!mounted) return;
      setState(() {
        _diagnosis = diagnosis;
        final discovery = diagnosis.discoveryFailure;
        if (discovery != null && browserSignInNeedsIssuer(discovery)) {
          _issuerRevealed = true;
        }
      });
      if (diagnosis.ready) {
        ConduitHaptics.success();
      } else {
        ConduitHaptics.error();
      }
    } catch (error, stackTrace) {
      DebugLogger.error(
        'browser-sign-in-test-failed',
        scope: 'auth/browser',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _error = AppLocalizations.of(context)!.genericSignInFailed,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final config = _config();
    if (config == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSave(config);
      if (!mounted) return;
      ConduitHaptics.success();
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'browser-sign-in-settings-save-failed',
        scope: 'auth/browser',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _error = AppLocalizations.of(context)!.errorMessage;
        });
      }
    }
  }

  Future<void> _remove() async {
    final remove = widget.onRemove;
    if (remove == null) return;
    final l10n = AppLocalizations.of(context)!;
    var confirmed = false;
    await AdaptiveAlertDialog.show(
      context: context,
      title: l10n.browserSignInRemoveTitle,
      message: l10n.browserSignInRemoveMessage,
      actions: [
        AlertAction(
          title: l10n.cancel,
          style: AlertActionStyle.cancel,
          onPressed: () {},
        ),
        AlertAction(
          title: l10n.browserSignInRemove,
          style: AlertActionStyle.destructive,
          onPressed: () => confirmed = true,
        ),
      ],
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await remove();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      DebugLogger.error(
        'browser-sign-in-settings-remove-failed',
        scope: 'auth/browser',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _busy = false;
          _error = l10n.errorMessage;
        });
      }
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ConduitHaptics.selectionClick();
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.copiedToClipboard,
      type: AdaptiveSnackBarType.info,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;

    return AnimatedPadding(
      duration: context.motionDuration(AnimationDuration.fast),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ConduitModalSheetSurface(
          showHandle: false,
          padding: EdgeInsets.zero,
          child: Column(
            key: const ValueKey<String>('browser-sign-in-settings'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConduitModalSheetHeader(
                leading: Icon(
                  context.usesCupertinoChrome
                      ? CupertinoIcons.lock_shield
                      : Icons.key_outlined,
                  size: IconSize.md,
                  color: theme.iconSecondary,
                ),
                title: l10n.browserSignInSettingsTitle,
                titleStyle: theme.headingSmall ?? const TextStyle(),
                closeTooltip: l10n.close,
                onClose: () => Navigator.of(context).maybePop(),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(Spacing.modalPadding),
                  // The flat section is the material the list tiles ink on.
                  child: InsetGroupedSection(
                    flat: true,
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _buildBody(l10n, theme),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBody(AppLocalizations l10n, ConduitThemeExtension theme) {
    final secondary = theme.bodySmall?.copyWith(color: theme.textSecondary);
    final providers = _providers;
    final error = _error;
    final diagnosis = _diagnosis;
    return [
      Text(
        l10n.browserSignInSettingsDescription,
        style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
      ),
      const SizedBox(height: Spacing.xs),
      Text(
        l10n.browserSignInSharedNote,
        key: const ValueKey<String>('browser-sign-in-shared-note'),
        style: secondary,
      ),
      if (providers.length > 1) ...[
        const SizedBox(height: Spacing.lg),
        Text(l10n.browserSignInProvider, style: theme.label),
        const SizedBox(height: Spacing.xs),
        AdaptiveSegmentedControl(
          key: const ValueKey<String>('browser-sign-in-provider'),
          labels: [for (final p in providers) widget.providerLabel(p)],
          selectedIndex: providers.indexOf(_provider),
          enabled: !_busy,
          onValueChanged: (index) => setState(() {
            _provider = providers[index];
            _diagnosis = null;
            _error = null;
          }),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      AccessibleFormField(
        key: const ValueKey<String>('browser-sign-in-client-id'),
        label: l10n.browserSignInClientId,
        hint: l10n.browserSignInClientIdHint,
        controller: _clientId,
        enabled: !_busy,
        autocorrect: false,
        isRequired: true,
        textInputAction: TextInputAction.done,
      ),
      const SizedBox(height: Spacing.md),
      _buildRedirectUri(l10n, theme, secondary),
      const SizedBox(height: Spacing.md),
      if (_issuerRevealed)
        _buildIssuerField(l10n, secondary)
      else
        AdaptiveExpansionTile(
          key: const ValueKey<String>('browser-sign-in-advanced'),
          title: Text(l10n.browserSignInAdvanced),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: Spacing.sm),
          children: [_buildIssuerField(l10n, secondary)],
        ),
      if (diagnosis != null) ...[
        const SizedBox(height: Spacing.md),
        _buildDiagnosis(l10n, theme, diagnosis),
      ],
      if (error != null) ...[
        const SizedBox(height: Spacing.md),
        ConnectionAttemptBanner(state: ConnectionAttemptState.failed(error)),
      ],
      const SizedBox(height: Spacing.lg),
      Row(
        children: [
          Expanded(
            child: ConduitButton(
              key: const ValueKey<String>('browser-sign-in-test'),
              text: l10n.browserSignInTest,
              isSecondary: true,
              onPressed: _busy ? null : _test,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: ConduitButton(
              key: const ValueKey<String>('browser-sign-in-save'),
              text: l10n.save,
              isLoading: _busy,
              onPressed: _busy ? null : _save,
            ),
          ),
        ],
      ),
      if (widget.onRemove != null) ...[
        const SizedBox(height: Spacing.sm),
        Center(
          child: ConduitTextButton(
            key: const ValueKey<String>('browser-sign-in-remove'),
            text: l10n.browserSignInRemove,
            isDestructive: true,
            onPressed: _busy ? null : _remove,
          ),
        ),
      ],
      const SizedBox(height: Spacing.lg),
      _buildChecklist(l10n, theme, secondary),
    ];
  }

  Widget _buildRedirectUri(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    TextStyle? secondary,
  ) {
    final redirect = oidcRedirectUriFor(
      provider: _provider,
      clientId: _clientId.text,
    );
    if (redirect == null) {
      return Text(
        l10n.browserSignInGoogleClientIdHint,
        key: const ValueKey<String>('browser-sign-in-google-hint'),
        style: secondary,
      );
    }
    final value = redirect.toString();
    return AdaptiveListTile(
      key: const ValueKey<String>('browser-sign-in-redirect-uri'),
      padding: EdgeInsets.zero,
      hideBottomDivider: true,
      title: Text(l10n.browserSignInRedirectUri, style: theme.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: theme.code?.copyWith(color: theme.textPrimary)),
          const SizedBox(height: Spacing.xxs),
          Text(l10n.browserSignInRedirectUriDescription, style: secondary),
        ],
      ),
      trailing: Icon(
        context.usesCupertinoChrome ? CupertinoIcons.doc_on_doc : Icons.copy,
        size: IconSize.small,
        color: theme.iconSecondary,
      ),
      onTap: () => _copy(value),
    );
  }

  Widget _buildIssuerField(AppLocalizations l10n, TextStyle? secondary) {
    return Column(
      key: const ValueKey<String>('browser-sign-in-issuer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AccessibleFormField(
          label: l10n.browserSignInIssuer,
          hint: 'https://',
          controller: _issuer,
          enabled: !_busy,
          autocorrect: false,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: Spacing.xs),
        Text(l10n.browserSignInIssuerDescription, style: secondary),
      ],
    );
  }

  Widget _buildDiagnosis(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    BrowserSignInDiagnosis diagnosis,
  ) {
    final discovery = diagnosis.discoveryFailure;
    final exchange = diagnosis.exchangeFailure;
    final issuer = diagnosis.issuer;
    return Column(
      key: const ValueKey<String>('browser-sign-in-diagnosis'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _diagnosisRow(
          theme,
          key: const ValueKey<String>('browser-sign-in-diagnosis-idp'),
          title: l10n.browserSignInTestIdentityProvider,
          ok: discovery == null,
          detail: discovery == null
              ? (issuer == null ? null : l10n.browserSignInTestFound(issuer))
              : browserSignInFailureMessage(l10n, discovery),
        ),
        _diagnosisRow(
          theme,
          key: const ValueKey<String>('browser-sign-in-diagnosis-exchange'),
          title: l10n.browserSignInTestExchange,
          ok: exchange == null,
          detail: exchange == null
              ? l10n.browserSignInTestExchangeOn
              : browserSignInFailureMessage(l10n, exchange),
          last: true,
        ),
      ],
    );
  }

  Widget _diagnosisRow(
    ConduitThemeExtension theme, {
    required Key key,
    required String title,
    required bool ok,
    String? detail,
    bool last = false,
  }) {
    final icon = ok
        ? (context.usesCupertinoChrome
              ? CupertinoIcons.check_mark_circled_solid
              : Icons.check_circle)
        : (context.usesCupertinoChrome
              ? CupertinoIcons.exclamationmark_circle_fill
              : Icons.error);
    return AdaptiveListTile(
      key: key,
      padding: EdgeInsets.zero,
      hideBottomDivider: last,
      leading: Icon(
        icon,
        size: IconSize.md,
        color: ok ? theme.success : theme.error,
      ),
      title: Text(title),
      subtitle: detail == null
          ? null
          : Text(
              detail,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
    );
  }

  Widget _buildChecklist(
    AppLocalizations l10n,
    ConduitThemeExtension theme,
    TextStyle? secondary,
  ) {
    final items = [
      l10n.browserSignInChecklistExchange,
      // Open WebUI can limit token exchange to listed clients only by asking
      // the provider's introspection endpoint, which Google and Microsoft
      // don't have.
      if (_provider == 'google' || _provider == 'microsoft')
        l10n.browserSignInChecklistNoClientCheck
      else
        l10n.browserSignInChecklistTrustedClients,
      l10n.browserSignInChecklistClient,
      l10n.browserSignInChecklistUsers,
      if (_provider == 'microsoft') l10n.browserSignInChecklistMicrosoft,
      if (_provider == 'google') l10n.browserSignInChecklistGoogle,
      l10n.browserSignInChecklistClaims,
    ];
    return Column(
      key: const ValueKey<String>('browser-sign-in-checklist'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.browserSignInChecklistTitle, style: theme.label),
        const SizedBox(height: Spacing.xs),
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: secondary),
                Expanded(child: Text(item, style: secondary)),
              ],
            ),
          ),
      ],
    );
  }
}
