import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/native_sheet_bridge.dart';

/// Settings pages as they were last described, by id.
///
/// Settings is one set of page definitions. iOS draws them in the native
/// sheet; the Flutter Settings pages (Android, and iOS when the sheet cannot
/// open) draw the same definitions from here. A page is known once something
/// registers it -- the root, or a page that leads to it -- exactly as the
/// native sheet only pushes a page it was given.
@immutable
class SettingsPagesState {
  const SettingsPagesState({this.pages = const {}});

  final Map<String, NativeSheetDetailConfig> pages;

  NativeSheetDetailConfig? operator [](String id) => pages[id];

  bool contains(String id) => pages.containsKey(id);
}

final settingsPagesProvider =
    NotifierProvider<SettingsPages, SettingsPagesState>(SettingsPages.new);

class SettingsPages extends Notifier<SettingsPagesState> {
  @override
  SettingsPagesState build() => const SettingsPagesState();

  /// Makes [details] known, replacing any earlier copy of each.
  void register(Iterable<NativeSheetDetailConfig> details) {
    if (details.isEmpty) return;
    state = SettingsPagesState(
      pages: {...state.pages, for (final detail in details) detail.id: detail},
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
  }) {
    final existing = state.pages[detailId];
    final pages = {
      ...state.pages,
      for (final detail in detailSheets) detail.id: detail,
    };
    if (existing != null) {
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
      );
    }
    if (existing != null || detailSheets.isNotEmpty) {
      state = SettingsPagesState(pages: pages);
    }
    return existing != null;
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
        );
    final native = await NativeSheetBridge.instance.applyDetailPatch(
      detailId: detailId,
      items: items,
      sections: sections,
      title: title,
      subtitle: subtitle,
      clearSubtitle: clearSubtitle,
      detailSheets: detailSheets,
    );
    return native || flutter;
  }

  /// Sends page [detail] as a whole, and the pages it leads to.
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
  );
}
