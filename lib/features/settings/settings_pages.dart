import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/native_sheet_bridge.dart';
import '../../shared/services/navigation_service.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart'
    show AdaptiveAlertDialog, AlertAction, AlertActionStyle;

/// Settings pages as they were last described, by id.
///
/// Settings is one set of page definitions. iOS draws them in the native
/// sheet; the Flutter Settings pages (Android, and iOS when the sheet cannot
/// open) draw the same definitions from here. A page is known once something
/// registers it -- the root, or a page that leads to it -- exactly as the
/// native sheet only pushes a page it was given.
@immutable
class SettingsPagesState {
  const SettingsPagesState({
    this.pages = const {},
    this.closeRequests = const {},
  });

  final Map<String, NativeSheetDetailConfig> pages;

  /// How many times each page was asked to close; a page that sees its
  /// count go up goes back to the page that opened it.
  final Map<String, int> closeRequests;

  NativeSheetDetailConfig? operator [](String id) => pages[id];

  bool contains(String id) => pages.containsKey(id);
}

final settingsPagesProvider =
    NotifierProvider<SettingsPages, SettingsPagesState>(SettingsPages.new);

class SettingsPages extends Notifier<SettingsPagesState> {
  @override
  SettingsPagesState build() => const SettingsPagesState();

  /// Makes [details] known, replacing any earlier copy of each. Close
  /// requests carry on, so a page open now does not take a reset count for
  /// a new one.
  void register(Iterable<NativeSheetDetailConfig> details) {
    if (details.isEmpty) return;
    state = SettingsPagesState(
      pages: {...state.pages, for (final detail in details) detail.id: detail},
      closeRequests: state.closeRequests,
    );
  }

  /// Applies a patch the way the native sheet does: only to a page that is
  /// already known, keeping what the patch does not name. Pages in
  /// [detailSheets] become known first, so a page can register the pages
  /// it leads to with its own rows. Returns whether [detailId] was known.
  bool patch({
    required String detailId,
    required List<NativeSheetItemConfig> items,
    List<NativeSheetSectionConfig> sections = const [],
    String? title,
    String? subtitle,
    bool clearSubtitle = false,
    List<NativeSheetDetailConfig> detailSheets = const [],
    NativeSheetDetailConfig? whole,
  }) {
    final existing = state.pages[detailId];
    final pages = {
      ...state.pages,
      for (final detail in detailSheets) detail.id: detail,
    };
    if (existing != null && whole != null) {
      pages[detailId] = whole;
    } else if (existing != null) {
      pages[detailId] = NativeSheetDetailConfig(
        id: existing.id,
        title: title ?? existing.title,
        subtitle: clearSubtitle ? null : subtitle ?? existing.subtitle,
        items: items,
        sections: sections,
        confirmActionId: existing.confirmActionId,
        confirmActionLabel: existing.confirmActionLabel,
        maxHeightFraction: existing.maxHeightFraction,
        trailingActionId: existing.trailingActionId,
        trailingActionSfSymbol: existing.trailingActionSfSymbol,
        discardPrompt: existing.discardPrompt,
        busy: existing.busy,
        edited: existing.edited,
        // Kept, so the same announcement sent again is not read out twice.
        announcement: existing.announcement,
        search: existing.search,
      );
    }
    if (existing != null || detailSheets.isNotEmpty) {
      state = SettingsPagesState(
        pages: pages,
        closeRequests: state.closeRequests,
      );
    }
    return existing != null;
  }

  /// Asks page [detailId], when it is open, to go back to the page that
  /// opened it.
  void requestClose(String detailId) {
    state = SettingsPagesState(
      pages: state.pages,
      closeRequests: {
        ...state.closeRequests,
        detailId: (state.closeRequests[detailId] ?? 0) + 1,
      },
    );
  }

  /// Forgets every page, as the native sheet does when it closes.
  void clear() => state = const SettingsPagesState();
}

final settingsSurfaceProvider = Provider<SettingsSurface>(SettingsSurface.new);

/// Where a Settings page update goes: the Flutter pages, and the native
/// sheet, which takes it on iOS while it is open.
class SettingsSurface {
  SettingsSurface(this._ref);

  final Ref _ref;

  /// Patches page [detailId] wherever it is shown. Returns whether a page
  /// with that id was showing to take it.
  Future<bool> applyDetailPatch({
    required String detailId,
    required List<NativeSheetItemConfig> items,
    List<NativeSheetSectionConfig> sections = const [],
    String? title,
    String? subtitle,
    bool clearSubtitle = false,
    List<NativeSheetDetailConfig> detailSheets = const [],
    NativeSheetDetailConfig? whole,
  }) async {
    if (items.isNotEmpty && sections.isNotEmpty) {
      throw ArgumentError(
        'A Settings page patch must use either items or sections, not both.',
      );
    }
    final flutter = _ref
        .read(settingsPagesProvider.notifier)
        .patch(
          detailId: detailId,
          items: items,
          sections: sections,
          title: title,
          subtitle: subtitle,
          clearSubtitle: clearSubtitle,
          detailSheets: detailSheets,
          whole: whole,
        );
    final native = await NativeSheetBridge.instance.applyDetailPatch(
      detailId: detailId,
      items: items,
      sections: sections,
      title: title,
      subtitle: subtitle,
      clearSubtitle: clearSubtitle,
      detailSheets: detailSheets,
      whole: whole,
    );
    return native || flutter;
  }

  /// Closes page [detailId] wherever it is open, back to the page that
  /// opened it: after a save, or once what it showed is gone.
  Future<void> closeDetail(String detailId) async {
    _ref.read(settingsPagesProvider.notifier).requestClose(detailId);
    await NativeSheetBridge.instance.closeDetail(detailId);
  }

  /// Asks [title] where Settings is: over the native sheet while it is up,
  /// as an alert from one of its own rows would be, else as a dialog over
  /// the Flutter pages. Returns the id of the answer chosen, or null when
  /// there was none.
  Future<String?> ask({
    required String title,
    String? message,
    required List<NativeSheetAlertAction> actions,
  }) async {
    final bridge = NativeSheetBridge.instance;
    if (bridge.settingsSheetOpen) {
      return bridge.presentAlert(
        title: title,
        message: message,
        actions: actions,
      );
    }
    final context = NavigationService.context;
    if (context == null || !context.mounted) return null;
    String? chosen;
    await AdaptiveAlertDialog.show(
      context: context,
      title: title,
      message: message,
      actions: [
        for (final action in actions)
          AlertAction(
            title: action.label,
            style: switch (action.style) {
              NativeSheetAlertStyle.normal => AlertActionStyle.defaultAction,
              NativeSheetAlertStyle.cancel => AlertActionStyle.cancel,
              NativeSheetAlertStyle.destructive =>
                AlertActionStyle.destructive,
            },
            onPressed: () => chosen = action.id,
          ),
      ],
    );
    return chosen;
  }

  /// Sends page [detail] as a whole -- its bar actions and discard question
  /// too -- and the pages it leads to.
  Future<bool> applyDetail(
    NativeSheetDetailConfig detail, {
    List<NativeSheetDetailConfig> detailSheets = const [],
  }) => applyDetailPatch(
    detailId: detail.id,
    title: detail.title,
    subtitle: detail.subtitle,
    clearSubtitle: detail.subtitle == null,
    items: detail.items,
    sections: detail.sections,
    detailSheets: detailSheets,
    whole: detail,
  );
}
