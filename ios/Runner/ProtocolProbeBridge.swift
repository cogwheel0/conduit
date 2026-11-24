#if DEBUG
import Flutter
import UIKit

/// Debug builds only: a probe of the in-app protocol host, which a build with
/// `--dart-define=CONDUIT_PROTOCOL_HOST=true` starts on the Dart side
/// (`lib/platform/protocol_channel_host.dart`). No UI.
///
/// Once the Dart side says it is ready and a window of the app is in front,
/// it opens a session, handshakes, lists the chats and logs
/// `[protocol-probe] ok N chats`, or `[protocol-probe] failed <reason>`. It
/// logs counts and error codes only, never a title, an id, an address or any
/// other content. Without the define the Dart side never answers, and the
/// probe logs nothing. The session stays open afterwards.
///
/// A CarPlay-only launch has no window in front, so it never opens a
/// session, and the host is never built.
final class ProtocolProbeBridge: ConduitBridge {
  static let shared = ProtocolProbeBridge()

  private weak var host: ConduitBridgeHost?
  private var control: FlutterBasicMessageChannel?
  private var rpc: FlutterBasicMessageChannel?
  private var session: String?
  private var nextId = 1
  private var pending: [Int: ([String: Any]) -> Void] = [:]
  private var activation: NSObjectProtocol?

  @MainActor func attach(to host: ConduitBridgeHost) {
    self.host = host
    forgetSession()
    let control = FlutterBasicMessageChannel(
      name: "conduit/protocol/control",
      binaryMessenger: host.messenger,
      codec: FlutterStandardMessageCodec.sharedInstance()
    )
    let rpc = FlutterBasicMessageChannel(
      name: "conduit/protocol/rpc",
      binaryMessenger: host.messenger,
      codec: FlutterStringCodec.sharedInstance()
    )
    // Handlers before the first message: one Dart sends to no handler is lost.
    control.setMessageHandler { [weak self] message, reply in
      reply(nil)
      guard let self, let message = message as? [String: Any] else { return }
      switch message["op"] as? String {
      case "ready":
        self.ready(protocolVersion: message["protocolVersion"] as? String)
      case "closed":
        if message["session"] as? String == self.session {
          self.forgetSession()
        }
      default:
        break
      }
    }
    rpc.setMessageHandler { [weak self] message, reply in
      // Taken: the host counts this answer as the acknowledgement.
      reply("")
      guard let self, let message = message as? String else { return }
      self.received(message)
    }
    self.control = control
    self.rpc = rpc
    control.sendMessage(["op": "hello"]) { [weak self] reply in
      guard let reply = reply as? [String: Any], reply["op"] as? String == "ready"
      else { return }
      self?.ready(protocolVersion: reply["protocolVersion"] as? String)
    }
  }

  /// The Dart side is up, the first time or again after a restart, when its
  /// sessions are gone.
  private func ready(protocolVersion: String?) {
    guard let protocolVersion else { return }
    forgetSession()
    whenWindowInFront { [weak self] in self?.open(protocolVersion: protocolVersion) }
  }

  private func whenWindowInFront(_ run: @escaping () -> Void) {
    if let activation { NotificationCenter.default.removeObserver(activation) }
    activation = nil
    if host?.activeWindowScene != nil {
      run()
      return
    }
    activation = NotificationCenter.default.addObserver(
      forName: UIScene.didActivateNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self, note.object is UIWindowScene else { return }
      if let activation = self.activation {
        NotificationCenter.default.removeObserver(activation)
      }
      self.activation = nil
      run()
    }
  }

  private func open(protocolVersion: String) {
    guard session == nil else { return }
    let id = "probe-\(UUID().uuidString)"
    control?.sendMessage(["op": "open", "session": id]) { [weak self] reply in
      guard let self else { return }
      guard let reply = reply as? [String: Any], reply["ok"] as? Bool == true else {
        self.log("failed open")
        return
      }
      self.session = id
      let handshake: [String: Any] = [
        "protocolVersion": protocolVersion,
        "clientName": "protocol-probe",
        "clientVersion": "1",
        "windowKind": "main",
        "locale": Locale.current.identifier,
      ]
      self.request("system.handshake", handshake) { _ in
        self.request("chats.list", nil) { result in
          let chats = (result["chats"] as? [Any])?.count ?? 0
          self.log("ok \(chats) chats")
        }
      }
    }
  }

  private func request(
    _ method: String,
    _ params: [String: Any]?,
    then: @escaping ([String: Any]) -> Void
  ) {
    guard let session else { return }
    let id = nextId
    nextId += 1
    var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params { message["params"] = params }
    guard let data = try? JSONSerialization.data(withJSONObject: message),
      let json = String(data: data, encoding: .utf8)
    else {
      log("failed encoding")
      return
    }
    pending[id] = then
    rpc?.sendMessage("\(session)\n\(json)") { [weak self] reply in
      if reply as? String == "closed" {
        self?.log("failed session gone")
      }
    }
  }

  private func received(_ message: String) {
    guard let newline = message.firstIndex(of: "\n"),
      String(message[..<newline]) == session,
      let data = String(message[message.index(after: newline)...]).data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let id = object["id"] as? Int,
      let then = pending.removeValue(forKey: id)
    else { return }
    if let error = object["error"] as? [String: Any] {
      // The JSON-RPC code only: the message may carry content.
      log("failed \(error["code"] as? Int ?? 0)")
      return
    }
    then(object["result"] as? [String: Any] ?? [:])
  }

  private func forgetSession() {
    session = nil
    pending = [:]
  }

  private func log(_ line: String) {
    NSLog("[protocol-probe] %@", line)
  }
}
#endif
