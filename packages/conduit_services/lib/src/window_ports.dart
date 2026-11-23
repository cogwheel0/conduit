import 'package:conduit_core/features/chat/providers/chat_handoff_providers.dart'
    show chatHandoffCoordinatorProvider;
import 'package:conduit_core/features/chat/realtime_call/realtime_call_availability.dart'
    show realtimePcmAudioFactoryProvider, realtimeWebRtcMediaFactoryProvider;
import 'package:conduit_core/features/chat/voice_mode/voice_mode_ports.dart'
    show voiceModeInputProvider;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart'
    show
        hermesConfigProvider,
        hermesModelSwitchPromptProvider,
        hostHermesDashboardBridgeFactoryProvider,
        hostHermesDashboardSignOutProvider;
import 'package:conduit_core/ports/secure_key_value_store.dart';
import 'package:conduit_core/providers/host_ports.dart';
import 'package:riverpod/misc.dart' show Override;

import 'apple_models_service.dart' show AppleModelsBridge, appleModelsOverrides;
import 'calls_service.dart' show CallPorts;
import 'hermes_dashboard_cookies.dart';
import 'location_bridge.dart';
import 'ports/handoff.dart';
import 'ports/open_url.dart';
import 'ports/ui_requests.dart';

/// The core's ports that the protocol's windows answer, made together with
/// the container overrides that bind them ([overrides]), so the container
/// and the services always hold the same instances.
final class WindowPorts {
  WindowPorts._({
    required this.openUrl,
    required this.uiRequests,
    required this.handoff,
    required this.calls,
    required this.apple,
    required this.dashboardCookies,
    required this.location,
  });

  /// New ports. With [dashboardCookieStore], a Hermes dashboard's cookies
  /// handed over by a window are kept there ([dashboardCookies]).
  static Future<WindowPorts> open({
    SecureKeyValueStore? dashboardCookieStore,
  }) async {
    final openUrl = DaemonOpenUrlPort();
    final uiRequests = DaemonUiRequestPort();
    final handoff = DaemonHandoffPort();
    final calls = CallPorts();
    final apple = AppleModelsBridge();
    final dashboardCookies = dashboardCookieStore == null
        ? null
        : await DaemonHermesDashboardCookies.open(dashboardCookieStore);
    final location = WindowLocationBridge();
    return WindowPorts._(
      openUrl: openUrl,
      uiRequests: uiRequests,
      handoff: handoff,
      calls: calls,
      apple: apple,
      dashboardCookies: dashboardCookies,
      location: location,
    );
  }

  /// How the core opens a page in the system browser; the services attach
  /// their event bus once there is one.
  final DaemonOpenUrlPort openUrl;

  /// How the core asks the user something mid-turn; the services attach
  /// their broker once there is one.
  final DaemonUiRequestPort uiRequests;

  /// How a server's `chat:handoff` is put to the user; the services attach
  /// their handoff service once there is one.
  final DaemonHandoffPort handoff;

  /// A voice call's microphone and realtime audio: the window, through the
  /// calls service, which attaches once there is one.
  final CallPorts calls;

  /// The window's Foundation Models engine, as the core's Apple host: the
  /// Apple service binds it to the event bus once there is one.
  final AppleModelsBridge apple;

  /// The Hermes dashboard sessions the window's sign-in handed over, and
  /// the core's cookie store; null when the host keeps none.
  final DaemonHermesDashboardCookies? dashboardCookies;

  /// The window's location services, as the core's location port: the
  /// services bind it to the event bus once there is one.
  final WindowLocationBridge location;

  /// What a container needs so the core reaches these ports.
  List<Override> overrides() {
    final cookies = dashboardCookies;
    return <Override>[
      openExternalUrlProvider.overrideWithValue(openUrl),
      uiRequestPortProvider.overrideWithValue(uiRequests),
      // Hermes holding a switch to another model asks the windows, as a
      // phone asks its screen (`hermesModelSwitch`).
      hermesModelSwitchPromptProvider.overrideWithValue(
        uiRequests.confirmHermesModelSwitch,
      ),
      // A server's `chat:handoff` is asked of the windows, which open the
      // new chat themselves; a phone's coordinator asks its screen.
      chatHandoffCoordinatorProvider.overrideWith(handoff.coordinator),
      // A voice call listens through the window (dictation's engines), and
      // for a realtime voice runs the window's echo-cancelled audio, or its
      // WebRTC peer for Hermes GPT-Live.
      voiceModeInputProvider.overrideWithValue(calls.input),
      realtimePcmAudioFactoryProvider.overrideWithValue(calls.newRealtimeAudio),
      realtimeWebRtcMediaFactoryProvider.overrideWithValue(
        calls.newWebRtcMedia,
      ),
      // Apple's on-device model runs in the window (Foundation Models is a
      // Swift API); the core's Apple adapter reaches it through this host,
      // as the phone's reaches its Swift bridge.
      ...appleModelsOverrides(apple),
      // A Desktop Gateway's dashboard sign-in runs in the window's browser
      // window, which hands the cookies over; the host then holds them as a
      // phone's WebView does, and sends the dashboard's requests with them
      // (the phone sends them from a hidden WebView page). Its store holds
      // only those: Open WebUI's sign-in windows keep nothing.
      if (cookies != null) ...<Override>[
        cookieJarProvider.overrideWithValue(cookies),
        hostHermesDashboardBridgeFactoryProvider.overrideWith(
          (ref) =>
              ({
                required Uri root,
                required Map<String, String> accessHeaders,
              }) => cookies.bridge(
                root: root,
                accessHeaders: accessHeaders,
                httpClient: hermesDashboardHttpClientFor(
                  root,
                  ref.read(hermesConfigProvider),
                ),
              ),
        ),
        hostHermesDashboardSignOutProvider.overrideWith(
          (ref) =>
              ({
                required Uri root,
                required Map<String, String> accessHeaders,
              }) => cookies.signOut(
                root: root,
                accessHeaders: accessHeaders,
                httpClient: hermesDashboardHttpClientFor(
                  root,
                  ref.read(hermesConfigProvider),
                ),
              ),
        ),
      ],
      // `{{USER_LOCATION}}` from the window's location services, asked only
      // for a request or a prompt template that names it, and only while the
      // account's location setting is on (the phone asks for every request
      // while it is on).
      ...windowLocationOverrides(location),
    ];
  }
}
