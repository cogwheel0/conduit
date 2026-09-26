import 'package:freezed_annotation/freezed_annotation.dart';

part 'capabilities.freezed.dart';
part 'capabilities.g.dart';

/// What the currently connected core can actually do.
///
/// The UI gates navigation and affordances on these flags rather than probing
/// the server itself: capability detection is server- and build-dependent
/// (an Open WebUI version, a Hermes deployment, a macOS-only helper), and
/// duplicating that logic in the renderer is exactly the drift the workspace
/// rules exist to stop.
///
/// A flat struct is safe here because [kConduitProtocolVersion] demands strict
/// equality — the daemon and the UI are always the same build, so there is no
/// "older peer sees an unknown flag" case to design around.
@freezed
abstract class Capabilities with _$Capabilities {
  const factory Capabilities({
    // Sidebar sections. Each gates a whole navigation entry.
    @Default(false) bool workspace,
    @Default(false) bool notes,
    @Default(false) bool channels,
    @Default(false) bool hermes,
    @Default(false) bool terminal,

    // Connection kinds.
    @Default(false) bool directConnections,
    @Default(false) bool mcp,

    // Speech. `serverStt` follows the active server's audio config;
    // `onDeviceStt` says whether this computer can transcribe on its own.
    @Default(false) bool serverStt,
    @Default(false) bool onDeviceStt,
    @Default(false) bool serverTts,
    @Default(false) bool deviceTts,

    // macOS Apple helper. `applePcc` stays false unless Apple grants
    // the entitlement, so the UI must treat it as independent of
    // `appleOnDeviceModels`.
    @Default(false) bool appleOnDeviceModels,
    @Default(false) bool applePcc,

    // Parity-plus. Desktop-only at first; the mobile app can flip
    // these on later against the same core methods.
    @Default(false) bool branchNavigation,
    @Default(false) bool messageRating,
    @Default(false) bool tags,
    @Default(false) bool bulkSelection,
  }) = _Capabilities;

  factory Capabilities.fromJson(Map<String, dynamic> json) =>
      _$CapabilitiesFromJson(json);

  /// Everything off. The state a fresh daemon reports before a server is
  /// selected, and the safe default if a capability probe fails.
  static const Capabilities none = Capabilities();
}
