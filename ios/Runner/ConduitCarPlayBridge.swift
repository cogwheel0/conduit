import Flutter
import Foundation

struct ConduitCarPlayVoiceSnapshot {
  let phase: String
  let isActive: Bool
  let canPause: Bool
  let canResume: Bool
  let isMuted: Bool
  let error: String?

  static let idle = ConduitCarPlayVoiceSnapshot(
    phase: "idle",
    isActive: false,
    canPause: false,
    canResume: false,
    isMuted: false,
    error: nil
  )

  init(
    phase: String,
    isActive: Bool,
    canPause: Bool,
    canResume: Bool,
    isMuted: Bool,
    error: String?
  ) {
    self.phase = phase
    self.isActive = isActive
    self.canPause = canPause
    self.canResume = canResume
    self.isMuted = isMuted
    self.error = error
  }

  init?(payload: [String: Any]) {
    guard let phase = payload["phase"] as? String else {
      return nil
    }

    self.phase = phase
    isActive = payload["isActive"] as? Bool ?? false
    canPause = payload["canPause"] as? Bool ?? false
    canResume = payload["canResume"] as? Bool ?? false
    isMuted = payload["isMuted"] as? Bool ?? false
    error = payload["error"] as? String
  }
}

struct ConduitCarPlayActionResult {
  let success: Bool
  let error: String?
  let snapshot: ConduitCarPlayVoiceSnapshot?

  static let unavailable = ConduitCarPlayActionResult(
    success: false,
    error: "Conduit is still starting.",
    snapshot: nil
  )

  static let startTimedOut = ConduitCarPlayActionResult(
    success: false,
    error: "Conduit did not finish starting. Try again in a moment.",
    snapshot: nil
  )

  static let disconnected = ConduitCarPlayActionResult(
    success: false,
    error: "CarPlay disconnected.",
    snapshot: nil
  )

  static let idle = ConduitCarPlayActionResult(
    success: true,
    error: nil,
    snapshot: .idle
  )
}

final class ConduitCarPlayBridge {
  static let shared = ConduitCarPlayBridge()

  private let channelName = "conduit/carplay"
  private let pendingStartTimeout: TimeInterval = 10
  private var channel: FlutterMethodChannel?
  private var isDartHandlerReady = false
  private var isDartReadinessProbeInFlight = false
  private var nextPendingStartID = 0
  private var pendingStarts: [Int: (ConduitCarPlayActionResult) -> Void] = [:]
  private(set) var latestSnapshot = ConduitCarPlayVoiceSnapshot.idle
  var isConfigured: Bool { channel != nil }
  var onSnapshotChanged: ((ConduitCarPlayVoiceSnapshot) -> Void)?

  private init() {}

  func configure(messenger: FlutterBinaryMessenger) {
    channel?.setMethodCallHandler(nil)
    let methodChannel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    isDartHandlerReady = false
    isDartReadinessProbeInFlight = false
    channel = methodChannel
    probeDartHandlerReadinessIfPossible()
  }

  func startVoiceConversation(
    completion: @escaping (ConduitCarPlayActionResult) -> Void
  ) {
    guard channel != nil, isDartHandlerReady else {
      queuePendingStart(completion)
      return
    }

    invoke("startVoiceConversation", completion: completion)
  }

  func endVoiceConversation(
    completion: @escaping (ConduitCarPlayActionResult) -> Void
  ) {
    cancelPendingStarts(with: .idle)
    guard isDartHandlerReady || latestSnapshot.isActive else {
      DispatchQueue.main.async {
        completion(.idle)
      }
      return
    }

    invoke("endVoiceConversation", completion: completion)
  }

  func pauseVoiceConversation(
    completion: @escaping (ConduitCarPlayActionResult) -> Void
  ) {
    invoke("pauseVoiceConversation", completion: completion)
  }

  func resumeVoiceConversation(
    completion: @escaping (ConduitCarPlayActionResult) -> Void
  ) {
    invoke("resumeVoiceConversation", completion: completion)
  }

  func carPlaySceneDidConnect(
    completion: ((ConduitCarPlayActionResult) -> Void)? = nil
  ) {
    invoke("carPlaySceneDidConnect") { result in
      completion?(result)
    }
  }

  func carPlaySceneDidDisconnect(
    completion: ((ConduitCarPlayActionResult) -> Void)? = nil
  ) {
    cancelPendingStarts(with: .disconnected)
    invoke("carPlaySceneDidDisconnect") { result in
      completion?(result)
    }
  }

  private func flushPendingStarts() {
    guard !pendingStarts.isEmpty else { return }

    let completions = Array(pendingStarts.values)
    pendingStarts.removeAll()

    for completion in completions {
      startVoiceConversation(completion: completion)
    }
  }

  private func cancelPendingStarts(with result: ConduitCarPlayActionResult) {
    guard !pendingStarts.isEmpty else { return }

    let completions = Array(pendingStarts.values)
    pendingStarts.removeAll()

    for completion in completions {
      completion(result)
    }
  }

  private func queuePendingStart(
    _ completion: @escaping (ConduitCarPlayActionResult) -> Void
  ) {
    let id = nextPendingStartID
    nextPendingStartID += 1
    pendingStarts[id] = completion
    probeDartHandlerReadinessIfPossible()

    DispatchQueue.main.asyncAfter(deadline: .now() + pendingStartTimeout) { [weak self] in
      guard
        let self,
        let completion = self.pendingStarts.removeValue(forKey: id)
      else {
        return
      }
      completion(.startTimedOut)
    }
  }

  private func probeDartHandlerReadinessIfPossible() {
    guard
      channel != nil,
      !isDartHandlerReady,
      !isDartReadinessProbeInFlight
    else {
      return
    }

    isDartReadinessProbeInFlight = true
    invoke("carPlaySceneDidConnect") { [weak self] result in
      guard let self else { return }
      self.isDartReadinessProbeInFlight = false
      guard result.success else { return }
      self.markDartHandlerReadyOnMain()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "carPlayDartReady":
      markDartHandlerReady()
      result(nil)
    case "voiceConversationStateChanged":
      guard
        let payload = call.arguments as? [String: Any],
        let snapshot = ConduitCarPlayVoiceSnapshot(payload: payload)
      else {
        result(FlutterError(
          code: "invalid_state",
          message: "Invalid CarPlay voice conversation state.",
          details: nil
        ))
        return
      }

      update(snapshot)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func update(_ snapshot: ConduitCarPlayVoiceSnapshot) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      latestSnapshot = snapshot
      onSnapshotChanged?(snapshot)
      markDartHandlerReadyOnMain()
    }
  }

  private func markDartHandlerReady() {
    DispatchQueue.main.async { [weak self] in
      self?.markDartHandlerReadyOnMain()
    }
  }

  private func markDartHandlerReadyOnMain() {
    guard !isDartHandlerReady else { return }
    isDartHandlerReady = true
    flushPendingStarts()
  }

  private func invoke(
    _ method: String,
    completion: @escaping (ConduitCarPlayActionResult) -> Void
  ) {
    guard let channel = channel else {
      DispatchQueue.main.async {
        completion(.unavailable)
      }
      return
    }

    channel.invokeMethod(method, arguments: nil) { [weak self] response in
      let result = Self.decode(response)
      DispatchQueue.main.async {
        if result.success, let snapshot = result.snapshot {
          self?.latestSnapshot = snapshot
          self?.onSnapshotChanged?(snapshot)
        }
        completion(result)
      }
    }
  }

  private static func decode(_ response: Any?) -> ConduitCarPlayActionResult {
    if let error = response as? FlutterError {
      return ConduitCarPlayActionResult(
        success: false,
        error: error.message ?? error.code,
        snapshot: nil
      )
    }

    guard let payload = response as? [String: Any] else {
      return ConduitCarPlayActionResult(
        success: false,
        error: "Invalid response.",
        snapshot: nil
      )
    }

    return ConduitCarPlayActionResult(
      success: payload["success"] as? Bool ?? false,
      error: payload["error"] as? String,
      snapshot: (payload["state"] as? [String: Any]).flatMap(ConduitCarPlayVoiceSnapshot.init(payload:))
    )
  }
}
