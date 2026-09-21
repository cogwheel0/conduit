import 'package:freezed_annotation/freezed_annotation.dart';

import 'capabilities.dart';

part 'handshake.freezed.dart';
part 'handshake.g.dart';

/// Which window opened this RPC connection.
///
/// Several renderer windows share one daemon, and the daemon broadcasts
/// events to all of them. The kind lets it skip work nobody is looking at —
/// the quick-ask window never needs the sidebar's chat pages.
enum WindowKind {
  /// The full app shell: sidebar, transcript, right pane.
  @JsonValue('main')
  main,

  /// Frameless always-on-top global-hotkey window (WP-9.1).
  @JsonValue('quickAsk')
  quickAsk,

  /// A headless connection used by tests and `conduitd --probe`.
  @JsonValue('headless')
  headless,
}

/// First frame the UI sends after the socket opens.
///
/// Sent as a normal JSON-RPC request (`system.handshake`) rather than as
/// WebSocket subprotocol data: the token check already happened at upgrade
/// time, so this carries only what the daemon needs to shape the session.
@freezed
abstract class HandshakeRequest with _$HandshakeRequest {
  const factory HandshakeRequest({
    /// Must equal the daemon's [kConduitProtocolVersion] exactly.
    required String protocolVersion,
    required String clientName,
    required String clientVersion,
    required WindowKind windowKind,

    /// BCP-47 tag, e.g. `zh-Hant`. The daemon does not localize anything; it
    /// forwards this to the server for `Accept-Language` and stores it so
    /// background notifications can be localized by the UI on click.
    required String locale,
  }) = _HandshakeRequest;

  factory HandshakeRequest.fromJson(Map<String, dynamic> json) =>
      _$HandshakeRequestFromJson(json);
}

/// Filesystem locations the daemon owns, echoed so the UI can show them in
/// Settings > Data & Connection and in exported diagnostics.
@freezed
abstract class DaemonPaths with _$DaemonPaths {
  const factory DaemonPaths({
    required String userData,
    required String database,
    required String cache,
    required String logs,

    /// Where `/upload` streams incoming files before they are handed to the
    /// attachment queue.
    required String staging,
  }) = _DaemonPaths;

  factory DaemonPaths.fromJson(Map<String, dynamic> json) =>
      _$DaemonPathsFromJson(json);
}

/// The daemon's reply to [HandshakeRequest].
@freezed
abstract class HandshakeResponse with _$HandshakeResponse {
  const factory HandshakeResponse({
    required String protocolVersion,
    required String daemonVersion,

    /// Identifies this socket for the lifetime of the connection. Appears in
    /// daemon logs so a user-reported problem can be traced to one window.
    required String sessionId,
    required Capabilities capabilities,
    required DaemonPaths paths,

    /// Host platform as the daemon sees it (`macos`, `windows`, `linux`).
    /// The renderer also gets this from the preload bridge; having it here
    /// keeps headless test clients honest.
    required String platform,

    /// True when this daemon was started fresh and has no server configured
    /// yet, so the UI can route straight to onboarding without a round trip.
    @Default(false) bool needsOnboarding,
  }) = _HandshakeResponse;

  factory HandshakeResponse.fromJson(Map<String, dynamic> json) =>
      _$HandshakeResponseFromJson(json);
}
