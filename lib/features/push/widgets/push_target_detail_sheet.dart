import 'dart:async';

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show kConduitHermesPluginPinned;
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sheet_handle.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../../../shared/widgets/utility_components.dart';
import '../../profile/widgets/account_actions.dart' show ActiveCheckmark;
import 'push_target_actions.dart';

/// Opens the detail sheet of the push target [scope].
Future<void> showPushTargetDetailSheet(BuildContext context, String scope) =>
    ThemedSheets.showCustom<void>(
      context: context,
      builder: (_) => PushTargetDetailSheet(scope: scope),
    );

/// One account's or connection's push: what its status means, a test, its
/// options, and diagnostics.
class PushTargetDetailSheet extends ConsumerStatefulWidget {
  const PushTargetDetailSheet({super.key, required this.scope});

  final String scope;

  @override
  ConsumerState<PushTargetDetailSheet> createState() =>
      _PushTargetDetailSheetState();
}

class _PushTargetDetailSheetState extends ConsumerState<PushTargetDetailSheet> {
  bool _testing = false;

  Future<void> _sendTest() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _testing = true);
    final arrived = await ref
        .read(pushCoordinatorProvider.notifier)
        .sendTest(widget.scope);
    if (!mounted) return;
    setState(() => _testing = false);
    AdaptiveSnackBar.show(
      context,
      message: arrived ? l10n.pushTestArrived : l10n.pushTestMissing,
      type: arrived
          ? AdaptiveSnackBarType.success
          : AdaptiveSnackBarType.warning,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final push = ref.watch(pushCoordinatorProvider);
    final target = push.targets[widget.scope];
    final accounts = pushAccountEntries(ref);
    final navigator = Navigator.of(context);

    final children = <Widget>[];
    if (target != null) {
      final action = pushTargetAction(target);
      final isOpenWebUi = target.target.kind == PushTargetKind.openWebUi;
      final busy = pushTargetBusy(target);
      children.addAll([
        Text(
          pushStatusText(l10n, target),
          key: const Key('push-detail-status'),
          style: theme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          pushStatusExplanation(l10n, target),
          key: const Key('push-detail-explanation'),
          style: theme.bodyMedium?.copyWith(color: theme.textSecondary),
        ),
        if (target.status == PushStatus.needsHermesPlugin &&
            target.hermesInstallCommand != null) ...[
          const SizedBox(height: Spacing.sm),
          InsetGroupedList(
            children: [
              UtilityValueRow(
                label: l10n.pushHermesCommandLabel,
                value: target.hermesInstallCommand!,
                monospace: true,
                stacked: true,
              ),
            ],
          ),
          // Without a pinned commit the command installs whatever the
          // plugin's repository publishes now.
          if (!kConduitHermesPluginPinned) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              l10n.pushHermesCommandLatest,
              key: const Key('push-detail-command-latest'),
              style: theme.caption?.copyWith(color: theme.textSecondary),
            ),
          ],
        ],
        if (action != null) ...[
          const SizedBox(height: Spacing.md),
          AdaptiveButton(
            key: const Key('push-detail-action'),
            onPressed: () => runPushTargetAction(context, ref, target, action),
            label: pushActionLabel(l10n, action),
          ),
        ],
        const SizedBox(height: Spacing.md),
        InsetGroupedList(
          children: [
            UtilityRow(
              key: const Key('push-detail-test'),
              title: l10n.pushDetailSendTest,
              enabled: push.enabled && !target.optedOut && !busy && !_testing,
              preserveTrailingSemantics: true,
              trailing: _testing
                  ? const ConduitLoadingIndicator(isCompact: true)
                  : null,
              onTap: push.enabled && !target.optedOut && !busy && !_testing
                  ? () => unawaited(_sendTest())
                  : null,
            ),
            UtilityRow(
              key: const Key('push-detail-use'),
              title: isOpenWebUi
                  ? l10n.pushDetailUseForAccount
                  : l10n.pushDetailUseForConnection,
              toggled: !target.optedOut,
              trailing: AdaptiveSwitch(
                value: !target.optedOut,
                onChanged: (use) => unawaited(
                  ref
                      .read(pushCoordinatorProvider.notifier)
                      .setTargetOptedOut(widget.scope, !use),
                ),
              ),
              onTap: () => unawaited(
                ref
                    .read(pushCoordinatorProvider.notifier)
                    .setTargetOptedOut(widget.scope, !target.optedOut),
              ),
            ),
          ],
        ),
        if (isOpenWebUi) ...[
          const SizedBox(height: Spacing.md),
          // Rows rather than a segmented control: the labels are long in
          // several languages.
          InsetGroupedList(
            key: const Key('push-detail-origin'),
            title: l10n.pushDetailOriginTitle,
            description: l10n.pushDetailOriginDescription,
            children: [
              for (final (origin, label) in [
                (PushOrigin.conduit, l10n.pushOriginConduit),
                (PushOrigin.any, l10n.pushOriginAny),
              ])
                UtilityRow(
                  key: Key('push-origin-${origin.name}'),
                  title: label,
                  selected: target.origin == origin,
                  trailing: target.origin == origin
                      ? ActiveCheckmark(semanticLabel: label)
                      : null,
                  onTap: target.origin == origin
                      ? null
                      : () => unawaited(
                          ref
                              .read(pushCoordinatorProvider.notifier)
                              .setOrigin(widget.scope, origin),
                        ),
                ),
            ],
          ),
        ],
        const SizedBox(height: Spacing.md),
        Text(
          _diagnostics(l10n, target),
          key: const Key('push-detail-diagnostics'),
          style: theme.caption?.copyWith(color: theme.textSecondary),
        ),
      ]);
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      child: ConduitModalSheetSurface(
        showHandle: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetHandle(),
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      target == null
                          ? l10n.pushSectionTitle
                          : pushTargetTitle(l10n, target.target, accounts),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.headingSmall,
                    ),
                  ),
                ),
                SheetCloseButton(
                  tooltip: l10n.close,
                  onPressed: () => navigator.pop(),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(
                  top: Spacing.sm,
                  bottom: Spacing.md,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _diagnostics(AppLocalizations l10n, PushTargetState target) {
    final lines = <String>[l10n.pushDiagnosticsTitle];
    final transport = target.transport;
    if (transport != null) {
      lines.add(
        '${l10n.pushDiagnosticsTransport}: ${_transportName(l10n, transport)}',
      );
    }
    if (target.serverVersion case final version?) {
      lines.add('${l10n.pushDiagnosticsServer}: $version');
    }
    if (target.pluginVersion case final version?) {
      final bundled = target.bundledVersion;
      lines.add(
        '${l10n.pushDiagnosticsPlugin}: $version'
        '${bundled != null && bundled != version ? ' → $bundled' : ''}',
      );
    }
    if (target.verifiedAt case final at?) {
      lines.add(
        '${l10n.pushDiagnosticsVerified}: '
        '${DateFormat.yMMMd().add_jm().format(at.toLocal())}',
      );
    }
    if (target.diagnostics case final report?) {
      final parts = [?report.error, ?report.code?.toString()];
      if (parts.isNotEmpty) {
        lines.add('${l10n.pushDiagnosticsServerReport}: ${parts.join(' · ')}');
      }
    }
    if (target.failure case final failure?) {
      lines.add(
        '${l10n.pushDiagnosticsError}: ${failure.reason.name}'
        '${failure.detail == null ? '' : ' (${failure.detail})'}',
      );
    }
    return lines.join('\n');
  }

  static String _transportName(
    AppLocalizations l10n,
    PushTransport transport,
  ) => switch (transport) {
    PushTransport.apns => 'APNs',
    PushTransport.fcm => l10n.pushDeliveryFcm,
    PushTransport.unifiedPush => l10n.pushDeliveryUnifiedPush,
  };
}
