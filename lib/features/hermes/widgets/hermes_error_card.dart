import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit/shared/widgets/platform_ui/vocabulary.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show startNewChat;
import 'package:conduit_core/features/hermes/models/hermes_error_surface.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/providers/app_providers.dart'
    show
        activeConversationProvider,
        isManualModelSelectionProvider,
        selectedModelProvider;

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/external_link_launcher.dart';
import '../../../shared/widgets/conduit_components.dart';
import 'hermes_context_usage_sheet.dart';

/// A failed Hermes turn: what broke, whether the chat is blocked or can go
/// on, when a limit resets, and the one action that helps.
class HermesErrorCard extends ConsumerStatefulWidget {
  const HermesErrorCard({
    super.key,
    required this.surface,
    required this.errorText,
    this.onRetry,
    this.onContinue,
  });

  final HermesErrorSurface surface;

  /// The turn's own error text, shown when Hermes wrote no sentence.
  final String? errorText;

  /// Runs the failed turn again; null hides Retry.
  final VoidCallback? onRetry;

  /// Asks the model to go on with a cut-off reply; null hides Continue.
  final FutureOr<void> Function()? onContinue;

  @override
  ConsumerState<HermesErrorCard> createState() => _HermesErrorCardState();
}

class _HermesErrorCardState extends ConsumerState<HermesErrorCard> {
  bool _busy = false;

  HermesErrorSurface get _surface => widget.surface;

  /// The open chat's stored Hermes session, for Compact.
  String? get _sessionId {
    final conversation = ref.read(activeConversationProvider);
    if (!isNativeHermesConversation(conversation)) return null;
    final id = conversation?.metadata['hermesSessionId']?.toString();
    return id == null || id.isEmpty ? null : id;
  }

  /// Whether this card can perform [action] here.
  bool _canPerform(HermesErrorAction action) => switch (action) {
    HermesErrorAction.retry => widget.onRetry != null,
    HermesErrorAction.continueReply => widget.onContinue != null,
    HermesErrorAction.compact =>
      _sessionId != null &&
          ref.read(hermesApiServiceProvider) is HermesDesktopApiService,
    HermesErrorAction.switchModel =>
      widget.onRetry != null && _surface.suggestions.isNotEmpty,
    HermesErrorAction.useCredits =>
      widget.onRetry != null &&
          ref.read(hermesApiServiceProvider) is HermesDesktopApiService,
    HermesErrorAction.openProviderSettings ||
    HermesErrorAction.openBilling ||
    HermesErrorAction.newChat => true,
  };

  String _label(AppLocalizations l10n, HermesErrorAction action) =>
      switch (action) {
        HermesErrorAction.retry => l10n.retry,
        HermesErrorAction.continueReply => l10n.hermesErrorContinue,
        HermesErrorAction.compact => l10n.hermesErrorCompact,
        HermesErrorAction.switchModel => l10n.hermesErrorSwitchModel(
          _surface.suggestions.first.label,
        ),
        HermesErrorAction.openProviderSettings =>
          l10n.hermesErrorOpenProviderSettings(_surface.providerName ?? ''),
        HermesErrorAction.openBilling => l10n.hermesErrorOpenBilling,
        HermesErrorAction.useCredits => l10n.hermesErrorUseCredits,
        HermesErrorAction.newChat => l10n.newChat,
      };

  Future<void> _perform(HermesErrorAction action) async {
    if (_busy) return;
    setState(() => _busy = true);
    var done = true;
    try {
      done = await _run(action);
    } catch (_) {
      done = false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!done && mounted) {
      AdaptiveSnackBar.show(
        context,
        message: AppLocalizations.of(context)!.hermesErrorActionFailed,
        type: AdaptiveSnackBarType.error,
      );
    }
  }

  /// Runs [action]; false when it could not.
  Future<bool> _run(HermesErrorAction action) async {
    switch (action) {
      case HermesErrorAction.retry:
        widget.onRetry?.call();
        return true;
      case HermesErrorAction.continueReply:
        await widget.onContinue?.call();
        return true;
      case HermesErrorAction.compact:
        final sessionId = _sessionId;
        if (sessionId == null) return false;
        await showHermesContextUsageSheet(context, sessionId: sessionId);
        return true;
      case HermesErrorAction.switchModel:
        return _switchModelAndRetry(_surface.suggestions.first);
      case HermesErrorAction.openProviderSettings:
        final url = _surface.providerSettingsUrl;
        return url != null && await launchExternalLink(url);
      case HermesErrorAction.openBilling:
        final url = _surface.billingPageUrl;
        return url != null && await launchExternalLink(url);
      case HermesErrorAction.useCredits:
        final service = ref.read(hermesApiServiceProvider);
        if (service is! HermesDesktopApiService) return false;
        if (await service.keepGoingOnCredits()) {
          widget.onRetry?.call();
          return true;
        }
        // Without billing access the account's billing page can still do it.
        final url = _surface.billingPageUrl;
        return url != null && await launchExternalLink(url);
      case HermesErrorAction.newChat:
        startNewChat(ref);
        return true;
    }
  }

  /// Picks [suggestion] as the chat's model, then runs the turn again on it.
  Future<bool> _switchModelAndRetry(HermesModelSuggestion suggestion) async {
    final models = await ref.read(hermesDesktopModelsProvider.future);
    if (!mounted) return false;
    final Model model = models.firstWhere(
      (model) =>
          model.metadata?['hermesModelId'] == suggestion.model &&
          model.metadata?['hermesProvider'] == suggestion.provider,
      orElse: () => hermesDesktopModel(
        modelId: suggestion.model,
        name: suggestion.label,
        provider: suggestion.provider,
      ),
    );
    ref.read(selectedModelProvider.notifier).set(model);
    ref.read(isManualModelSelectionProvider.notifier).set(true);
    widget.onRetry?.call();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    final surface = _surface;
    final blocking = surface.severityAt(now) == HermesErrorSeverity.blocking;
    final action = surface.actionAt(now);
    final reset = surface.upcomingResetAt(now);
    final accent = blocking ? theme.error : theme.textSecondary;
    final body = surface.message ?? widget.errorText;
    final identity = [?surface.providerName, ?surface.model].join(' · ');
    final detail = AppTypography.bodySmallStyle.copyWith(
      color: theme.textSecondary,
    );
    return Container(
      key: const ValueKey<String>('hermes-error-card'),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: blocking
            ? theme.error.withValues(alpha: 0.08)
            : theme.cardBackground,
        border: Border.all(
          color: blocking
              ? theme.error.withValues(alpha: 0.25)
              : theme.cardBorder,
        ),
        borderRadius: BorderRadius.circular(Spacing.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_icon(surface.kind), size: IconSize.medium, color: accent),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _title(l10n, surface.kind),
                      style: AppTypography.standard.copyWith(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      blocking
                          ? l10n.hermesErrorBlocking
                          : l10n.hermesErrorDegraded,
                      style: AppTypography.bodySmallStyle.copyWith(
                        color: accent,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (identity.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              identity,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodySmallStyle.copyWith(
                color: theme.textTertiary,
              ),
            ),
          ],
          if (body != null && body.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Text(body, style: detail),
          ],
          if (surface.partial) ...[
            const SizedBox(height: Spacing.xs),
            Text(l10n.hermesErrorPartialKept, style: detail),
          ],
          if (reset != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.hermesErrorResetsAt(formatHermesMoment(context, reset)),
              style: detail.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
          if (action != null && _canPerform(action)) ...[
            const SizedBox(height: Spacing.sm),
            ConduitButton(
              key: ValueKey<String>('hermes-error-action-${action.name}'),
              text: _label(l10n, action),
              isSecondary: true,
              isCompact: true,
              isLoading: _busy,
              onPressed: () => unawaited(_perform(action)),
            ),
          ],
        ],
      ),
    );
  }
}

String _title(AppLocalizations l10n, HermesErrorKind kind) => switch (kind) {
  HermesErrorKind.provider => l10n.hermesErrorProvider,
  HermesErrorKind.endpoint => l10n.hermesErrorEndpoint,
  HermesErrorKind.connection => l10n.hermesErrorConnection,
  HermesErrorKind.auth => l10n.hermesErrorAuth,
  HermesErrorKind.billing => l10n.hermesErrorBilling,
  HermesErrorKind.usageLimit => l10n.hermesErrorUsageLimit,
  HermesErrorKind.freeTier => l10n.hermesErrorFreeTier,
  HermesErrorKind.rateLimit => l10n.hermesErrorRateLimit,
  HermesErrorKind.contextOverflow => l10n.hermesErrorContextOverflow,
  HermesErrorKind.model => l10n.hermesErrorModel,
  HermesErrorKind.policy => l10n.hermesErrorPolicy,
  HermesErrorKind.truncated => l10n.hermesErrorTruncated,
  HermesErrorKind.badReply => l10n.hermesErrorBadReply,
  HermesErrorKind.workspace => l10n.hermesErrorWorkspace,
  HermesErrorKind.session => l10n.hermesErrorSession,
  HermesErrorKind.busy => l10n.hermesErrorBusy,
  HermesErrorKind.gateway => l10n.hermesErrorGateway,
  HermesErrorKind.disk => l10n.hermesErrorDisk,
  HermesErrorKind.unknown => l10n.hermesErrorUnknown,
};

IconData _icon(HermesErrorKind kind) => switch (kind) {
  HermesErrorKind.provider || HermesErrorKind.endpoint => Icons.cloud_off,
  HermesErrorKind.connection => Icons.wifi_off,
  HermesErrorKind.auth => Icons.key,
  HermesErrorKind.billing => Icons.credit_card,
  HermesErrorKind.usageLimit => Icons.hourglass_bottom,
  HermesErrorKind.freeTier => Icons.card_giftcard,
  HermesErrorKind.rateLimit => Icons.speed,
  HermesErrorKind.contextOverflow => Icons.data_usage_rounded,
  HermesErrorKind.model => Icons.smart_toy_outlined,
  HermesErrorKind.policy => Icons.block,
  HermesErrorKind.truncated => Icons.content_cut,
  HermesErrorKind.badReply => Icons.report_outlined,
  HermesErrorKind.workspace => Icons.folder_off_outlined,
  HermesErrorKind.session => Icons.lock_outline,
  HermesErrorKind.busy => Icons.hourglass_empty,
  HermesErrorKind.disk => Icons.storage,
  HermesErrorKind.gateway || HermesErrorKind.unknown => Icons.error_outline,
};
