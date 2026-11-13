import 'dart:async';
import 'dart:ui' show Offset, PlatformDispatcher, Rect;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/features/push/services/hermes_push_backend.dart'
    show kConduitHermesPluginPinned;
import 'package:conduit_core/features/push/services/openwebui_push_backend.dart'
    show kConduitPushFunctionId;
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart';
import '../../push/widgets/push_target_actions.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';
import 'hermes_page_ids.dart';
import 'push_page_ids.dart';

/// What a push target's page shows besides the target itself: a test under
/// way or its answer, and a note from the last fix tried.
@immutable
class PushTargetPageState {
  const PushTargetPageState({
    this.testing = false,
    this.testArrived,
    this.notice,
  });

  final bool testing;

  /// Whether the last test notification arrived; null with none sent.
  final bool? testArrived;

  /// What the last fix said: the command copied, say.
  final String? notice;
}

String _encoded(String scope) => Uri.encodeComponent(scope);

/// The rows of one push target's status: what it means, and for Hermes the
/// command to run.
NativeSheetSectionConfig _statusSection(
  AppLocalizations l10n,
  PushTargetState target,
) {
  final scope = _encoded(target.scope);
  final command = target.status == PushStatus.needsHermesPlugin
      ? target.hermesInstallCommand
      : null;
  return NativeSheetSectionConfig(
    // Without a pinned commit the command installs whatever the plugin's
    // repository publishes now.
    footer: command != null && !kConduitHermesPluginPinned
        ? l10n.pushHermesCommandLatest
        : null,
    items: [
      NativeSheetItemConfig(
        id: 'push-target-status:$scope',
        title: pushStatusText(l10n, target),
        subtitle: pushStatusExplanation(l10n, target),
        sfSymbol: pushTargetBusy(target)
            ? 'hourglass'
            : pushTargetNeedsAttention(target)
            ? 'exclamationmark.triangle'
            : target.status == PushStatus.on
            ? 'checkmark.circle'
            : 'bell.slash',
        kind: NativeSheetItemKind.info,
      ),
      if (command != null)
        NativeSheetItemConfig(
          id: 'push-target-command:$scope',
          title: l10n.pushHermesCommandLabel,
          subtitle: command,
          sfSymbol: 'terminal',
          kind: NativeSheetItemKind.info,
        ),
    ],
  );
}

/// Where a fix that installs code links to that code.
String? _sourceUrl(PushTargetAction action) => switch (action) {
  PushTargetAction.setUp ||
  PushTargetAction.update => kConduitPushFunctionSourceUrl,
  PushTargetAction.installHermes => kConduitHermesPluginSourceUrl,
  _ => null,
};

/// The one-tap fix [target] needs, with a link to the code it would
/// install. Signing in to an Open WebUI account is a flow of its own, so
/// that row closes Settings first; a Hermes connection signs in on its own
/// page of Settings.
NativeSheetSectionConfig? _actionSection(
  AppLocalizations l10n,
  PushTargetState target,
  PushTargetPageState page,
) {
  final action = pushTargetAction(target);
  if (action == null) return null;
  final scope = _encoded(target.scope);
  final symbol = switch (action) {
    PushTargetAction.setUp ||
    PushTargetAction.installHermes => 'arrow.down.circle',
    PushTargetAction.update => 'arrow.triangle.2.circlepath',
    PushTargetAction.askAdmin => 'square.and.arrow.up',
    PushTargetAction.copyCommand => 'doc.on.doc',
    PushTargetAction.signIn => 'person.crop.circle.badge.checkmark',
    PushTargetAction.retry => 'arrow.clockwise',
  };
  final label = pushActionLabel(l10n, action);
  final NativeSheetItemConfig row;
  switch ((action, target.target)) {
    case (PushTargetAction.signIn, OpenWebUiPushTarget()):
      row = NativeSheetItemConfig(
        id: '$pushTargetActionPrefix$scope',
        title: label,
        sfSymbol: symbol,
        accent: true,
        dismissOnSelect: true,
        showsDisclosure: false,
        actionId: pushTargetSignInActionId,
        actionValue: target.scope,
      );
    case (PushTargetAction.signIn, HermesPushTarget(:final connectionId)):
      row = NativeSheetItemConfig(
        id: hermesConnectionPageId(connectionId),
        title: label,
        sfSymbol: symbol,
        accent: true,
      );
    default:
      row = NativeSheetItemConfig(
        id: '$pushTargetActionPrefix$scope',
        title: label,
        sfSymbol: symbol,
        accent: true,
        showsDisclosure: false,
      );
  }
  final source = _sourceUrl(action);
  return NativeSheetSectionConfig(
    footer: page.notice,
    items: [
      row,
      if (source != null)
        NativeSheetItemConfig(
          id: 'push-target-source:$scope',
          title: l10n.pushViewSource,
          subtitle: source,
          sfSymbol: 'chevron.left.forwardslash.chevron.right',
          url: source,
          showsDisclosure: false,
        ),
    ],
  );
}

/// [target]'s diagnostics, a row each, for support.
NativeSheetSectionConfig? _diagnosticsSection(
  AppLocalizations l10n,
  PushTargetState target,
) {
  final scope = _encoded(target.scope);
  NativeSheetItemConfig line(
    String key,
    String title,
    String value,
    String symbol,
  ) => NativeSheetItemConfig(
    id: 'push-target-diagnostics-$key:$scope',
    title: title,
    subtitle: value,
    sfSymbol: symbol,
    kind: NativeSheetItemKind.info,
  );
  final rows = <NativeSheetItemConfig>[
    if (target.transport case final transport?)
      line('transport', l10n.pushDiagnosticsTransport, switch (transport) {
        PushTransport.apns => 'APNs',
        PushTransport.fcm => l10n.pushDeliveryFcm,
        PushTransport.unifiedPush => l10n.pushDeliveryUnifiedPush,
      }, 'antenna.radiowaves.left.and.right'),
    if (target.serverVersion case final version?)
      line('server', l10n.pushDiagnosticsServer, version, 'server.rack'),
    if (target.pluginVersion case final version?)
      line(
        'plugin',
        l10n.pushDiagnosticsPlugin,
        switch (target.bundledVersion) {
          final bundled? when bundled != version => '$version → $bundled',
          _ => version,
        },
        'puzzlepiece.extension',
      ),
    if (target.verifiedAt case final at?)
      line(
        'verified',
        l10n.pushDiagnosticsVerified,
        DateFormat.yMMMd(l10n.localeName).add_jm().format(at.toLocal()),
        'clock',
      ),
    if (target.diagnostics case final report?)
      if ([?report.error, ?report.code?.toString()] case final parts
          when parts.isNotEmpty)
        line(
          'report',
          l10n.pushDiagnosticsServerReport,
          parts.join(' · '),
          'doc.text',
        ),
    if (target.failure case final failure?)
      line(
        'error',
        l10n.pushDiagnosticsError,
        '${failure.reason.name}'
            '${failure.detail == null ? '' : ' (${failure.detail})'}',
        'exclamationmark.triangle',
      ),
  ];
  if (rows.isEmpty) return null;
  return NativeSheetSectionConfig(
    title: l10n.pushDiagnosticsTitle,
    items: rows,
  );
}

/// The page of one account's or connection's push: what its status means,
/// the fix it needs, a test, whether it uses push, which replies notify
/// (Open WebUI), and diagnostics. [title] names the account or connection.
@visibleForTesting
NativeSheetDetailConfig buildPushTargetPage(
  AppLocalizations l10n, {
  required PushTargetState target,
  required String title,
  required bool pushEnabled,
  PushTargetPageState page = const PushTargetPageState(),
}) {
  final scope = _encoded(target.scope);
  final isOpenWebUi = target.target.kind == PushTargetKind.openWebUi;
  final canTest = pushEnabled && !target.optedOut && !pushTargetBusy(target);
  final action = _actionSection(l10n, target, page);
  final diagnostics = _diagnosticsSection(l10n, target);
  final testResult = switch (page.testArrived) {
    true => l10n.pushTestArrived,
    false => l10n.pushTestMissing,
    null => null,
  };
  return NativeSheetDetailConfig(
    id: pushTargetPageId(target.scope),
    title: title,
    announcement: testResult ?? page.notice,
    sections: [
      _statusSection(l10n, target),
      ?action,
      NativeSheetSectionConfig(
        // A test that went through says so; one that didn't, in its group.
        footer: page.testArrived == true ? testResult : null,
        items: [
          NativeSheetItemConfig(
            id: '$pushTargetTestPrefix$scope',
            title: l10n.pushDetailSendTest,
            sfSymbol: 'paperplane',
            showsDisclosure: false,
            pending: page.testing,
            disabled: !canTest || page.testing,
          ),
          if (page.testArrived == false)
            NativeSheetItemConfig(
              id: 'push-target-test-failed:$scope',
              title: l10n.pushTestMissing,
              sfSymbol: 'exclamationmark.triangle',
              kind: NativeSheetItemKind.info,
            ),
          NativeSheetItemConfig(
            id: '$pushTargetUsePrefix$scope',
            title: isOpenWebUi
                ? l10n.pushDetailUseForAccount
                : l10n.pushDetailUseForConnection,
            sfSymbol: 'bell',
            kind: NativeSheetItemKind.toggle,
            value: !target.optedOut,
          ),
        ],
      ),
      if (isOpenWebUi)
        NativeSheetSectionConfig(
          title: l10n.pushDetailOriginTitle,
          footer: l10n.pushDetailOriginDescription,
          items: [
            for (final (origin, label, symbol) in [
              (PushOrigin.conduit, l10n.pushOriginConduit, 'iphone'),
              (
                PushOrigin.any,
                l10n.pushOriginAny,
                'bubble.left.and.bubble.right',
              ),
            ])
              NativeSheetItemConfig(
                id: '$pushTargetOriginPrefix$scope:${origin.name}',
                title: label,
                sfSymbol: symbol,
                checked: target.origin == origin,
                kind: target.origin == origin
                    ? NativeSheetItemKind.info
                    : NativeSheetItemKind.navigation,
                showsDisclosure: false,
              ),
          ],
        ),
      ?diagnostics,
    ],
  );
}

/// "How Push Stays Private": the threat model in a few plain sentences, a
/// group each, with a link to the whole document.
NativeSheetDetailConfig buildPushPrivacyPage(AppLocalizations l10n) {
  final topics = [
    (l10n.pushPrivacyServerTitle, l10n.pushPrivacyServerBody, 'server.rack'),
    (
      l10n.pushPrivacyRelayTitle,
      l10n.pushPrivacyRelayBody,
      'arrow.triangle.branch',
    ),
    (l10n.pushPrivacyProvidersTitle, l10n.pushPrivacyProvidersBody, 'cloud'),
    (
      l10n.pushPrivacyUnifiedPushTitle,
      l10n.pushPrivacyUnifiedPushBody,
      'antenna.radiowaves.left.and.right',
    ),
    (l10n.pushPrivacyOffTitle, l10n.pushPrivacyOffBody, 'bell.slash'),
  ];
  return NativeSheetDetailConfig(
    id: pushPrivacyPageId,
    title: l10n.pushPrivacyTitle,
    sections: [
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: 'push-privacy-intro',
            title: l10n.pushPrivacyIntro,
            sfSymbol: 'lock.shield',
            kind: NativeSheetItemKind.info,
          ),
        ],
      ),
      for (final (index, (title, body, symbol)) in topics.indexed)
        NativeSheetSectionConfig(
          title: title,
          items: [
            NativeSheetItemConfig(
              id: 'push-privacy-topic-$index',
              title: body,
              sfSymbol: symbol,
              kind: NativeSheetItemKind.info,
            ),
          ],
        ),
      NativeSheetSectionConfig(
        items: [
          NativeSheetItemConfig(
            id: 'push-privacy-read-more',
            title: l10n.pushPrivacyReadMore,
            sfSymbol: 'link',
            url: kConduitPushThreatModelUrl,
            showsDisclosure: false,
          ),
        ],
      ),
    ],
  );
}

/// The pages a push targets list leads to: each target's, and for a Hermes
/// connection that must sign in again, its page of Settings.
List<NativeSheetDetailConfig> pushTargetChildPages(
  AppLocalizations l10n,
  PushState push,
) => [
  for (final target in push.targets.values) ...[
    buildPushTargetLoadingPage(l10n, target.scope),
    if (target.target case HermesPushTarget(:final connectionId))
      buildNativeLoadingDetail(
        l10n: l10n,
        id: hermesConnectionPageId(connectionId),
        title: l10n.hermesAgentSettingsTitle,
      ),
  ],
];

/// Push's pages of Settings: the list of accounts and connections with
/// their status, each one's page with its fixes, a test and its options,
/// and "How Push Stays Private". While one is open they follow push as it
/// changes, so a setup that finishes shows without leaving.
class PushSettingsPages extends SettingsPageModule {
  PushSettingsPages(this._ref);

  final Ref _ref;
  final Set<String> _following = {};
  ProviderSubscription<Object?>? _pushSubscription;
  ProviderSubscription<Object?>? _accountsSubscription;
  bool _redrawQueued = false;
  AppLocalizations? _l10n;

  /// Per target scope: what its page shows besides the target.
  final Map<String, PushTargetPageState> _pages = {};

  /// Per target scope, how many times its page was left: an answer that
  /// lands after the page it was asked from is left belongs to no page.
  final Map<String, int> _leaves = {};
  int _closings = 0;

  SettingsSurface get _surface => _ref.read(settingsSurfaceProvider);

  @override
  bool ownsPage(String detailId) =>
      detailId == NativeSheetRoutes.pushTargets ||
      detailId == pushPrivacyPageId ||
      detailId.startsWith(pushTargetPagePrefix);

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    _l10n = l10n;
    if (detailId == pushPrivacyPageId) {
      await _surface.applyDetail(buildPushPrivacyPage(l10n));
      return;
    }
    _follow(detailId);
    await _apply(l10n, detailId);
  }

  @override
  void pageLeft(String detailId) {
    if (_following.remove(detailId) && _following.isEmpty) _stopFollowing();
    final scope = pushTargetScopeOf(detailId);
    if (scope == null) return;
    _leaves[scope] = (_leaves[scope] ?? 0) + 1;
    _pages.remove(scope);
  }

  @override
  void settingsClosed() {
    _following.clear();
    _stopFollowing();
    _pages.clear();
    _closings++;
  }

  (int, int) _visit(String scope) => (_leaves[scope] ?? 0, _closings);

  bool _stillOpen(String scope, (int, int) visit) => _visit(scope) == visit;

  PushState? get _push => _ref.read(pushStateIfUsedProvider);

  Map<String, OpenWebUiAccountEntry> get _accounts => {
    for (final entry
        in _ref.read(openWebUiAccountsProvider).value ??
            const <OpenWebUiAccountEntry>[])
      entry.id: entry,
  };

  void _follow(String detailId) {
    _following.add(detailId);
    if (_pushSubscription != null) return;
    void redraw(Object? _, Object? _) => _queueRedraw();
    // Through the container: a listener on the modules' own ref, which
    // nothing watches, missed changes the pages' own rows made.
    final container = _ref.container;
    _pushSubscription = container.listen(pushStateIfUsedProvider, redraw);
    _accountsSubscription = container.listen(openWebUiAccountsProvider, redraw);
  }

  void _stopFollowing() {
    _pushSubscription?.close();
    _pushSubscription = null;
    _accountsSubscription?.close();
    _accountsSubscription = null;
  }

  /// Redraws the pages followed, once for changes that land together.
  void _queueRedraw() {
    if (_redrawQueued) return;
    _redrawQueued = true;
    scheduleMicrotask(() {
      _redrawQueued = false;
      final l10n = _l10n;
      if (l10n == null) return;
      for (final detailId in [..._following]) {
        unawaited(_apply(l10n, detailId));
      }
    });
  }

  Future<void> _apply(AppLocalizations l10n, String detailId) async {
    try {
      final push = _push;
      if (detailId == NativeSheetRoutes.pushTargets) {
        if (push == null) return;
        final accounts = _accounts;
        await _surface.applyDetail(
          buildNativePushTargetsDetail(
            l10n,
            push,
            titleOf: (target) => pushTargetTitle(l10n, target, accounts),
          ),
          detailSheets: _unknown(pushTargetChildPages(l10n, push)),
        );
        return;
      }
      final scope = pushTargetScopeOf(detailId);
      if (scope == null) return;
      final target = push?.targets[scope];
      if (push == null || target == null) {
        // Signed out of, or removed, since the page was opened: there is
        // nothing left to show, so the page goes.
        await _surface.closeDetail(detailId);
        return;
      }
      await _surface.applyDetail(
        buildPushTargetPage(
          l10n,
          target: target,
          title: pushTargetTitle(l10n, target.target, _accounts),
          pushEnabled: push.enabled,
          page: _pages[scope] ?? const PushTargetPageState(),
        ),
        detailSheets: _unknown([
          if (target.target case HermesPushTarget(:final connectionId))
            buildNativeLoadingDetail(
              l10n: l10n,
              id: hermesConnectionPageId(connectionId),
              title: l10n.hermesAgentSettingsTitle,
            ),
        ]),
      );
    } catch (error, stackTrace) {
      DebugLogger.error(
        'push-page-draw-failed',
        scope: 'settings/push',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// [pages] not drawn yet: a page open over this one (a target's page, the
  /// Hermes connection's editor) keeps what it shows through live redraws.
  List<NativeSheetDetailConfig> _unknown(List<NativeSheetDetailConfig> pages) {
    final known = _ref.read(settingsPagesProvider);
    return [
      for (final page in pages)
        if (!known.contains(page.id)) page,
    ];
  }

  Future<void> _redraw(String scope) async {
    final l10n = _l10n;
    if (l10n == null) return;
    await _apply(l10n, pushTargetPageId(scope));
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    _l10n = l10n;
    if (id.startsWith(pushTargetActionPrefix)) {
      final scope = Uri.decodeComponent(
        id.substring(pushTargetActionPrefix.length),
      );
      await _runAction(l10n, scope);
      return true;
    }
    if (id.startsWith(pushTargetTestPrefix)) {
      final scope = Uri.decodeComponent(
        id.substring(pushTargetTestPrefix.length),
      );
      // Not waited for: other row changes, an opt-out among them, are not
      // held behind a test on its way.
      unawaited(_sendTest(scope));
      return true;
    }
    if (id.startsWith(pushTargetUsePrefix)) {
      final scope = Uri.decodeComponent(
        id.substring(pushTargetUsePrefix.length),
      );
      if (value is bool && _push?.targets[scope] != null) {
        await _guard(
          'push-opt-out-failed',
          _ref
              .read(pushCoordinatorProvider.notifier)
              .setTargetOptedOut(scope, !value),
        );
        // A change that did not go through leaves the switch as it is.
        await _redraw(scope);
      }
      return true;
    }
    if (id.startsWith(pushTargetOriginPrefix)) {
      final rest = id.substring(pushTargetOriginPrefix.length);
      final colon = rest.lastIndexOf(':');
      if (colon < 0) return true;
      final scope = Uri.decodeComponent(rest.substring(0, colon));
      final origin = PushOrigin.values.asNameMap()[rest.substring(colon + 1)];
      final target = _push?.targets[scope];
      if (origin != null && target != null && target.origin != origin) {
        await _guard(
          'push-origin-failed',
          _ref.read(pushCoordinatorProvider.notifier).setOrigin(scope, origin),
        );
        await _redraw(scope);
      }
      return true;
    }
    return false;
  }

  /// Runs the fix [scope]'s target needs now, asking first where it installs
  /// code on a server. Long-running work goes on after this returns; the
  /// target's status shows how it goes.
  Future<void> _runAction(AppLocalizations l10n, String scope) async {
    final target = _push?.targets[scope];
    if (target == null) return;
    final action = pushTargetAction(target);
    if (action == null) return;
    final coordinator = _ref.read(pushCoordinatorProvider.notifier);
    final visit = _visit(scope);
    switch (action) {
      case PushTargetAction.setUp || PushTargetAction.update:
        final update = action == PushTargetAction.update;
        if (!await _confirmInstall(
          l10n,
          title: update
              ? l10n.pushUpdateOpenWebUiTitle
              : l10n.pushInstallOpenWebUiTitle,
          message: update
              ? l10n.pushUpdateOpenWebUiMessage
              : l10n.pushInstallOpenWebUiMessage,
          confirm: update ? l10n.pushActionUpdate : l10n.pushActionInstall,
        )) {
          return;
        }
        if (!_stillOpen(scope, visit)) return;
        _fireAndForget(coordinator.installOpenWebUiFunction(scope));
      case PushTargetAction.installHermes:
        if (!await _confirmInstall(
          l10n,
          title: l10n.pushInstallHermesTitle,
          message: l10n.pushInstallHermesMessage,
          confirm: l10n.pushActionInstall,
        )) {
          return;
        }
        if (!_stillOpen(scope, visit)) return;
        _fireAndForget(coordinator.installHermesPlugin(scope));
      case PushTargetAction.askAdmin:
        await SharePlus.instance.share(
          ShareParams(
            text: l10n.pushAskAdminMessage(
              kConduitPushFunctionRawUrl,
              kConduitPushFunctionId,
              kConduitPushAdminGuideUrl,
            ),
            sharePositionOrigin: _shareOrigin(),
          ),
        );
      case PushTargetAction.copyCommand:
        final command = target.hermesInstallCommand;
        if (command == null) return;
        await Clipboard.setData(ClipboardData(text: command));
        if (!_stillOpen(scope, visit)) return;
        _pages[scope] = PushTargetPageState(notice: l10n.copiedToClipboard);
        await _redraw(scope);
      case PushTargetAction.retry:
        _fireAndForget(coordinator.retry(scope));
      case PushTargetAction.signIn:
        // Its row leads elsewhere: Settings closes for an Open WebUI
        // account's sign-in, and a Hermes connection opens its own page.
        return;
    }
  }

  /// Asks before code is installed on the user's server. The page links to
  /// that code under the fix.
  Future<bool> _confirmInstall(
    AppLocalizations l10n, {
    required String title,
    required String message,
    required String confirm,
  }) async =>
      await _surface.ask(
        title: title,
        message: message,
        actions: [
          NativeSheetAlertAction(
            'cancel',
            l10n.cancel,
            style: NativeSheetAlertStyle.cancel,
          ),
          NativeSheetAlertAction('install', confirm),
        ],
      ) ==
      'install';

  /// Sends a test notification to [scope]; its page waits on the row, then
  /// says whether it arrived.
  Future<void> _sendTest(String scope) async {
    final push = _push;
    final target = push?.targets[scope];
    if (push == null ||
        target == null ||
        !push.enabled ||
        target.optedOut ||
        pushTargetBusy(target) ||
        (_pages[scope]?.testing ?? false)) {
      return;
    }
    final visit = _visit(scope);
    _pages[scope] = const PushTargetPageState(testing: true);
    await _redraw(scope);
    var arrived = false;
    try {
      arrived = await _ref
          .read(pushCoordinatorProvider.notifier)
          .sendTest(scope);
    } catch (error, stackTrace) {
      DebugLogger.error(
        'push-test-failed',
        scope: 'settings/push',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Left meanwhile: the answer is no page's.
    if (!_stillOpen(scope, visit)) return;
    _pages[scope] = PushTargetPageState(testArrived: arrived);
    await _redraw(scope);
  }

  Future<void> _guard(String message, Future<void> work) async {
    try {
      await work;
    } catch (error, stackTrace) {
      DebugLogger.error(
        message,
        scope: 'settings/push',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _fireAndForget(Future<Object?> work) => unawaited(
    work.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) => DebugLogger.error(
        'push-action-failed',
        scope: 'settings/push',
        error: error,
        stackTrace: stackTrace,
      ),
    ),
  );

  /// Where an iPad anchors the share sheet: the middle of the window, as
  /// the row that asked for it has no place Dart knows.
  Rect? _shareOrigin() {
    final view = PlatformDispatcher.instance.views.firstOrNull;
    if (view == null) return null;
    final size = view.physicalSize / view.devicePixelRatio;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: 1,
      height: 1,
    );
  }
}
