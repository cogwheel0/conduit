import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../l10n/app_localizations.dart';
import '../../../platform/mobile_tailnet.dart';
import '../settings_page_module.dart';
import '../settings_pages.dart';

const tailnetSettingsId = 'settings-tailscale';

String tailnetStatusLabel(AppLocalizations l10n, TailnetState state) =>
    switch (state) {
      TailnetState.signedOut => l10n.terminalDisconnectedStatus,
      TailnetState.idle => l10n.tailscaleIdle,
      TailnetState.connecting => l10n.connecting,
      TailnetState.authorizing => l10n.tailscaleAuthorize,
      TailnetState.needsApproval => l10n.tailscaleApprove,
      TailnetState.connected => l10n.directConnectionProbeConnected,
      TailnetState.unavailable => l10n.tailscaleUnavailable,
    };

NativeSheetDetailConfig tailnetSettingsPage(
  AppLocalizations l10n,
  TailnetState state,
) => NativeSheetDetailConfig(
  id: tailnetSettingsId,
  title: 'Tailscale',
  sections: [
    NativeSheetSectionConfig(
      footer: l10n.tailscaleAccountHelp,
      items: [
        NativeSheetItemConfig(
          id: 'tailnet-state',
          title: tailnetStatusLabel(l10n, state),
          sfSymbol: 'network',
          kind: NativeSheetItemKind.info,
        ),
        if (state == TailnetState.signedOut ||
            state == TailnetState.unavailable ||
            state == TailnetState.authorizing)
          NativeSheetItemConfig(
            id: 'tailnet-sign-in',
            actionId: 'tailnet-sign-in',
            showsDisclosure: false,
            title: l10n.signIn,
            sfSymbol: 'person.badge.plus',
          ),
        if (state != TailnetState.signedOut)
          NativeSheetItemConfig(
            id: 'tailnet-sign-out',
            actionId: 'tailnet-sign-out',
            showsDisclosure: false,
            title: l10n.signOut,
            sfSymbol: 'rectangle.portrait.and.arrow.right',
            destructive: true,
          ),
      ],
    ),
  ],
);

class TailnetSettingsPages extends SettingsPageModule {
  TailnetSettingsPages(this.ref);
  final Ref ref;
  AppLocalizations? _l10n;
  MobileTailnet get _node => MobileTailnet.instance;

  @override
  bool ownsPage(String detailId) => detailId == tailnetSettingsId;

  void _redraw() {
    final l10n = _l10n;
    if (l10n != null) {
      unawaited(
        ref
            .read(settingsSurfaceProvider)
            .applyDetail(tailnetSettingsPage(l10n, _node.state)),
      );
    }
  }

  @override
  Future<void> hydrate(String detailId, AppLocalizations l10n) async {
    if (_l10n == null) _node.addListener(_redraw);
    _l10n = l10n;
    await _node.refresh();
    _redraw();
  }

  @override
  Future<bool> handleChange(
    String id,
    Object? value,
    AppLocalizations l10n,
  ) async {
    if (id == 'tailnet-sign-in') {
      await _node.signIn();
      return true;
    }
    if (id == 'tailnet-sign-out') {
      await _node.signOut();
      return true;
    }
    return false;
  }

  @override
  void pageLeft(String detailId) {
    if (ownsPage(detailId)) settingsClosed();
  }

  @override
  void settingsClosed() {
    _node.removeListener(_redraw);
    _l10n = null;
  }
}
