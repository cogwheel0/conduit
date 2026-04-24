import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_state_manager.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Compact non-blocking banner shown at the top of the chat shell when the
/// background `/health` probe reports the configured Open WebUI server is not
/// reachable. The chat UI stays interactive — sends queue locally via
/// TaskQueue and drain when reachability returns.
class ServerReachabilityBanner extends ConsumerWidget {
  const ServerReachabilityBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reachable = ref.watch(serverReachableProvider);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        axisAlignment: -1,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: reachable
          ? const SizedBox.shrink()
          : _Banner(
              key: const ValueKey('reachability-banner-visible'),
              onRetry: () =>
                  ref.read(authStateManagerProvider.notifier)
                      .probeServerReachability(),
            ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.onRetry});

  final Future<bool> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final background = theme.warningBackground;
    final foreground = theme.warning;
    return Material(
      color: background,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 12.0,
            vertical: 6.0,
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 16, color: foreground),
              const SizedBox(width: 8.0),
              Expanded(
                child: Text(
                  'Reconnecting to server…',
                  style: TextStyle(
                    fontSize: 13.0,
                    fontWeight: FontWeight.w500,
                    color: foreground,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _RetryButton(onRetry: onRetry, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}

class _RetryButton extends StatefulWidget {
  const _RetryButton({required this.onRetry, required this.color});

  final Future<bool> Function() onRetry;
  final Color color;

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton> {
  bool _busy = false;

  Future<void> _handle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _busy ? null : _handle,
      borderRadius: BorderRadius.circular(6.0),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
        child: _busy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(widget.color),
                ),
              )
            : Text(
                'Retry',
                style: TextStyle(
                  fontSize: 13.0,
                  fontWeight: FontWeight.w600,
                  color: widget.color,
                ),
              ),
      ),
    );
  }
}
