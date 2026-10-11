import 'package:conduit_core/auth/openwebui_two_step.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:conduit/l10n/app_localizations.dart';

import '../../../core/services/haptic_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/connection_components.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/utility_components.dart';

/// The second step of an Open WebUI sign-in with two-step verification
/// (Open WebUI 0.12): a code from the account's authenticator app or one of
/// its recovery codes, adding an authenticator on the first sign-in since it
/// became required, or an administrator's recovery token after a reset.
///
/// Mirrors the web client's sign-in step. Adding an authenticator ends on the
/// account's new recovery codes, which the server shows only once, before the
/// session is signed in to.
class OpenWebUiTwoStepForm extends ConsumerStatefulWidget {
  const OpenWebUiTwoStepForm({
    super.key,
    required this.challenge,
    required this.account,
    required this.onCancel,
    required this.mayFinish,
    required this.formatSignInError,
  });

  final OpenWebUiTwoStepChallenge challenge;

  /// The username the sign-in began with, to label the authenticator entry.
  final String account;

  /// Returns to the sign-in form.
  final VoidCallback onCancel;

  /// Whether the server the sign-in began on is still the one to sign in to.
  final Future<bool> Function() mayFinish;

  /// The sign-in page's message for a failed sign-in.
  final String Function(String error) formatSignInError;

  @override
  ConsumerState<OpenWebUiTwoStepForm> createState() =>
      _OpenWebUiTwoStepFormState();
}

class _OpenWebUiTwoStepFormState extends ConsumerState<OpenWebUiTwoStepForm> {
  late OpenWebUiTwoStepChallenge _challenge = widget.challenge;
  final TextEditingController _code = TextEditingController();
  OpenWebUiTwoStepSetup? _setup;
  bool _loadingSetup = false;
  bool _recovery = false;
  bool _busy = false;
  String? _error;

  /// A session issued with new recovery codes, signed in to once the user
  /// has seen them.
  OpenWebUiTwoStepSession? _issued;

  bool get _enrolling => _challenge.kind == OpenWebUiTwoStepKind.enroll;
  bool get _redeeming => _challenge.kind == OpenWebUiTwoStepKind.recover;

  @override
  void initState() {
    super.initState();
    _code.addListener(_onCodeChanged);
    if (_enrolling) _loadSetup();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    if (!mounted) return;
    setState(() {
      if (!_busy) _error = null;
    });
  }

  Future<void> _loadSetup() async {
    if (!_enrolling || _loadingSetup) return;
    setState(() {
      _loadingSetup = true;
      _error = null;
    });
    try {
      final setup = await ref
          .read(authActionsProvider)
          .startTwoStepEnrollment(_challenge);
      if (mounted) setState(() => _setup = setup);
    } catch (error) {
      if (mounted) setState(() => _error = _failureText(error));
    } finally {
      if (mounted) setState(() => _loadingSetup = false);
    }
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (_busy || code.isEmpty || (_enrolling && _setup == null)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final actions = ref.read(authActionsProvider);
    try {
      if (_redeeming) {
        final next = await actions.redeemTwoStepResetToken(_challenge, code);
        if (!mounted) return;
        _code.clear();
        setState(() {
          _challenge = next;
          _setup = null;
        });
        await _loadSetup();
        return;
      }
      final session = await actions.submitTwoStepCode(
        _challenge,
        code,
        recovery: _recovery,
      );
      if (!mounted) return;
      _code.clear();
      if (session.recoveryCodes.isNotEmpty) {
        setState(() => _issued = session);
        return;
      }
      await _finish(session);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _failureText(error));
      ConduitHaptics.error();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishIssued() async {
    final session = _issued;
    if (_busy || session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _finish(session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Signs in with [session]. Navigation follows the auth state.
  Future<void> _finish(OpenWebUiTwoStepSession session) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      if (!await widget.mayFinish()) {
        throw StateError('The selected server changed before sign-in.');
      }
      final signedIn = await ref
          .read(authActionsProvider)
          .finishTwoStepSignIn(session);
      if (!mounted) return;
      if (signedIn) {
        ConduitHaptics.success();
      } else {
        setState(() => _error = l10n.genericSignInFailed);
      }
    } catch (error) {
      DebugLogger.error(
        'two-step-finish-failed',
        scope: 'auth/page',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      setState(() => _error = widget.formatSignInError(error.toString()));
      ConduitHaptics.error();
    }
  }

  String _failureText(Object error) {
    final l10n = AppLocalizations.of(context)!;
    if (error is! OpenWebUiTwoStepException) return l10n.twoStepFailed;
    return switch (error.failure) {
      OpenWebUiTwoStepFailure.invalidCode => l10n.twoStepInvalidCode,
      OpenWebUiTwoStepFailure.expired => l10n.twoStepExpired,
      OpenWebUiTwoStepFailure.tooManyAttempts => l10n.twoStepTooManyAttempts,
      OpenWebUiTwoStepFailure.failed => l10n.twoStepFailed,
    };
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

  Future<void> _openAuthenticator(OpenWebUiTwoStepSetup setup) async {
    var opened = false;
    try {
      opened = await launchUrl(
        setup.authenticatorUri(account: widget.account),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    if (opened || !mounted) return;
    AdaptiveSnackBar.show(
      context,
      message: AppLocalizations.of(context)!.twoStepNoAuthenticatorApp,
      type: AdaptiveSnackBarType.warning,
    );
  }

  @override
  Widget build(BuildContext context) {
    final issued = _issued;
    return issued != null ? _buildRecoveryCodes(issued) : _buildStep();
  }

  Widget _buildStep() {
    final l10n = AppLocalizations.of(context)!;
    final title = switch (_challenge.kind) {
      OpenWebUiTwoStepKind.verify => l10n.twoStepVerifyTitle,
      OpenWebUiTwoStepKind.enroll => l10n.twoStepEnrollTitle,
      OpenWebUiTwoStepKind.recover => l10n.twoStepRecoverTitle,
    };
    final description = switch (_challenge.kind) {
      OpenWebUiTwoStepKind.verify =>
        _recovery
            ? l10n.twoStepRecoveryCodeDescription
            : l10n.twoStepVerifyDescription,
      OpenWebUiTwoStepKind.enroll => l10n.twoStepEnrollDescription,
      OpenWebUiTwoStepKind.recover => l10n.twoStepRecoverDescription,
    };
    final label = _redeeming
        ? l10n.twoStepResetTokenLabel
        : _recovery
        ? l10n.twoStepRecoveryCodeLabel
        : l10n.twoStepCodeLabel;
    final numeric = !_redeeming && !_recovery;
    final error = _error;

    return Column(
      key: const ValueKey<String>('two-step-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIntro(title, description),
        if (_enrolling) ...[
          const SizedBox(height: Spacing.lg),
          _buildSetup(),
        ],
        const SizedBox(height: Spacing.lg),
        InsetGroupedSection(
          flat: true,
          child: AccessibleFormField(
            key: const ValueKey<String>('two-step-code-field'),
            label: label,
            controller: _code,
            keyboardType: numeric ? TextInputType.number : TextInputType.text,
            autofillHints: _redeeming
                ? null
                : const [AutofillHints.oneTimeCode],
            autocorrect: false,
            autofocus: true,
            readOnly: _busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: Spacing.md),
          ConnectionAttemptBanner(state: ConnectionAttemptState.failed(error)),
        ],
        const SizedBox(height: Spacing.lg),
        ConduitButton(
          key: const ValueKey<String>('two-step-continue'),
          text: l10n.continueAction,
          onPressed:
              _busy ||
                  _code.text.trim().isEmpty ||
                  (_enrolling && _setup == null)
              ? null
              : _submit,
          isLoading: _busy,
          isFullWidth: true,
        ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ConduitTextButton(
              key: const ValueKey<String>('two-step-back'),
              text: l10n.twoStepBackToSignIn,
              onPressed: _busy ? null : widget.onCancel,
            ),
            if (_challenge.kind == OpenWebUiTwoStepKind.verify)
              ConduitTextButton(
                key: const ValueKey<String>('two-step-toggle-recovery'),
                text: _recovery
                    ? l10n.twoStepUseAuthenticatorCode
                    : l10n.twoStepUseRecoveryCode,
                onPressed: _busy
                    ? null
                    : () {
                        _code.clear();
                        setState(() {
                          _recovery = !_recovery;
                          _error = null;
                        });
                      },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildIntro(String title, String description) {
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: theme.headingSmall?.copyWith(color: theme.textPrimary),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          description,
          style: theme.bodyMedium?.copyWith(
            color: theme.textSecondary,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildSetup() {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final setup = _setup;
    if (setup == null) {
      if (_loadingSetup) {
        return Text(
          l10n.twoStepSetupLoading,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        );
      }
      return Row(
        children: [
          Expanded(
            child: Text(
              l10n.twoStepSetupFailed,
              style: theme.bodySmall?.copyWith(color: theme.textSecondary),
            ),
          ),
          ConduitTextButton(
            key: const ValueKey<String>('two-step-retry-setup'),
            text: l10n.retry,
            onPressed: _loadSetup,
          ),
        ],
      );
    }

    final svg = setup.qrSvg;
    return Column(
      key: const ValueKey<String>('two-step-setup'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConduitButton(
          key: const ValueKey<String>('two-step-open-authenticator'),
          text: l10n.twoStepOpenAuthenticator,
          isSecondary: true,
          isFullWidth: true,
          onPressed: () => _openAuthenticator(setup),
        ),
        if (svg != null) ...[
          const SizedBox(height: Spacing.lg),
          Center(
            child: Semantics(
              label: l10n.twoStepQrCodeLabel,
              image: true,
              child: Container(
                // Scanners need the code dark on light, in either theme.
                color: const Color(0xFFFFFFFF),
                padding: const EdgeInsets.all(Spacing.sm),
                child: SvgPicture.string(svg, width: 160, height: 160),
              ),
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        Text(
          l10n.twoStepSetupKeyLabel,
          style: theme.bodySmall?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                _groupedKey(setup.manualKey),
                key: const ValueKey<String>('two-step-setup-key'),
                style: theme.bodyMedium?.copyWith(
                  color: theme.textPrimary,
                  fontFamily: AppTypography.monospaceFontFamily,
                ),
              ),
            ),
            ConduitIconButton(
              icon: context.usesCupertinoChrome
                  ? CupertinoIcons.doc_on_doc
                  : Icons.copy_rounded,
              iconColor: theme.iconSecondary,
              tooltip: l10n.twoStepCopySetupKey,
              onPressed: () => _copy(setup.manualKey),
              isCompact: true,
            ),
          ],
        ),
      ],
    );
  }

  /// The key in groups of four, as authenticator apps show it.
  static String _groupedKey(String key) => key
      .replaceAllMapped(RegExp('.{1,4}'), (match) => '${match[0]} ')
      .trim();

  Widget _buildRecoveryCodes(OpenWebUiTwoStepSession session) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final codes = session.recoveryCodes.join('\n');
    final error = _error;
    return Column(
      key: const ValueKey<String>('two-step-recovery-codes'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildIntro(
          l10n.twoStepRecoveryCodesTitle,
          l10n.twoStepRecoveryCodesDescription,
        ),
        const SizedBox(height: Spacing.lg),
        InsetGroupedSection(
          flat: true,
          child: Text(
            codes,
            style: theme.bodyMedium?.copyWith(
              color: theme.textPrimary,
              fontFamily: AppTypography.monospaceFontFamily,
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
        ConduitButton(
          key: const ValueKey<String>('two-step-copy-recovery-codes'),
          text: l10n.twoStepCopyRecoveryCodes,
          isSecondary: true,
          isFullWidth: true,
          onPressed: () => _copy(codes),
        ),
        if (error != null) ...[
          const SizedBox(height: Spacing.md),
          ConnectionAttemptBanner(state: ConnectionAttemptState.failed(error)),
        ],
        const SizedBox(height: Spacing.lg),
        ConduitButton(
          key: const ValueKey<String>('two-step-continue'),
          text: l10n.continueAction,
          onPressed: _busy ? null : _finishIssued,
          isLoading: _busy,
          isFullWidth: true,
        ),
      ],
    );
  }
}
