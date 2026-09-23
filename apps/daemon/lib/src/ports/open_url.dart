import 'package:conduit_core/ports/external_url_port.dart';
import 'package:conduit_protocol/conduit_protocol.dart';

import '../event_bus.dart';

/// Opens a page in the system browser by asking a window to (M4).
///
/// The daemon has no browser and should not start one itself: Electron
/// already sends every http(s) `window.open` to `shell.openExternal`, so
/// the renderer does that and nothing here has to know how each platform
/// opens a URL. What needs it is an MCP server's OAuth sign-in, whose
/// callback the daemon's loopback listener then receives.
///
/// The container is built before the event bus exists, so the bus is
/// attached afterwards. Until then, and with no window to ask, it refuses,
/// which the OAuth flow reports as "could not open the browser".
final class DaemonOpenUrlPort implements OpenExternalUrlPort {
  EventBus? _events;

  void attach(EventBus events) => _events = events;

  @override
  Future<bool> open(Uri url) async {
    final events = _events;
    if (events == null || events.subscriberCount == 0) return false;
    if (url.scheme != 'https' && url.scheme != 'http') return false;
    events.publish(
      ConduitEvents.openUrl,
      payload: OpenUrl(url: url.toString()).toJson(),
    );
    return true;
  }
}
