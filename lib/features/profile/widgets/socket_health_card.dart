import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/socket_health.dart';
import '../../../core/services/socket_service.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';

/// Widget that displays socket connection health with real-time updates.
class SocketHealthCard extends StatefulWidget {
  const SocketHealthCard({super.key, required this.socketService});

  final SocketService socketService;

  @override
  State<SocketHealthCard> createState() => SocketHealthCardState();
}

class SocketHealthCardState extends State<SocketHealthCard> {
  SocketHealth? _health;
  StreamSubscription<SocketHealth>? _subscription;

  @override
  void initState() {
    super.initState();
    _initHealth();
  }

  void _initHealth() {
    _health = widget.socketService.currentHealth;
    _subscription = widget.socketService.healthStream.listen((health) {
      if (mounted) {
        setState(() => _health = health);
      }
    });
  }

  @override
  void didUpdateWidget(covariant SocketHealthCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.socketService != widget.socketService) {
      _subscription?.cancel();
      _initHealth();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final health = _health;

    if (health == null) {
      return ConduitCard(
        padding: const EdgeInsets.all(Spacing.md),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off,
              color: theme.iconSecondary,
              size: IconSize.medium,
            ),
            const SizedBox(width: Spacing.md),
            Text(
              'Not connected',
              style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
            ),
          ],
        ),
      );
    }

    final statusColor = health.isConnected ? theme.success : theme.error;
    final qualityColor = _getQualityColor(theme, health.quality);

    return ConduitCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppBorderRadius.small),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.2),
                    width: BorderWidth.thin,
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  health.isConnected ? Icons.cloud_done : Icons.cloud_off,
                  color: statusColor,
                  size: IconSize.medium,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      health.isConnected ? 'Connected' : 'Disconnected',
                      style: theme.bodyMedium?.copyWith(
                        color: theme.sidebarForeground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Spacing.xxs),
                    Text(
                      _getTransportLabel(health.transport),
                      style: theme.bodySmall?.copyWith(
                        color: theme.sidebarForeground.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              if (health.isConnected && health.hasLatencyInfo)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Spacing.sm,
                    vertical: Spacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: qualityColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppBorderRadius.small),
                    border: Border.all(
                      color: qualityColor.withValues(alpha: 0.3),
                      width: BorderWidth.thin,
                    ),
                  ),
                  child: Text(
                    _getQualityLabel(health.quality),
                    style: theme.bodySmall?.copyWith(
                      color: qualityColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          if (health.isConnected) ...[
            const SizedBox(height: Spacing.md),
            const Divider(height: 1),
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(
                  child: MetricTile(
                    icon: Icons.speed,
                    label: 'Latency',
                    value: health.hasLatencyInfo
                        ? '${health.latencyMs}ms'
                        : '—',
                    color: qualityColor,
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: MetricTile(
                    icon: Icons.refresh,
                    label: 'Reconnects',
                    value: '${health.reconnectCount}',
                    color: health.reconnectCount > 0
                        ? theme.warning
                        : theme.success,
                  ),
                ),
              ],
            ),
            if (health.lastHeartbeat != null) ...[
              const SizedBox(height: Spacing.md),
              Row(
                children: [
                  Icon(
                    Icons.favorite,
                    color: theme.error.withValues(alpha: 0.7),
                    size: IconSize.small,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    'Last heartbeat: ${_formatLastHeartbeat(health.lastHeartbeat!)}',
                    style: theme.bodySmall?.copyWith(
                      color: theme.sidebarForeground.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  String _getTransportLabel(String transport) {
    switch (transport) {
      case 'websocket':
        return 'WebSocket transport';
      case 'polling':
        return 'HTTP polling transport';
      default:
        return 'Unknown transport';
    }
  }

  String _getQualityLabel(String quality) {
    switch (quality) {
      case 'excellent':
        return 'Excellent';
      case 'good':
        return 'Good';
      case 'fair':
        return 'Fair';
      case 'poor':
        return 'Poor';
      default:
        return '—';
    }
  }

  Color _getQualityColor(ConduitThemeExtension theme, String quality) {
    switch (quality) {
      case 'excellent':
        return theme.success;
      case 'good':
        return theme.success.withValues(alpha: 0.8);
      case 'fair':
        return theme.warning;
      case 'poor':
        return theme.error;
      default:
        return theme.textSecondary;
    }
  }

  String _formatLastHeartbeat(DateTime lastHeartbeat) {
    final now = DateTime.now();
    final diff = now.difference(lastHeartbeat);

    if (diff.inSeconds < 5) {
      return 'just now';
    } else if (diff.inSeconds < 60) {
      return '${diff.inSeconds}s ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}m ago';
    } else {
      return '${diff.inHours}h ago';
    }
  }
}

/// A compact tile showing a single metric with icon, label, and value.
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;

    return Container(
      padding: const EdgeInsets.all(Spacing.sm),
      decoration: BoxDecoration(
        color: theme.cardBackground.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppBorderRadius.small),
        border: Border.all(
          color: theme.cardBorder.withValues(alpha: 0.3),
          width: BorderWidth.thin,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: IconSize.small),
          const SizedBox(width: Spacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: AppTypography.labelSmallStyle.copyWith(
                    color: theme.textSecondary,
                  ),
                ),
                Text(
                  value,
                  style: theme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
