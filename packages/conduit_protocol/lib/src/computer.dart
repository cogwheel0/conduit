import 'package:freezed_annotation/freezed_annotation.dart';

part 'computer.freezed.dart';
part 'computer.g.dart';

/// What a chat's terminal shows in the Computer viewer: its desktop, or
/// the browser it drives.
enum ComputerSurfaceKind { desktop, browser }

/// Where a view stands when it opens.
enum ComputerViewState {
  /// Something to watch: the viewer page connects to [ComputerView.streamUrl].
  live,

  /// A browser with no tab: the user may open one.
  empty,

  /// A browser tab the terminal shows through its proxy, which must be
  /// taken over (opened again with its [ComputerView.tabId]) to be watched.
  inactive,

  /// The terminal's browser cannot run Chrome, which watching needs.
  browserUnavailable,
}

/// Params naming the chat whose terminal is meant: `computer.status`,
/// `computer.tabs`.
@freezed
abstract class ComputerScope with _$ComputerScope {
  const factory ComputerScope({required String chatId}) = _ComputerScope;

  factory ComputerScope.fromJson(Map<String, dynamic> json) =>
      _$ComputerScopeFromJson(json);
}

/// Reply to `computer.status`: whether the chat's header offers Computer.
/// Only a saved chat with a terminal selected can, and only with the
/// Computer setting on; the terminal says which surfaces it has.
@freezed
abstract class ComputerStatus with _$ComputerStatus {
  const factory ComputerStatus({
    /// The Computer setting (Settings › Chats) is on.
    @Default(false) bool enabled,
    @Default(false) bool desktop,
    @Default(false) bool browser,
  }) = _ComputerStatus;

  factory ComputerStatus.fromJson(Map<String, dynamic> json) =>
      _$ComputerStatusFromJson(json);
}

/// Params for `computer.open`. Opening never makes anything on its own: a
/// browser tab is selected only with [tabId], and made only with [newTab].
@freezed
abstract class ComputerOpen with _$ComputerOpen {
  const factory ComputerOpen({
    required String chatId,
    required ComputerSurfaceKind surface,

    /// A browser tab to select and watch (which takes it over).
    String? tabId,

    /// Opens a new browser tab and watches it.
    @Default(false) bool newTab,
  }) = _ComputerOpen;

  factory ComputerOpen.fromJson(Map<String, dynamic> json) =>
      _$ComputerOpenFromJson(json);
}

/// Reply to `computer.open`: a view of the surface. When [state] is
/// `live`, [streamUrl] is a socket on this computer that relays the
/// surface; the daemon holds every credential, and the viewer's own auth
/// message is sent on with the account's token put in. [handle] names the
/// view until `computer.close`.
@freezed
abstract class ComputerView with _$ComputerView {
  const factory ComputerView({
    required ComputerSurfaceKind surface,
    @Default(ComputerViewState.live) ComputerViewState state,
    String? handle,
    String? streamUrl,

    /// How the surface streams: `frames` or `vnc`.
    @Default('frames') String transport,

    /// The desktop has sound to play.
    @Default(false) bool audio,

    /// The browser tab shown, or the one waiting to be taken over.
    String? tabId,
    @Default('') String title,
    @Default('') String url,
  }) = _ComputerView;

  factory ComputerView.fromJson(Map<String, dynamic> json) =>
      _$ComputerViewFromJson(json);
}

/// One of a terminal browser's tabs.
@freezed
abstract class ComputerTab with _$ComputerTab {
  const factory ComputerTab({
    required String id,
    @Default('') String title,
    @Default('') String url,
    @Default(false) bool selected,
  }) = _ComputerTab;

  factory ComputerTab.fromJson(Map<String, dynamic> json) =>
      _$ComputerTabFromJson(json);
}

/// Reply to `computer.tabs`.
@freezed
abstract class ComputerTabs with _$ComputerTabs {
  const factory ComputerTabs({
    @Default(<ComputerTab>[]) List<ComputerTab> tabs,
  }) = _ComputerTabs;

  factory ComputerTabs.fromJson(Map<String, dynamic> json) =>
      _$ComputerTabsFromJson(json);
}

/// Params for `computer.closeTab`.
@freezed
abstract class ComputerTabRef with _$ComputerTabRef {
  const factory ComputerTabRef({
    required String chatId,
    required String tabId,
  }) = _ComputerTabRef;

  factory ComputerTabRef.fromJson(Map<String, dynamic> json) =>
      _$ComputerTabRefFromJson(json);
}

/// Params for `computer.shortcut`: a key combination for the surface a
/// view shows, such as `ctrl+c`, `alt+Tab` or `Return`.
@freezed
abstract class ComputerShortcut with _$ComputerShortcut {
  const factory ComputerShortcut({
    required String handle,
    required String key,
  }) = _ComputerShortcut;

  factory ComputerShortcut.fromJson(Map<String, dynamic> json) =>
      _$ComputerShortcutFromJson(json);
}

/// Params naming a view: `computer.close`.
@freezed
abstract class ComputerHandleRef with _$ComputerHandleRef {
  const factory ComputerHandleRef({required String handle}) =
      _ComputerHandleRef;

  factory ComputerHandleRef.fromJson(Map<String, dynamic> json) =>
      _$ComputerHandleRefFromJson(json);
}
