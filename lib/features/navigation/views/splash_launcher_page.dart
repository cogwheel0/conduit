import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_state_manager.dart';
import '../../../core/services/navigation_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../providers/splash_providers.dart';

class SplashLauncherPage extends ConsumerWidget {
  const SplashLauncherPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final splashState = ref.watch(splashStateManagerProvider);

    return Scaffold(
      backgroundColor: context.conduitTheme.surfaceBackground,
      body: SafeArea(
        child: Center(
          child: splashState.showTimeout
              ? _buildTimeoutRecovery(context, ref, l10n, splashState)
              : _buildLoading(context, ref, l10n),
        ),
      ),
    );
  }

  Widget _buildLoading(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations? l10n,
  ) {
    final manager = ref.read(splashStateManagerProvider.notifier);
    final tapCount = ref.watch(splashStateManagerProvider).tapCount;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Trigger haptic feedback on each tap
        HapticFeedback.lightImpact();
        manager.onLoadingTap();
      },
      child: Container(
        // Full screen tap target
        width: double.infinity,
        height: double.infinity,
        color: Colors.transparent,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    context.conduitTheme.loadingIndicator,
                  ),
                ),
              ),
              if (tapCount > 0) ...[
                const SizedBox(height: 16),
                Text(
                  'Tap ${3 - tapCount} more time${3 - tapCount == 1 ? '' : 's'}',
                  style: context.conduitTheme.bodySmall?.copyWith(
                    color: context.conduitTheme.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeoutRecovery(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations? l10n,
    SplashState splashState,
  ) {
    final authState = ref.watch(authStateManagerProvider).asData?.value;
    final errorMessage = authState?.error;
    final manager = ref.read(splashStateManagerProvider.notifier);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: context.conduitTheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                color: context.conduitTheme.error.withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: Icon(
              Platform.isIOS
                  ? CupertinoIcons.exclamationmark_triangle
                  : Icons.error_outline,
              color: context.conduitTheme.error,
              size: 28,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            l10n?.connectionTimeout ?? 'Connection Timeout',
            textAlign: TextAlign.center,
            style: context.conduitTheme.headingMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: context.conduitTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            errorMessage ??
                (l10n?.connectionTimeoutMessage ??
                    'The app is taking longer than expected to connect. This might be due to a slow connection or server timeout.'),
            textAlign: TextAlign.center,
            style: context.conduitTheme.bodyMedium?.copyWith(
              color: context.conduitTheme.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 32),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConduitButton(
                  text: l10n?.retry ?? 'Retry',
                  onPressed: splashState.isRecovering
                      ? null
                      : () async {
                          await manager.retry();
                        },
                  isLoading: splashState.isRecovering,
                  icon: Platform.isIOS
                      ? CupertinoIcons.refresh
                      : Icons.refresh_rounded,
                  isFullWidth: true,
                ),
                const SizedBox(height: 12),
                ConduitButton(
                  text: l10n?.signOut ?? 'Sign Out',
                  onPressed: splashState.isRecovering
                      ? null
                      : () async {
                          await manager.logout();
                          if (context.mounted) {
                            context.go(Routes.serverConnection);
                          }
                        },
                  isSecondary: true,
                  icon: Platform.isIOS
                      ? CupertinoIcons.arrow_turn_up_left
                      : Icons.logout,
                  isFullWidth: true,
                  isCompact: true,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
