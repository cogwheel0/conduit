import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/backend_mode_providers.dart';
import '../../../core/services/navigation_service.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../auth/widgets/adaptive_auth_scaffold.dart';
import '../../direct_connections/providers/direct_connection_providers.dart';
import '../../profile/widgets/settings_page_scaffold.dart';
import '../chatgpt_account_adapter.dart';
import '../chatgpt_feature.dart';
import '../chatgpt_providers.dart';
import '../chatgpt_verification_browser.dart';
import '../native_generated/api/contract.dart' show DeviceCodeChallenge;

class ChatGptAccountPage extends ConsumerStatefulWidget {
  const ChatGptAccountPage({super.key, this.isOnboarding = false});

  final bool isOnboarding;

  @override
  ConsumerState<ChatGptAccountPage> createState() => _ChatGptAccountPageState();
}

class _ChatGptAccountPageState extends ConsumerState<ChatGptAccountPage> {
  Future<void>? _profileReconciliation;
  bool _scheduledInitialReconciliation = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connection = ref.watch(chatGptConnectionProvider);
    final profiles = ref.watch(directConnectionProfilesProvider);

    ref.listen(chatGptConnectionProvider, (previous, next) {
      if (next.value?.status == ChatGptConnectionStatus.authenticated) {
        unawaited(_ensureProfile());
      }
    });
    if (connection.value?.status == ChatGptConnectionStatus.authenticated &&
        profiles.value != null &&
        !_scheduledInitialReconciliation) {
      _scheduledInitialReconciliation = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensureProfile());
      });
    }

    final authenticated =
        connection.value?.status == ChatGptConnectionStatus.authenticated;
    final content = <Widget>[
      Text(
        l10n.chatGptAccountSubtitle,
        style: context.conduitTheme.bodyMedium?.copyWith(
          color: context.conduitTheme.textSecondary,
        ),
      ),
      const SizedBox(height: Spacing.lg),
      ChatGptAccountCard(
        connection: connection,
        onConnect: () => unawaited(_runAccountAction(_connect)),
        onCancelLogin: () => unawaited(
          _runAccountAction(
            () => ref.read(chatGptConnectionProvider.notifier).cancelLogin(),
          ),
        ),
        onReconnect: () => unawaited(
          _runAccountAction(
            () => ref.read(chatGptConnectionProvider.notifier).reconnect(),
          ),
        ),
        onDisconnect: () => unawaited(_disconnect()),
      ),
    ];

    if (widget.isOnboarding) {
      return AdaptiveAuthScaffold(
        title: l10n.chatGptAccountTitle,
        backLabel: l10n.back,
        backButtonKey: const ValueKey<String>('chatgpt-onboarding-back-button'),
        onBack: () => context.go(Routes.backendChooser),
        bottomAction: authenticated
            ? ConduitButton(
                key: const ValueKey<String>('finish-chatgpt-onboarding-button'),
                text: l10n.continueAction,
                isFullWidth: true,
                useNativeLabel: true,
                onPressed: () => unawaited(_finishOnboarding()),
              )
            : const SizedBox.shrink(),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: content,
        ),
      );
    }

    return SettingsPageScaffold(
      title: l10n.chatGptAccountTitle,
      children: content,
    );
  }

  Future<void> _connect() =>
      ref.read(chatGptConnectionProvider.notifier).connect();

  Future<void> _finishOnboarding() async {
    try {
      await _ensureProfile();
      await ref
          .read(preferredBackendProvider.notifier)
          .set(PreferredBackend.chatgpt);
      if (mounted) context.go(Routes.chat);
    } catch (error) {
      DebugLogger.error(
        'backend-activation-failed',
        scope: 'auth/chatgpt',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.directConnectionSaveFailed,
          isError: true,
        );
      }
    }
  }

  Future<void> _ensureProfile() async {
    final running = _profileReconciliation;
    if (running != null) return running;
    final reconciliation = _reconcileProfile();
    _profileReconciliation = reconciliation;
    try {
      await reconciliation;
    } finally {
      if (identical(_profileReconciliation, reconciliation)) {
        _profileReconciliation = null;
      }
    }
  }

  Future<void> _reconcileProfile() async {
    final profiles = await ref.read(directConnectionProfilesProvider.future);
    if (profiles.any(isCanonicalChatGptAccountProfile)) return;
    await ref
        .read(directConnectionProfilesProvider.notifier)
        .upsert(chatGptAccountProfile());
  }

  Future<void> _runAccountAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      DebugLogger.error(
        'account-action-failed',
        scope: 'auth/chatgpt',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.chatGptLoginError,
          isError: true,
        );
      }
    }
  }

  Future<void> _disconnect() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.chatGptDisconnectTitle,
      message: l10n.chatGptDisconnectMessage,
      confirmText: l10n.chatGptDisconnect,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await ref.read(chatGptConnectionProvider.notifier).disconnect();
      if (!mounted) return;
      if (ref.read(preferredBackendProvider) == PreferredBackend.chatgpt) {
        await ref
            .read(preferredBackendProvider.notifier)
            .set(PreferredBackend.unset);
      }
    } catch (error) {
      DebugLogger.error(
        'disconnect-failed',
        scope: 'auth/chatgpt',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (mounted) {
        UiUtils.showMessage(
          context,
          AppLocalizations.of(context)!.directConnectionDeleteFailed,
          isError: true,
        );
      }
    }
  }
}

class ChatGptAccountCard extends StatelessWidget {
  const ChatGptAccountCard({
    super.key,
    required this.connection,
    required this.onConnect,
    required this.onCancelLogin,
    required this.onReconnect,
    required this.onDisconnect,
  });

  final AsyncValue<ChatGptConnectionState> connection;
  final VoidCallback onConnect;
  final VoidCallback onCancelLogin;
  final VoidCallback onReconnect;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final state = connection.value;
    final status = connection.hasError
        ? ChatGptConnectionStatus.error
        : state?.status ?? ChatGptConnectionStatus.disconnected;

    Widget statusContent;
    if (connection.isLoading) {
      statusContent = Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Row(
          children: [
            const CircularProgressIndicator.adaptive(),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Text(
                l10n.chatGptAccountSubtitle,
                style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
              ),
            ),
          ],
        ),
      );
    } else if (status == ChatGptConnectionStatus.pending &&
        state?.challenge != null) {
      statusContent = _PendingLoginContent(
        challenge: state!.challenge!,
        onCancelLogin: onCancelLogin,
      );
    } else if (status == ChatGptConnectionStatus.authenticated) {
      final identity = state?.auth?.email ?? l10n.chatGptConnected;
      statusContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle, color: theme.success),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(
                  identity,
                  style: theme.bodyMedium?.copyWith(
                    color: theme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (state?.auth?.planType case final plan?)
                Text(
                  plan,
                  style: theme.bodySmall?.copyWith(color: theme.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              ConduitButton(
                text: l10n.chatGptReconnect,
                isCompact: true,
                isSecondary: true,
                onPressed: onReconnect,
              ),
              ConduitButton(
                text: l10n.chatGptDisconnect,
                isCompact: true,
                isDestructive: true,
                onPressed: onDisconnect,
              ),
            ],
          ),
        ],
      );
    } else {
      final message = switch (status) {
        ChatGptConnectionStatus.expired => l10n.chatGptLoginExpired,
        ChatGptConnectionStatus.denied => l10n.chatGptLoginDenied,
        ChatGptConnectionStatus.error => l10n.chatGptLoginError,
        _ => l10n.chatGptAccountSubtitle,
      };
      statusContent = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
          ),
          const SizedBox(height: Spacing.md),
          ConduitButton(
            text: l10n.chatGptConnect,
            icon: Icons.login,
            onPressed: onConnect,
          ),
        ],
      );
    }

    return ConduitCard(
      key: const ValueKey<String>('chatgpt-account-card'),
      padding: const EdgeInsets.all(Spacing.lg),
      child: statusContent,
    );
  }
}

class _PendingLoginContent extends StatelessWidget {
  const _PendingLoginContent({
    required this.challenge,
    required this.onCancelLogin,
  });

  final DeviceCodeChallenge challenge;
  final VoidCallback onCancelLogin;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.chatGptDeviceCodeInstructions,
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        const SizedBox(height: Spacing.md),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Spacing.md),
          decoration: BoxDecoration(
            color: theme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppBorderRadius.card),
          ),
          child: SelectableText(
            challenge.userCode,
            textAlign: TextAlign.center,
            style: theme.headingMedium?.copyWith(
              color: theme.textPrimary,
              letterSpacing: 2,
            ),
          ),
        ),
        const SizedBox(height: Spacing.md),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            ConduitButton(
              text: l10n.copy,
              icon: Icons.copy,
              isCompact: true,
              isSecondary: true,
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: challenge.userCode),
                );
                if (context.mounted) {
                  UiUtils.showMessage(context, l10n.codeCopiedToClipboard);
                }
              },
            ),
            ConduitButton(
              text: l10n.chatGptOpenVerification,
              icon: Icons.open_in_new,
              isCompact: true,
              onPressed: () => unawaited(
                _openVerificationBrowser(
                  context,
                  challenge.verificationUrl,
                  challenge.userCode,
                ),
              ),
            ),
            ConduitButton(
              text: l10n.cancel,
              isCompact: true,
              isSecondary: true,
              onPressed: onCancelLogin,
            ),
          ],
        ),
      ],
    );
  }
}

Future<void> _openVerificationBrowser(
  BuildContext context,
  String rawUrl,
  String userCode,
) async {
  final uri = validateChatGptVerificationUrl(rawUrl);
  if (uri == null) {
    DebugLogger.error('verification-url-rejected', scope: 'auth/chatgpt');
    return;
  }
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) =>
          ChatGptVerificationBrowser(initialUrl: uri, userCode: userCode),
    ),
  );
}
