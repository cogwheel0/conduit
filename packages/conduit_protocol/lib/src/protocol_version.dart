/// The wire contract version shared by `conduitd` and the desktop UI.
///
/// The handshake requires *strict equality*: the daemon and the UI are built
/// and shipped from the same commit, so a mismatch means a stale binary is
/// running and the only safe move is to refuse the connection rather than
/// guess which side is older.
///
/// Bump this whenever a method, event, or DTO changes shape in a way that an
/// older peer would misread.
const String kConduitProtocolVersion = '1.18.0';

/// The WebSocket subprotocol token that identifies a Conduit RPC client.
///
/// Sent alongside the session token so the daemon can reject sockets from any
/// other local page before the JSON-RPC peer is ever created.
const String kConduitSubprotocol = 'conduit.v1';

/// The only [Uri] origin the daemon accepts WebSocket upgrades from.
///
/// Electron serves the Jaspr bundle from this custom scheme, so requiring it
/// blocks cross-site WebSocket hijacking from any page the user happens to
/// have open in a real browser.
const String kConduitAppOrigin = 'app://conduit';
