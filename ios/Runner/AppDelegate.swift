import AVFoundation
import BackgroundTasks
import CryptoKit
import Darwin
import Flutter
import AppIntents
import UIKit
import UniformTypeIdentifiers
import WebKit

private func appLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}

private let conduitShareChannelName = "conduit/share_receiver_text"
private let conduitShareAppGroupIdKey = "AppGroupId"
private let conduitVoiceAudioRouteChannelName = "app.cogwheel.conduit/voice_audio_route"
private let nativeIosTtsMethodChannelName = "app.cogwheel.conduit/native_ios_tts"
private let nativeIosTtsEventChannelName = "app.cogwheel.conduit/native_ios_tts/events"

func nativeSharedPayloadTypeIsText(_ type: Any?) -> Bool {
  if let type = type as? String {
    return type == "text" || type == "url"
  }
  if let type = type as? NSNumber {
    // JSON booleans bridge through NSNumber, where false.intValue is 0 and
    // true.intValue is 1. They are not valid share-media type codes.
    guard CFGetTypeID(type) != CFBooleanGetTypeID() else { return false }
    let value = type.intValue
    return value == 0 || value == 1 || value == 5
  }
  if let type = type as? Int {
    return type == 0 || type == 1 || type == 5
  }
  return false
}

/// Builds the acknowledgement-bearing payload only from a complete native
/// record. Returning content without its durable status identifier would make
/// the record impossible for Dart to acknowledge and permanently wedge the
/// pending-share signal.
func nativeValidatedShareImportPayload(
  rawItems: [[String: Any]],
  message: String?,
  status: [String: Any]?,
  shareStagingDirectoryPath: String?
) -> [String: Any]? {
  guard let id = (status?["id"] as? String)?
    .trimmingCharacters(in: .whitespacesAndNewlines),
    !id.isEmpty else {
    return nil
  }

  var textParts: [String] = []
  var seenText = Set<String>()
  var filePaths: [String] = []
  var seenFilePaths = Set<String>()

  func addText(_ value: String?) {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty,
          seenText.insert(trimmed).inserted else { return }
    textParts.append(trimmed)
  }

  func addFilePath(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !value.isEmpty else { return false }

    let path: String
    if value.lowercased().hasPrefix("file:") {
      guard let url = URL(string: value), url.isFileURL,
            url.host == nil || url.host?.isEmpty == true ||
              url.host?.lowercased() == "localhost" else {
        return false
      }
      path = url.standardizedFileURL.path
    } else {
      guard value.hasPrefix("/") else { return false }
      path = URL(fileURLWithPath: value).standardizedFileURL.path
    }
    guard !path.isEmpty, path.hasPrefix("/"),
          let rawRoot = shareStagingDirectoryPath,
          rawRoot.hasPrefix("/") else { return false }
    let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
      .resolvingSymlinksInPath()
      .standardizedFileURL
    let candidate = URL(fileURLWithPath: path).standardizedFileURL
    let canonicalCandidate = candidate.resolvingSymlinksInPath()
      .standardizedFileURL
    guard canonicalCandidate.deletingLastPathComponent().path == root.path else {
      return false
    }
    var rootMetadata = stat()
    var candidateMetadata = stat()
    guard root.path.withCString({ lstat($0, &rootMetadata) }) == 0,
          rootMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
          candidate.path.withCString({ lstat($0, &candidateMetadata) }) == 0,
          candidateMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
      return false
    }
    if seenFilePaths.insert(canonicalCandidate.path).inserted {
      filePaths.append(canonicalCandidate.path)
    }
    return true
  }

  addText(message)
  for item in rawItems {
    // Every encoded media entry must carry both its type and content. Treat a
    // partially decoded map as corruption instead of silently returning an
    // unacknowledgeable or truncated handoff.
    guard item["type"] != nil,
          let value = item["path"] as? String ?? item["value"] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    if nativeSharedPayloadTypeIsText(item["type"]) {
      addText(value)
    } else {
      guard addFilePath(value) else { return nil }
    }
  }

  guard !textParts.isEmpty || !filePaths.isEmpty else { return nil }
  var payload: [String: Any] = [
    "id": id,
    "filePaths": filePaths,
  ]
  if !textParts.isEmpty {
    payload["text"] = textParts.joined(separator: "\n")
  }
  return payload
}

/// Manages AVAudioSession for voice calls in the background.
///
/// IMPORTANT: This manager is ONLY used for server-side STT (speech-to-text).
/// When using local STT, the native recognizer path manages its own audio
/// session. Do NOT activate this manager when local STT is in use to avoid
/// audio session conflicts.
///
/// The voice_call_service.dart checks `useServerMic` before calling
/// startBackgroundExecution with requiresMicrophone:true.
final class VoiceBackgroundAudioManager {
    static let shared = VoiceBackgroundAudioManager()

    private var isActive = false
    private let lock = NSLock()
    
    /// Flag indicating another component owns the audio session.
    /// When true, this manager will skip activation to avoid conflicts.
    private var externalSessionOwner = false

    private init() {}
    
    /// Mark that an external component is managing the audio session.
    /// Call this before starting local STT to prevent conflicts.
    func setExternalSessionOwner(_ isExternal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        externalSessionOwner = isExternal
        
        if isExternal {
            print("VoiceBackgroundAudioManager: External session owner active, deferring to external management")
        }
    }
    
    /// Check if an external component owns the audio session.
    var hasExternalSessionOwner: Bool {
        lock.lock()
        defer { lock.unlock() }
        return externalSessionOwner
    }

    func activate() {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isActive else { return }
        
        // Skip if another component is managing the audio session
        if externalSessionOwner {
            print("VoiceBackgroundAudioManager: Skipping activation - external session owner active")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // Check current category to avoid unnecessary reconfiguration
            // This helps prevent conflicts if local STT already configured the session.
            let currentCategory = session.category
            let needsReconfiguration = currentCategory != .playAndRecord
            
            if needsReconfiguration {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [
                        // Keep the session on duplex-capable routes while the
                        // server-side recorder is streaming PCM from the mic.
                        .allowBluetoothHFP,
                        .defaultToSpeaker,
                    ]
                )
            }
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            isActive = true
        } catch {
            print("VoiceBackgroundAudioManager: Failed to activate audio session: \(error)")
        }
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        
        guard isActive else { return }
        
        // Don't deactivate if external owner - they manage their own lifecycle
        if externalSessionOwner {
            print("VoiceBackgroundAudioManager: Skipping deactivation - external session owner active")
            isActive = false
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("VoiceBackgroundAudioManager: Failed to deactivate audio session: \(error)")
        }

        isActive = false
    }
    
    /// Check if audio session is currently active (thread-safe).
    var isSessionActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }
}

final class VoiceAudioRouteBridge {
    static let shared = VoiceAudioRouteBridge()

    private var methodChannel: FlutterMethodChannel?

    private init() {}

    deinit {}

    func configure(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: conduitVoiceAudioRouteChannelName,
            binaryMessenger: messenger
        )
        methodChannel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(nil)
                return
            }

            switch call.method {
            case "preferBluetoothHfpInput":
                result(self.preferBluetoothHfpInput())
            case "clearPreferredInput":
                result(self.clearPreferredInput())
            case "currentRoute":
                result(self.currentRoutePayload(operation: "currentRoute"))
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func preferBluetoothHfpInput() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let availableInputs = session.availableInputs ?? []
        guard let bluetoothInput = availableInputs.first(where: { $0.portType == .bluetoothHFP }) else {
            var payload = currentRoutePayload(operation: "preferBluetoothHfpInput")
            payload["selected"] = false
            payload["reason"] = "bluetooth-hfp-input-unavailable"
            payload["availableInputs"] = availableInputs.map { portPayload($0) }
            return payload
        }

        do {
            try session.setPreferredInput(bluetoothInput)
            var payload = currentRoutePayload(
                operation: "preferBluetoothHfpInput",
                preferredInput: bluetoothInput
            )
            payload["selected"] = true
            payload["availableInputs"] = availableInputs.map { portPayload($0) }
            return payload
        } catch {
            var payload = currentRoutePayload(
                operation: "preferBluetoothHfpInput",
                preferredInput: bluetoothInput
            )
            payload["selected"] = false
            payload["error"] = error.localizedDescription
            payload["availableInputs"] = availableInputs.map { portPayload($0) }
            return payload
        }
    }

    private func clearPreferredInput() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setPreferredInput(nil)
            var payload = currentRoutePayload(operation: "clearPreferredInput")
            payload["cleared"] = true
            return payload
        } catch {
            var payload = currentRoutePayload(operation: "clearPreferredInput")
            payload["cleared"] = false
            payload["error"] = error.localizedDescription
            return payload
        }
    }

    private func currentRoutePayload(
        operation: String,
        preferredInput: AVAudioSessionPortDescription? = nil
    ) -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        var payload: [String: Any] = [
            "operation": operation,
            "category": session.category.rawValue,
            "mode": session.mode.rawValue,
            "sampleRate": session.sampleRate,
            "currentInputs": session.currentRoute.inputs.map { portPayload($0) },
            "currentOutputs": session.currentRoute.outputs.map { portPayload($0) },
        ]

        if let preferredInput {
            payload["preferredInput"] = portPayload(preferredInput)
        } else if let preferredInput = session.preferredInput {
            payload["preferredInput"] = portPayload(preferredInput)
        }

        return payload
    }

    private func portPayload(_ port: AVAudioSessionPortDescription) -> [String: Any] {
        [
            "type": port.portType.rawValue,
            "uid": port.uid,
        ]
    }
}

final class NativeIosTtsBridge: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
    static let shared = NativeIosTtsBridge()

    private let synthesizer = AVSpeechSynthesizer()
    private var methodChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {}

    func configure(messenger: FlutterBinaryMessenger) {
        let methodChannel = FlutterMethodChannel(
            name: nativeIosTtsMethodChannelName,
            binaryMessenger: messenger
        )
        self.methodChannel = methodChannel
        methodChannel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }

        FlutterEventChannel(
            name: nativeIosTtsEventChannelName,
            binaryMessenger: messenger
        ).setStreamHandler(self)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)
        case "getVoices":
            loadVoicesForPicker(result: result)
        case "speak":
            guard let arguments = call.arguments as? [String: Any],
                  let text = arguments["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                result(false)
                return
            }

            if synthesizer.isSpeaking || synthesizer.isPaused {
                synthesizer.stopSpeaking(at: .immediate)
            }

            let utterance = AVSpeechUtterance(string: text)
            if let identifier = arguments["voiceIdentifier"] as? String,
               !identifier.isEmpty,
               let voice = resolveVoice(identifier) {
                utterance.voice = voice
            }
            utterance.rate = Self.speechRate(from: arguments["rate"])
            utterance.pitchMultiplier = Self.floatValue(
                arguments["pitch"],
                fallback: 1.0,
                min: 0.5,
                max: 2.0
            )
            utterance.volume = Self.floatValue(
                arguments["volume"],
                fallback: 1.0,
                min: 0.0,
                max: 1.0
            )
            synthesizer.speak(utterance)
            result(true)
        case "stop":
            result(synthesizer.stopSpeaking(at: .immediate))
        case "pause":
            result(synthesizer.pauseSpeaking(at: .word))
        case "resume":
            result(synthesizer.continueSpeaking())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func loadVoicesForPicker(result: @escaping FlutterResult) {
        if #available(iOS 17.0, *),
           AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .notDetermined {
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] _ in
                DispatchQueue.main.async {
                    result(self?.availableVoicePayloads() ?? [])
                }
            }
            return
        }

        result(availableVoicePayloads())
    }

    private func availableVoicePayloads() -> [[String: Any]] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { left, right in
                let leftLanguage = left.language.localizedCaseInsensitiveCompare(right.language)
                if leftLanguage != .orderedSame {
                    return leftLanguage == .orderedAscending
                }

                let leftName = left.name.localizedCaseInsensitiveCompare(right.name)
                if leftName != .orderedSame {
                    return leftName == .orderedAscending
                }

                return left.identifier.localizedCaseInsensitiveCompare(right.identifier) == .orderedAscending
            }
            .map(voicePayload)
    }

    private func voicePayload(_ voice: AVSpeechSynthesisVoice) -> [String: Any] {
        var payload: [String: Any] = [
            "id": voice.identifier,
            "identifier": voice.identifier,
            "name": voice.name,
            "displayName": displayName(for: voice),
            "locale": voice.language,
            "language": voice.language,
            "languageName": Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language,
            "quality": voice.quality.rawValue,
            "qualityName": qualityName(voice.quality),
            "gender": voice.gender.rawValue,
        ]

        if #available(iOS 17.0, *) {
            let traits = voice.voiceTraits
            let isPersonalVoice = traits.contains(.isPersonalVoice)
            let isNoveltyVoice = traits.contains(.isNoveltyVoice)
            payload["isPersonalVoice"] = isPersonalVoice
            payload["isNoveltyVoice"] = isNoveltyVoice
            payload["traits"] = voiceTraitNames(
                isPersonalVoice: isPersonalVoice,
                isNoveltyVoice: isNoveltyVoice
            )
        }

        return payload
    }

    private func displayName(for voice: AVSpeechSynthesisVoice) -> String {
        if #available(iOS 17.0, *) {
            if voice.voiceTraits.contains(.isPersonalVoice) {
                return "\(voice.name) (Personal Voice)"
            }
            if voice.voiceTraits.contains(.isNoveltyVoice) {
                return "\(voice.name) (Novelty)"
            }
        }

        return voice.name
    }

    private func voiceTraitNames(isPersonalVoice: Bool, isNoveltyVoice: Bool) -> [String] {
        var names: [String] = []
        if isPersonalVoice {
            names.append("personal")
        }
        if isNoveltyVoice {
            names.append("novelty")
        }
        return names
    }

    private func resolveVoice(_ requested: String) -> AVSpeechSynthesisVoice? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let voice = AVSpeechSynthesisVoice(identifier: trimmed) {
            return voice
        }

        let normalized = trimmed.lowercased()
        if let exact = AVSpeechSynthesisVoice.speechVoices().first(where: { voice in
            voice.identifier.lowercased() == normalized ||
                voice.name.lowercased() == normalized ||
                voice.language.lowercased() == normalized
        }) {
            return exact
        }

        return AVSpeechSynthesisVoice(language: trimmed)
    }

    private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default:
            return "Default"
        case .enhanced:
            return "Enhanced"
        case .premium:
            return "Premium"
        @unknown default:
            return "Unknown"
        }
    }

    private static func speechRate(from raw: Any?) -> Float {
        let requested = floatValue(
            raw,
            fallback: AVSpeechUtteranceDefaultSpeechRate,
            min: AVSpeechUtteranceMinimumSpeechRate,
            max: AVSpeechUtteranceMaximumSpeechRate
        )
        return requested
    }

    private static func floatValue(
        _ raw: Any?,
        fallback: Float,
        min: Float,
        max: Float
    ) -> Float {
        let value: Float
        if let number = raw as? NSNumber {
            value = number.floatValue
        } else if let double = raw as? Double {
            value = Float(double)
        } else if let string = raw as? String, let parsed = Float(string) {
            value = parsed
        } else {
            value = fallback
        }
        return Swift.min(Swift.max(value, min), max)
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        emit(["type": "start"])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        emit(["type": "complete"])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        emit(["type": "cancel"])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        emit(["type": "pause"])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        emit(["type": "continue"])
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        emit([
            "type": "progress",
            "start": characterRange.location,
            "end": characterRange.location + characterRange.length,
        ])
    }
}

private struct BackgroundStreamingLease {
    let id: String
    let kind: String
    let requiresMicrophone: Bool
    let startedAtMillis: Int64

    var isChat: Bool { kind == "chat" }
    var isVoice: Bool { kind == "voice" }
    var isSocket: Bool { id == "socket-keepalive" }
}

private extension PlatformBackgroundStreamKind {
    var payloadName: String {
        switch self {
        case .chat: "chat"
        case .voice: "voice"
        }
    }
}

private extension BackgroundStreamingLease {
    init(_ lease: PlatformBackgroundStreamLease) {
        id = lease.id
        kind = lease.kind.payloadName
        requiresMicrophone = lease.requiresMicrophone
        startedAtMillis = lease.startedAtMillis
    }

    func asPlatformLease() -> PlatformBackgroundStreamLease {
        PlatformBackgroundStreamLease(
            id: id,
            kind: isVoice ? .voice : .chat,
            requiresMicrophone: requiresMicrophone,
            startedAtMillis: startedAtMillis
        )
    }
}

private final class BGProcessingCompletionState {
    var completed = false
}

// Background streaming handler class
@MainActor
class BackgroundStreamingHandler: NSObject, BackgroundStreamingHostApi {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var bgProcessingTask: BGTask?
    private var activeLeases: [String: BackgroundStreamingLease] = [:]
    private var flutterApi: BackgroundStreamingFlutterApi?

    static let processingTaskIdentifier = "app.cogwheel.conduit.refresh"

    override init() {
        super.init()
        setupNotifications()
    }
    
    func setup(messenger: FlutterBinaryMessenger) {
        flutterApi = BackgroundStreamingFlutterApi(binaryMessenger: messenger)
        BackgroundStreamingHostApiSetup.setUp(
            binaryMessenger: messenger,
            api: self
        )
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func appDidEnterBackground() {
        if hasBackgroundExecutionLeases {
            startBackgroundTask()
            if hasChatLeases {
                scheduleBGProcessingTask()
            }
        }
    }
    
    @objc private func appWillEnterForeground() {
        endBackgroundTask()
    }
    
    func startBackgroundExecution(request: PlatformBackgroundStartRequest) throws {
        startBackgroundExecution(
            leases: parseLeases(
                request.leases,
                streamIds: request.streamIds,
                requiresMic: request.requiresMicrophone
            )
        )
    }

    func stopBackgroundExecution(request: PlatformBackgroundStopRequest) throws {
        stopBackgroundExecution(streamIds: request.streamIds)
    }

    func keepAlive(request: PlatformBackgroundKeepAliveRequest) throws {
        keepAlive()
    }

    func checkBackgroundRefreshStatus() throws -> Bool {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available:
            return true
        case .denied, .restricted:
            return false
        @unknown default:
            return true
        }
    }

    func checkNotificationPermission() throws -> Bool {
        true
    }

    func setExternalAudioSessionOwner(
        request: PlatformBackgroundAudioSessionOwnerRequest
    ) throws {
        VoiceBackgroundAudioManager.shared.setExternalSessionOwner(
            request.isExternal
        )
    }

    func getActiveStreamCount() throws -> Int64 {
        Int64(activeLeases.count)
    }

    func getActiveStreamLeases() throws -> [PlatformBackgroundStreamLease] {
        activeLeases.values.map { $0.asPlatformLease() }
    }

    func stopAllBackgroundExecution() throws {
        stopBackgroundExecution(streamIds: Array(activeLeases.keys))
    }
    
    private var hasChatLeases: Bool {
        activeLeases.values.contains { $0.isChat && !$0.isSocket }
    }

    private var hasBackgroundExecutionLeases: Bool {
        activeLeases.values.contains {
            !$0.isSocket && ($0.isChat || $0.isVoice)
        }
    }

    private var hasMicrophoneLeases: Bool {
        activeLeases.values.contains { $0.requiresMicrophone }
    }

    private func parseLeases(
        _ rawLeases: [PlatformBackgroundStreamLease],
        streamIds: [String],
        requiresMic: Bool
    ) -> [BackgroundStreamingLease] {
        if !rawLeases.isEmpty {
            return rawLeases.compactMap { lease in
                guard lease.id != "socket-keepalive" else { return nil }
                return BackgroundStreamingLease(lease)
            }
        }

        let startedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        return streamIds.compactMap { id in
            guard id != "socket-keepalive" else { return nil }
            return BackgroundStreamingLease(
                id: id,
                kind: requiresMic ? "voice" : "chat",
                requiresMicrophone: requiresMic,
                startedAtMillis: startedAtMillis
            )
        }
    }

    private func startBackgroundExecution(leases: [BackgroundStreamingLease]) {
        for lease in leases {
            activeLeases[lease.id] = lease
        }

        // Activate audio session for microphone access in background
        if hasMicrophoneLeases {
            VoiceBackgroundAudioManager.shared.activate()
        }

        // Start background tasks if app is already backgrounded
        if UIApplication.shared.applicationState == .background &&
            hasBackgroundExecutionLeases {
            startBackgroundTask()
            if hasChatLeases {
                scheduleBGProcessingTask()
            }
        }
    }

    private func stopBackgroundExecution(streamIds: [String]) {
        streamIds.forEach { activeLeases.removeValue(forKey: $0) }

        if !hasBackgroundExecutionLeases {
            endBackgroundTask()
            cancelBGProcessingTask()
        } else if !hasChatLeases {
            cancelBGProcessingTask()
        }

        if !hasMicrophoneLeases {
            VoiceBackgroundAudioManager.shared.deactivate()
        }
    }
    
    private func startBackgroundTask() {
        guard backgroundTask == .invalid else { return }

        backgroundTask = beginStreamingBackgroundTask()
    }

    private func beginStreamingBackgroundTask() -> UIBackgroundTaskIdentifier {
        var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "ConduitStreaming") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.notifyStreamsSuspending(reason: "background_task_expiring")
                self.flutterApi?.backgroundTaskExpiring { _ in }
                if self.backgroundTask == taskIdentifier {
                    self.endBackgroundTask()
                } else if taskIdentifier != .invalid {
                    UIApplication.shared.endBackgroundTask(taskIdentifier)
                }
            }
        }
        return taskIdentifier
    }
    
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    
    private func keepAlive() {
        if hasBackgroundExecutionLeases &&
            UIApplication.shared.applicationState == .background {
            let oldTask = backgroundTask
            let newTask = beginStreamingBackgroundTask()
            if newTask != .invalid {
                backgroundTask = newTask
                if oldTask != .invalid {
                    UIApplication.shared.endBackgroundTask(oldTask)
                }
            }
        }

        // Keep audio session active for microphone streams
        if hasMicrophoneLeases {
            VoiceBackgroundAudioManager.shared.activate()
        }
    }
    
    private func notifyStreamsSuspending(reason: String) {
        guard !activeLeases.isEmpty else { return }
        flutterApi?.streamsSuspending(
            event: PlatformStreamsSuspendingEvent(
                streamIds: Array(activeLeases.keys),
                reason: reason
            )
        ) { _ in }
    }

    // MARK: - BGTaskScheduler Methods
    //
    // IMPORTANT: BGProcessingTask limitations on iOS:
    // - iOS schedules these during opportunistic windows (device charging, overnight, etc.)
    // - The earliestBeginDate is a HINT, not a guarantee of immediate execution
    // - Typical execution time is ~1-3 minutes when granted, but may NOT run at all
    // - BGProcessingTask is "best-effort bonus time", NOT "guaranteed extended execution"
    //
    // For reliable background execution:
    // - Voice calls: UIBackgroundModes "audio" + AVAudioSession keeps app alive reliably
    // - Chat streaming: beginBackgroundTask gives ~30 seconds (only reliable mechanism)
    // - Socket keepalive: Best-effort; iOS may suspend app regardless
    //
    // The BGProcessingTask here provides opportunistic extended time for long-running
    // streams, but callers should NOT depend on it for critical functionality.

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                self?.handleBGProcessingTask(task: processingTask)
            }
        }
    }

    private func scheduleBGProcessingTask() {
        guard hasChatLeases else { return }
        // Cancel any existing task
        cancelBGProcessingTask()

        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Active chat streams need the task to be eligible during the current
        // response. This is still best-effort and only scheduled for chat leases.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("BackgroundStreamingHandler: Scheduled BGProcessingTask")
        } catch {
            print("BackgroundStreamingHandler: Failed to schedule BGProcessingTask: \(error)")
        }
    }

    private func cancelBGProcessingTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskIdentifier)
        print("BackgroundStreamingHandler: Cancelled BGProcessingTask")
    }

    private func handleBGProcessingTask(task: BGProcessingTask) {
        print("BackgroundStreamingHandler: BGProcessingTask started")
        bgProcessingTask = task
        let completionState = BGProcessingCompletionState()

        // Schedule a new task for continuation if streams are still active
        if hasChatLeases {
            scheduleBGProcessingTask()
        }

        func completeTask(success: Bool) {
            guard !completionState.completed else { return }
            completionState.completed = true
            task.setTaskCompleted(success: success)
            if bgProcessingTask === task {
                bgProcessingTask = nil
            }
        }

        // Set expiration handler
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                print("BackgroundStreamingHandler: BGProcessingTask expiring")
                self.notifyStreamsSuspending(reason: "bg_processing_task_expiring")
                self.flutterApi?.backgroundTaskExpiring { _ in }
                completeTask(success: false)
            }
        }

        // Notify Flutter that we have extended background time
        flutterApi?.backgroundTaskExtended(
            event: PlatformBackgroundTaskExtendedEvent(
                streamIds: Array(activeLeases.keys),
                estimatedTime: 180 // ~3 minutes typical for BGProcessingTask
            )
        ) { _ in }

        Task { @MainActor [weak self] in
            guard let self = self else {
                completeTask(success: false)
                return
            }
            let keepAliveInterval: UInt64 = 30_000_000_000
            let maxTime: TimeInterval = 180
            var elapsedTime: TimeInterval = 0

            while !completionState.completed &&
                self.hasChatLeases &&
                elapsedTime < maxTime {
                try? await Task.sleep(nanoseconds: keepAliveInterval)
                elapsedTime += 30

                if !completionState.completed && self.hasChatLeases {
                    self.flutterApi?.backgroundKeepAlive { _ in }
                }
            }

            completeTask(success: true)
        }
    }


    deinit {
        NotificationCenter.default.removeObserver(self)
        let task = backgroundTask
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
        VoiceBackgroundAudioManager.shared.deactivate()
  }
}

/// Manages the method channel for App Intent invocations to Flutter.
/// Native Swift intents call this to invoke Flutter-side business logic.
final class AppIntentReadiness {
    private let lock = NSLock()
    private var ready = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    func update(_ value: Bool) {
        lock.lock()
        ready = value
        let readyWaiters: [CheckedContinuation<Bool, Never>]
        if value {
            readyWaiters = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
        } else {
            readyWaiters = []
        }
        lock.unlock()
        readyWaiters.forEach { $0.resume(returning: true) }
    }

    func currentValue() -> Bool {
        lock.lock()
        let value = ready
        lock.unlock()
        return value
    }

    func waitUntilReady(timeoutNanoseconds: UInt64) async -> Bool {
        if Task.isCancelled { return false }
        if currentValue() { return true }
        guard timeoutNanoseconds > 0 else { return false }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { [weak self] in
                guard let self else { return false }
                return await self.waitForReadySignal()
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return false
                }
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func waitForReadySignal() async -> Bool {
        if Task.isCancelled { return false }
        let waiterId = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if ready {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                waiters[waiterId] = continuation
                lock.unlock()
            }
        } onCancel: {
            self.resolveWaiter(waiterId, value: false)
        }
    }

    private func resolveWaiter(_ waiterId: UUID, value: Bool) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: waiterId)
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

let appIntentNativeDispatchStateKey = "_nativeDispatchState"
let appIntentNativeDispatchNotDispatched = "notDispatched"
let appIntentNativeDispatchCompleted = "completed"
let appIntentNativeDispatchIndeterminate = "indeterminate"
let appIntentNativeOwnedFilePathKey = "_nativeOwnedFilePath"

struct AppIntentInvocationLease: Equatable {
    let invocationId: String
    fileprivate let fingerprint: String
}

/// Persists the identity of an invocation whose dispatch outcome was
/// indeterminate. App Intents does not expose an execution identifier, so a
/// retry is correlated by a privacy-safe digest of the intent and its
/// canonical inputs. Completed and provably-undispatched calls immediately
/// release their lease; only an interrupted dispatched call remains reusable.
final class AppIntentInvocationStore: @unchecked Sendable {
    private struct Record: Codable, Equatable {
        let invocationId: String
        let fingerprint: String
        var expiresAtMilliseconds: Int64
    }

    private struct LegacyRecord: Codable {
        let invocationId: String
        let expiresAtMilliseconds: Int64
    }

    static let shared = AppIntentInvocationStore()

    private static let defaultsKey =
        "app.cogwheel.conduit.app-intent-invocations-v1"
    private static let leaseLifetimeMilliseconds: Int64 = 5 * 60 * 1_000

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let nowMilliseconds: () -> Int64
    // Activity is intentionally process-local. A record left behind by
    // process termination must become retryable when the next process starts.
    private var activeInvocationIds = Set<String>()

    init(
        defaults: UserDefaults = .standard,
        nowMilliseconds: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.defaults = defaults
        self.nowMilliseconds = nowMilliseconds
    }

    func lease(
        identifier: String,
        canonicalParameters: [String: String]
    ) -> AppIntentInvocationLease {
        let fingerprint = Self.fingerprint(
            identifier: identifier,
            canonicalParameters: canonicalParameters
        )
        lock.lock()
        defer { lock.unlock() }

        let now = nowMilliseconds()
        var records = readRecordsLocked().filter {
            $0.value.expiresAtMilliseconds > now
        }
        activeInvocationIds.formIntersection(records.keys)
        if let reusable = records.values
            .filter({
                !activeInvocationIds.contains($0.invocationId) &&
                    $0.fingerprint == fingerprint &&
                    UUID(uuidString: $0.invocationId) != nil
            })
            .max(by: {
                if $0.expiresAtMilliseconds == $1.expiresAtMilliseconds {
                    return $0.invocationId < $1.invocationId
                }
                return $0.expiresAtMilliseconds < $1.expiresAtMilliseconds
            }) {
            var renewed = reusable
            renewed.expiresAtMilliseconds =
                now + Self.leaseLifetimeMilliseconds
            records[renewed.invocationId] = renewed
            activeInvocationIds.insert(renewed.invocationId)
            persistLocked(records)
            return AppIntentInvocationLease(
                invocationId: renewed.invocationId,
                fingerprint: fingerprint
            )
        }

        let invocationId = UUID().uuidString.lowercased()
        records[invocationId] = Record(
            invocationId: invocationId,
            fingerprint: fingerprint,
            expiresAtMilliseconds: now + Self.leaseLifetimeMilliseconds
        )
        activeInvocationIds.insert(invocationId)
        persistLocked(records)
        return AppIntentInvocationLease(
            invocationId: invocationId,
            fingerprint: fingerprint
        )
    }

    func resolve(
        _ lease: AppIntentInvocationLease,
        dispatchState: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        var records = readRecordsLocked()
        activeInvocationIds.remove(lease.invocationId)
        guard var record = records[lease.invocationId],
              record.fingerprint == lease.fingerprint else { return }
        if dispatchState == appIntentNativeDispatchIndeterminate {
            record.expiresAtMilliseconds =
                nowMilliseconds() + Self.leaseLifetimeMilliseconds
            records[lease.invocationId] = record
        } else {
            records.removeValue(forKey: lease.invocationId)
        }
        persistLocked(records)
    }

    static func fingerprint(
        identifier: String,
        canonicalParameters: [String: String]
    ) -> String {
        var input = Data()
        func append(_ value: String) {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        append(identifier)
        for key in canonicalParameters.keys.sorted() {
            append(key)
            append(canonicalParameters[key] ?? "")
        }
        return SHA256.hash(data: input)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func readRecordsLocked() -> [String: Record] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            return [:]
        }
        if let records = try? JSONDecoder().decode(
            [String: Record].self,
            from: data
        ) {
            return records
        }
        guard let legacyRecords = try? JSONDecoder().decode(
            [String: LegacyRecord].self,
            from: data
        ) else { return [:] }
        return legacyRecords.reduce(into: [:]) { records, entry in
            let (fingerprint, legacy) = entry
            guard UUID(uuidString: legacy.invocationId) != nil else { return }
            records[legacy.invocationId] = Record(
                invocationId: legacy.invocationId,
                fingerprint: fingerprint,
                expiresAtMilliseconds: legacy.expiresAtMilliseconds
            )
        }
    }

    private func persistLocked(_ records: [String: Record]) {
        if records.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
        // App Intent execution may be terminated immediately after perform()
        // returns; flush the tiny lease record before exposing the result.
        defaults.synchronize()
    }
}

/// Exactly-once bridge between callback-based Pigeon calls and async App
/// Intents. Cancellation can race continuation installation, so the gate also
/// retains an early terminal payload until the continuation is ready.
final class AppIntentInvocationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: Any], Never>?
    private var earlyPayload: [String: Any]?
    private var resolved = false
    private var dispatched = false

    var isResolved: Bool {
        lock.lock()
        let value = resolved
        lock.unlock()
        return value
    }

    func install(
        _ continuation: CheckedContinuation<[String: Any], Never>
    ) {
        lock.lock()
        if resolved {
            let payload = earlyPayload ?? Self.failurePayload(
                "App Intent was cancelled.",
                dispatchState: appIntentNativeDispatchNotDispatched
            )
            earlyPayload = nil
            lock.unlock()
            continuation.resume(returning: payload)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Atomically claims the right to send the Pigeon message.
    func beginDispatch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved, !dispatched else { return false }
        dispatched = true
        return true
    }

    @discardableResult
    func resolveCompleted(_ payload: [String: Any]) -> Bool {
        resolve(
            Self.payload(
                payload,
                dispatchState: appIntentNativeDispatchCompleted
            )
        )
    }

    @discardableResult
    func resolveTransportFailure(_ message: String) -> Bool {
        resolve(Self.failurePayload(
            message,
            dispatchState: appIntentNativeDispatchIndeterminate
        ))
    }

    @discardableResult
    func resolveNotDispatched(_ message: String) -> Bool {
        resolve(Self.failurePayload(
            message,
            dispatchState: appIntentNativeDispatchNotDispatched
        ))
    }

    @discardableResult
    func resolveInterrupted(_ message: String) -> Bool {
        lock.lock()
        let dispatchState = dispatched
            ? appIntentNativeDispatchIndeterminate
            : appIntentNativeDispatchNotDispatched
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let payload = Self.failurePayload(
            message,
            dispatchState: dispatchState
        )
        let callback = continuation
        continuation = nil
        if callback == nil {
            earlyPayload = payload
        }
        lock.unlock()
        callback?.resume(returning: payload)
        return true
    }

    private func resolve(_ payload: [String: Any]) -> Bool {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return false
        }
        resolved = true
        let callback = continuation
        continuation = nil
        if callback == nil {
            earlyPayload = payload
        }
        lock.unlock()
        callback?.resume(returning: payload)
        return true
    }

    private static func payload(
        _ payload: [String: Any],
        dispatchState: String
    ) -> [String: Any] {
        var result = payload
        result[appIntentNativeDispatchStateKey] = dispatchState
        return result
    }

    private static func failurePayload(
        _ message: String,
        dispatchState: String
    ) -> [String: Any] {
        payload(
            ["success": false, "error": message],
            dispatchState: dispatchState
        )
    }
}

struct AppIntentStagedImage: Equatable {
    let filePath: String
    let contentDigest: String
}

final class AppIntentBridge: AppIntentHostApi, @unchecked Sendable {
    private static let sharedLock = NSLock()
    private static var storedShared: AppIntentBridge?
    private static let sharedReadiness = AppIntentReadiness()

    static var shared: AppIntentBridge? {
        get {
            sharedLock.lock()
            let bridge = storedShared
            sharedLock.unlock()
            return bridge
        }
        set {
            sharedLock.lock()
            storedShared = newValue
            let ready = newValue?.readiness.currentValue() ?? false
            sharedReadiness.update(ready)
            sharedLock.unlock()
        }
    }

    private static let imageByteLimit = 20 * 1024 * 1024
    private static let imageStagingDirectoryName = "conduit-app-intents"
    private static let invocationTimeout: TimeInterval = 10

    private let api: AppIntentFlutterApi
    private let readiness = AppIntentReadiness()

    init(messenger: FlutterBinaryMessenger) {
        api = AppIntentFlutterApi(binaryMessenger: messenger)
        AppIntentHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    }

    func setReady(ready: Bool) throws {
        // Pigeon acknowledges this synchronous host call as soon as the
        // method returns. Apply readiness before returning so Dart never sees
        // a successful setReady(true) while native intents still see false.
        Self.sharedLock.lock()
        readiness.update(ready)
        if Self.storedShared === self {
            Self.sharedReadiness.update(ready)
        }
        Self.sharedLock.unlock()
    }

    /// Waits for both the Flutter engine and the Dart handler to be ready.
    /// App Intents can be asked to run while a cold launch is still between
    /// native plugin registration and the deferred Dart coordinator startup.
    static func readyBridge() async -> AppIntentBridge? {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while true {
            guard !Task.isCancelled else { return nil }
            if let bridge = readySharedBridge() {
                return bridge
            }
            let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
            guard remainingSeconds > 0 else { return nil }
            let remainingNanoseconds = UInt64(
                min(remainingSeconds * 1_000_000_000, Double(UInt64.max))
            )
            guard await sharedReadiness.waitUntilReady(
                timeoutNanoseconds: remainingNanoseconds
            ) else { return nil }
        }
    }

    private static func readySharedBridge() -> AppIntentBridge? {
        sharedLock.lock()
        let bridge = storedShared
        let ready = bridge?.readiness.currentValue() ?? false
        sharedLock.unlock()
        return ready ? bridge : nil
    }

    static func stageImage(data: Data, filename: String) async throws -> String {
        try await stageImageArtifact(data: data, filename: filename).filePath
    }

    static func stageImageArtifact(
        data: Data,
        filename: String
    ) async throws -> AppIntentStagedImage {
        guard !data.isEmpty, data.count <= imageByteLimit else {
            throw AppIntentError.executionFailed(
                appLocalized("appIntent.imageTooLarge", "Image is too large (20 MB maximum).")
            )
        }
        let stagingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let directory = try imageStagingDirectory()
            let fileExtension = safeImageFileExtension(filename)
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString)-intent.\(fileExtension)"
            )
            var completed = false
            defer {
                if !completed {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try data.write(to: destination, options: [.atomic])
            try Task.checkCancellation()
            completed = true
            return AppIntentStagedImage(
                filePath: destination.path,
                contentDigest: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        }
        return try await withTaskCancellationHandler {
            try await stagingTask.value
        } onCancel: {
            stagingTask.cancel()
        }
    }

    static func stageImage(fileURL: URL, filename: String) async throws -> String {
        try await stageImageArtifact(
            fileURL: fileURL,
            filename: filename
        ).filePath
    }

    static func stageImageArtifact(
        fileURL: URL,
        filename: String
    ) async throws -> AppIntentStagedImage {
        let stagingTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let didAccessSecurityScope = fileURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSecurityScope {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            let values = try fileURL.resourceValues(
                forKeys: [
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            if let fileSize = values.fileSize,
               fileSize <= 0 || fileSize > imageByteLimit {
                throw AppIntentError.executionFailed(
                    appLocalized(
                        "appIntent.imageTooLarge",
                        "Image is too large (20 MB maximum)."
                    )
                )
            }

            let directory = try imageStagingDirectory()
            let destination = directory.appendingPathComponent(
                "\(UUID().uuidString)-intent.\(safeImageFileExtension(filename))"
            )
            guard FileManager.default.createFile(
                atPath: destination.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }

            var completed = false
            defer {
                if !completed {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            let input = try FileHandle(forReadingFrom: fileURL)
            let output = try FileHandle(forWritingTo: destination)
            defer {
                try? input.close()
                try? output.close()
            }

            var totalBytes = 0
            var digest = SHA256()
            while let chunk = try input.read(upToCount: 64 * 1024),
                  !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= imageByteLimit - totalBytes else {
                    throw AppIntentError.executionFailed(
                        appLocalized(
                            "appIntent.imageTooLarge",
                            "Image is too large (20 MB maximum)."
                        )
                    )
                }
                try output.write(contentsOf: chunk)
                digest.update(data: chunk)
                totalBytes += chunk.count
            }
            try Task.checkCancellation()
            guard totalBytes > 0 else {
                throw AppIntentError.executionFailed(
                    appLocalized(
                        "appIntent.imageTooLarge",
                        "Image is too large (20 MB maximum)."
                    )
                )
            }
            completed = true
            return AppIntentStagedImage(
                filePath: destination.path,
                contentDigest: digest.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()
            )
        }
        return try await withTaskCancellationHandler {
            try await stagingTask.value
        } onCancel: {
            stagingTask.cancel()
        }
    }

    static func removeStagedImageIfOwned(atPath filePath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(imageStagingDirectoryName, isDirectory: true)
            .standardizedFileURL
        let candidate = URL(fileURLWithPath: filePath).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path,
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private static func imageStagingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(imageStagingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return directory.standardizedFileURL
    }

    private static func safeImageFileExtension(_ filename: String) -> String {
        let rawExtension = (filename as NSString).pathExtension.lowercased()
        let allowed = rawExtension.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed)).prefix(10)
        return sanitized.isEmpty ? "img" : String(sanitized)
    }

    /// Invokes a Flutter handler for the given intent identifier.
    func invokeIntent(
        identifier: String,
        parameters: [String: Any],
        canonicalParameters: [String: String]
    ) async -> [String: Any] {
        let invocationLease = AppIntentInvocationStore.shared.lease(
            identifier: identifier,
            canonicalParameters: canonicalParameters
        )
        let result: [String: Any]
        switch identifier {
        case "app.cogwheel.conduit.ask_chat":
            result = await invoke { bridge, completion in
                bridge.api.askChat(
                    invocationId: invocationLease.invocationId,
                    prompt: parameters["prompt"] as? String,
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.start_voice_call":
            result = await invoke { bridge, completion in
                bridge.api.startVoiceCall(
                    invocationId: invocationLease.invocationId,
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_text":
            result = await invoke { bridge, completion in
                bridge.api.sendText(
                    invocationId: invocationLease.invocationId,
                    text: parameters["text"] as? String ?? "",
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_url":
            result = await invoke { bridge, completion in
                bridge.api.sendUrl(
                    invocationId: invocationLease.invocationId,
                    url: parameters["url"] as? String ?? "",
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_image":
            guard let filePath = parameters["filePath"] as? String,
                  !filePath.isEmpty else {
                result = [
                    "success": false,
                    "error": "No staged image provided."
                ]
                break
            }
            let payload = PlatformAppIntentImagePayload(
                filename: parameters["filename"] as? String ?? "shared_image.jpg",
                filePath: filePath
            )
            result = await invoke { bridge, completion in
                bridge.api.sendImage(
                    invocationId: invocationLease.invocationId,
                    payload: payload,
                    completion: completion
                )
            }
        default:
            result = [
                "success": false,
                "error": "Unknown intent: \(identifier)"
            ]
        }
        AppIntentInvocationStore.shared.resolve(
            invocationLease,
            dispatchState: result[appIntentNativeDispatchStateKey] as? String
        )
        return result
    }

    private func invoke(
        _ call: @escaping (
            AppIntentBridge,
            @escaping (Result<PlatformAppIntentResponse, PigeonError>) -> Void
        ) -> Void
    ) async -> [String: Any] {
        let completion = AppIntentInvocationCompletion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                guard !completion.isResolved else { return }

                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + Self.invocationTimeout
                ) {
                    completion.resolveInterrupted(
                        "App Intent timed out waiting for Conduit."
                    )
                }

                DispatchQueue.main.async {
                    // Reacquire at the dispatch boundary. The bridge returned
                    // by readyBridge() can be replaced (or deallocated)
                    // before this block reaches the main queue; the current
                    // ready bridge receives the same durable invocation.
                    guard let targetBridge = Self.readySharedBridge() else {
                        completion.resolveNotDispatched(
                            "App Intent bridge was replaced."
                        )
                        return
                    }
                    guard completion.beginDispatch() else { return }
                    call(targetBridge) { result in
                        switch result {
                        case .success(let response):
                            var payload: [String: Any] = [
                                "success": response.success,
                            ]
                            payload["value"] = response.value
                            payload["error"] = response.error
                            payload[appIntentNativeOwnedFilePathKey] =
                                response.ownedFilePath
                            completion.resolveCompleted(payload)
                        case .failure(let error):
                            // The message crossed the engine boundary, but a
                            // transport failure cannot prove whether Dart took
                            // ownership before its response was lost.
                            completion.resolveTransportFailure(
                                error.message ?? error.localizedDescription
                            )
                        }
                    }
                }
            }
        } onCancel: {
            completion.resolveInterrupted("App Intent was cancelled.")
        }
    }
}

@available(iOS 16.0, *)
enum AppIntentError: Error {
    case executionFailed(String)
}

@available(iOS 16.0, *)
struct AskConduitIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Conduit"
    static var description = IntentDescription(
        "Start a Conduit chat with an optional prompt."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Prompt",
        requestValueDialog: IntentDialog("What should Conduit answer?")
    )
    var prompt: String?

    init() {}

    init(prompt: String?) {
        self.prompt = prompt
    }

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let parameters: [String: Any] = prompt?.isEmpty == false
            ? ["prompt": prompt ?? ""]
            : [:]
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.ask_chat",
            parameters: parameters,
            canonicalParameters: ["prompt": prompt ?? ""]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.openingChat", "Opening chat")
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? appLocalized("appIntent.unableOpenChat", "Unable to open Conduit chat")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct StartVoiceCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Call"
    static var description = IntentDescription(
        "Start a live voice call with Conduit."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.start_voice_call",
            parameters: [:],
            canonicalParameters: [:]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.startingVoiceCall", "Starting voice call")
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? appLocalized("appIntent.unableStartVoiceCall", "Unable to start voice call")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct ConduitSendTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Conduit"
    static var description = IntentDescription(
        "Start a Conduit chat with provided text."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What should Conduit process?")
    )
    var text: String?

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_text",
            parameters: ["text": trimmed ?? ""],
            canonicalParameters: ["text": trimmed ?? ""]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.sentToConduit", "Sent to Conduit")
            return .result(value: value)
        }

        let message = result["error"] as? String ?? appLocalized("appIntent.unableSendText", "Unable to send text")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct ConduitSendUrlIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Link to Conduit"
    static var description = IntentDescription(
        "Send a URL into Conduit for summary or analysis."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "URL",
        requestValueDialog: IntentDialog("Which link should Conduit analyze?")
    )
    var url: URL

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_url",
            parameters: ["url": url.absoluteString],
            canonicalParameters: ["url": url.absoluteString]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.sentLinkToConduit", "Sent link to Conduit")
            return .result(value: value)
        }

        let message = result["error"] as? String ?? appLocalized("appIntent.unableSendLink", "Unable to send link")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct ConduitSendImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Image to Conduit"
    static var description = IntentDescription(
        "Send an image into Conduit for analysis."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Image",
        requestValueDialog: IntentDialog("Choose an image for Conduit.")
    )
    var image: IntentFile

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = await AppIntentBridge.readyBridge() else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        if let type = image.type, !type.conforms(to: .image) {
            throw AppIntentError.executionFailed(
                appLocalized("appIntent.onlyImagesSupported", "Only image files are supported.")
            )
        }

        let name = image.filename
        let stagedImage: AppIntentStagedImage
        if let fileURL = image.fileURL {
            stagedImage = try await AppIntentBridge.stageImageArtifact(
                fileURL: fileURL,
                filename: name
            )
        } else {
            // Some providers expose only in-memory data. Keep this fallback,
            // but prefer file-backed streaming so the 20 MB limit is enforced
            // before materializing the full image in the app process.
            stagedImage = try await AppIntentBridge.stageImageArtifact(
                data: image.data,
                filename: name
            )
        }
        let filePath = stagedImage.filePath
        var dartMayOwnStagedImage = false
        defer {
            if !dartMayOwnStagedImage {
                AppIntentBridge.removeStagedImageIfOwned(atPath: filePath)
            }
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_image",
            parameters: [
                "filename": name,
                "filePath": filePath,
            ],
            canonicalParameters: [
                "filename": name,
                "contentDigest": stagedImage.contentDigest,
            ]
        )

        if let success = result["success"] as? Bool, success {
            // A retry stages a fresh copy but reuses the invocation ID. Dart
            // may return the cached result for the original path; transfer
            // only the exact path Dart reports owning so the duplicate copy
            // is reclaimed by this defer.
            dartMayOwnStagedImage =
                result[appIntentNativeOwnedFilePathKey] as? String == filePath
            let value = result["value"] as? String ?? appLocalized("appIntent.sentImageToConduit", "Sent image to Conduit")
            return .result(value: value)
        }

        // A timeout, cancellation, or transport failure after dispatch is an
        // indeterminate ownership boundary. Dart may already have persisted a
        // queue row for this exact path, so native cleanup must fail safe.
        if result[appIntentNativeDispatchStateKey] as? String ==
            appIntentNativeDispatchIndeterminate {
            dartMayOwnStagedImage = true
        }

        let message = result["error"] as? String ?? appLocalized("appIntent.unableSendImage", "Unable to send image")
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: AskConduitIntent(),
                phrases: [
                    "Ask with \(.applicationName)",
                    "Start chat in \(.applicationName)",
                    "Open composer in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: StartVoiceCallIntent(),
                phrases: [
                    "Start voice call in \(.applicationName)",
                    "Call with \(.applicationName)",
                    "Begin voice chat in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: ConduitSendTextIntent(),
                phrases: [
                    "Send text to \(.applicationName)",
                    "Share text with \(.applicationName)",
                    "Summarize this in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: ConduitSendUrlIntent(),
                phrases: [
                    "Summarize link in \(.applicationName)",
                    "Analyze link with \(.applicationName)",
                    "Send URL to \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: ConduitSendImageIntent(),
                phrases: [
                    "Send image to \(.applicationName)",
                    "Analyze image with \(.applicationName)",
                    "Share photo to \(.applicationName)",
                ]
            ),
        ]
    }
}

/// Matches an HTTP cookie using its host-only/domain scope, Secure attribute,
/// and RFC 6265 path boundary rules.
func cookieMatchesUrl(cookie: HTTPCookie, url: URL) -> Bool {
    guard let host = url.host?.lowercased(), !host.isEmpty else {
        return false
    }

    if cookie.isSecure && url.scheme?.lowercased() != "https" {
        return false
    }

    let rawDomain = cookie.domain.lowercased()
    let isDomainCookie = rawDomain.hasPrefix(".")
    let cookieHost = isDomainCookie
        ? String(rawDomain.dropFirst())
        : rawDomain
    guard !cookieHost.isEmpty else { return false }

    if isDomainCookie {
        guard host == cookieHost || host.hasSuffix(".\(cookieHost)") else {
            return false
        }
    } else if host != cookieHost {
        return false
    }

    // RFC 6265 compares the request-target path as encoded octets. `URL.path`
    // decodes `%2F` into `/`, which would incorrectly broaden `/admin` to
    // match a request for `/admin%2Fpublic`.
    let encodedPath = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )?.percentEncodedPath ?? ""
    let requestPath = encodedPath.isEmpty ? "/" : encodedPath
    let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
    guard requestPath.hasPrefix(cookiePath) else { return false }
    if requestPath == cookiePath || cookiePath.hasSuffix("/") {
        return true
    }

    let boundary = requestPath.index(
        requestPath.startIndex,
        offsetBy: cookiePath.count
    )
    return requestPath[boundary] == "/"
}

/// Collapses matching cookies to the name/value map expected by Dart.
///
/// WKHTTPCookieStore does not promise a useful order. Prefer the cookie with
/// the longest matching path for duplicate names, then apply stable scope and
/// lexical tie-breakers so store enumeration order cannot change the result.
func cookieValuesForUrl(cookies: [HTTPCookie], url: URL) -> [String: String] {
    var selected: [String: HTTPCookie] = [:]
    for cookie in cookies where cookieMatchesUrl(cookie: cookie, url: url) {
        guard let current = selected[cookie.name] else {
            selected[cookie.name] = cookie
            continue
        }
        if cookieIsPreferred(candidate: cookie, over: current) {
            selected[cookie.name] = cookie
        }
    }
    return selected.mapValues(\.value)
}

private func cookieIsPreferred(
    candidate: HTTPCookie,
    over current: HTTPCookie
) -> Bool {
    let candidatePath = candidate.path.isEmpty ? "/" : candidate.path
    let currentPath = current.path.isEmpty ? "/" : current.path
    if candidatePath.utf8.count != currentPath.utf8.count {
        return candidatePath.utf8.count > currentPath.utf8.count
    }

    let candidateHostOnly = !candidate.domain.hasPrefix(".")
    let currentHostOnly = !current.domain.hasPrefix(".")
    if candidateHostOnly != currentHostOnly {
        return candidateHostOnly
    }

    if candidate.isSecure != current.isSecure {
        return candidate.isSecure
    }

    let candidateDomain = candidate.domain.lowercased()
    let currentDomain = current.domain.lowercased()
    if candidateDomain.utf8.count != currentDomain.utf8.count {
        return candidateDomain.utf8.count > currentDomain.utf8.count
    }
    if candidatePath != currentPath {
        return candidatePath < currentPath
    }
    if candidateDomain != currentDomain {
        return candidateDomain < currentDomain
    }
    return candidate.value < current.value
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundStreamingHandler: BackgroundStreamingHandler?
  private var sharedFlutterEngine: FlutterEngine?
  private weak var sharedFlutterWindowScene: UIWindowScene?
  private var didConfigureSharedFlutterEngine = false
  private var cookieChannel: FlutterMethodChannel?
  private var shareImportChannel: FlutterMethodChannel?

  private func shareAppGroupId() -> String? {
    let appGroupId = Bundle.main.object(
      forInfoDictionaryKey: conduitShareAppGroupIdKey
    ) as? String
    let defaultGroupId = Bundle.main.bundleIdentifier.map { "group.\($0)" }
    return appGroupId ?? defaultGroupId
  }

  private func shareUserDefaults() -> UserDefaults? {
    guard let groupId = shareAppGroupId() else { return nil }
    return UserDefaults(suiteName: groupId)
  }

  private lazy var shareEnvelopeStore: NativeShareEnvelopeStore? = {
    guard let groupId = shareAppGroupId(),
          let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId
          ) else { return nil }
    return NativeShareEnvelopeStore(
      containerURL: container,
      legacyDefaults: shareUserDefaults()
    )
  }()

  private func shareStagingDirectoryPath() -> String? {
    guard let groupId = shareAppGroupId(),
          let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId
          ) else { return nil }
    let directory = container.appendingPathComponent(
      nativeShareStagingDirectoryName,
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let values = try directory.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        return nil
      }
      return directory.resolvingSymlinksInPath().standardizedFileURL.path
    } catch {
      return nil
    }
  }

  private func pendingShareImportStatus() -> [String: Any]? {
    guard let store = shareEnvelopeStore,
          let data = try? store.currentStatusJSON() else {
      return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func clearShareImportStatus(id: String?) {
    guard let store = shareEnvelopeStore else { return }
    _ = try? store.clearStatus(id: id)
  }

  private func takePendingShareImportPayload() -> [String: Any]? {
    guard let store = shareEnvelopeStore,
          let snapshot = try? store.takeCurrent(),
          let rawItems = (try? JSONSerialization.jsonObject(
            with: snapshot.envelope.itemsJSON
          ))
      as? [[String: Any]],
      let status = (try? JSONSerialization.jsonObject(
        with: snapshot.statusJSON
      )) as? [String: Any],
      let payload = nativeValidatedShareImportPayload(
        rawItems: rawItems,
        message: snapshot.envelope.message,
        status: status,
        shareStagingDirectoryPath: shareStagingDirectoryPath()
      ) else {
      return nil
    }
    return payload
  }

  private func acknowledgePendingShareImportPayload(id: String?) -> Bool {
    guard let id, let store = shareEnvelopeStore else { return false }
    return (try? store.acknowledge(id: id)) == true
  }

  func notifyShareImportEvent() {
    shareImportChannel?.invokeMethod("stagedSharePayloadReady", arguments: nil)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    backgroundStreamingHandler = BackgroundStreamingHandler()
    backgroundStreamingHandler?.registerBackgroundTasks()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    guard sharedFlutterEngine == nil else { return }

    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    configureApplicationFlutterChannels(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
  }

  @discardableResult
  func ensureCarPlayFlutterEngine() -> Bool {
    return ensureSharedFlutterEngine() != nil
  }

  @discardableResult
  func ensureSharedFlutterEngine() -> FlutterEngine? {
    if let engine = sharedFlutterEngine {
      configureSharedFlutterEngineIfNeeded(engine)
      return engine
    }

    let engine = FlutterEngine(
      name: "conduit.shared",
      project: nil,
      allowHeadlessExecution: true
    )
    guard engine.run() else {
      print("AppDelegate: failed to start shared Flutter engine")
      return nil
    }

    sharedFlutterEngine = engine
    configureSharedFlutterEngineIfNeeded(engine)
    return engine
  }

  func claimSharedFlutterWindowScene(_ windowScene: UIWindowScene) -> Bool {
    if let currentScene = sharedFlutterWindowScene, currentScene !== windowScene {
      return false
    }

    sharedFlutterWindowScene = windowScene
    return true
  }

  func releaseSharedFlutterWindowScene(_ windowScene: UIWindowScene) {
    if sharedFlutterWindowScene === windowScene {
      sharedFlutterWindowScene = nil
    }
  }

  private func configureSharedFlutterEngineIfNeeded(_ engine: FlutterEngine) {
    guard !didConfigureSharedFlutterEngine else { return }

    GeneratedPluginRegistrant.register(with: engine)
    configureApplicationFlutterChannels(messenger: engine.binaryMessenger)
    didConfigureSharedFlutterEngine = true
  }

  private func configureApplicationFlutterChannels(
    messenger: FlutterBinaryMessenger
  ) {
    AppIntentBridge.shared = AppIntentBridge(messenger: messenger)
    ConduitCarPlayBridge.shared.configure(messenger: messenger)
    NativePasteBridge.shared.configure(messenger: messenger)
    NativeKeyboardAttachmentBridge.shared.configure(messenger: messenger)
    NativeSheetBridge.shared.configure(messenger: messenger)
    NativeDropdownBridge.shared.configure(messenger: messenger)
    NativeSttBridge.shared.configure(messenger: messenger)
    VoiceAudioRouteBridge.shared.configure(messenger: messenger)
    NativeIosTtsBridge.shared.configure(messenger: messenger)
    backgroundStreamingHandler?.setup(messenger: messenger)

    let shareImportChannel = FlutterMethodChannel(
      name: conduitShareChannelName,
      binaryMessenger: messenger
    )
    self.shareImportChannel = shareImportChannel
    shareImportChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }

      switch call.method {
      case "pendingShareImportStatus":
        result(self.pendingShareImportStatus())
      case "takePendingShareImportPayload":
        result(self.takePendingShareImportPayload())
      case "ackPendingShareImportPayload":
        let arguments = call.arguments as? [String: Any]
        result(self.acknowledgePendingShareImportPayload(
          id: arguments?["id"] as? String
        ))
      case "shareStagingDirectoryPath":
        result(self.shareStagingDirectoryPath())
      case "clearShareImportStatus":
        let arguments = call.arguments as? [String: Any]
        self.clearShareImportStatus(id: arguments?["id"] as? String)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let cookieChannel = FlutterMethodChannel(
      name: "com.conduit.app/cookies",
      binaryMessenger: messenger
    )
    self.cookieChannel = cookieChannel

    cookieChannel.setMethodCallHandler { (call, result) in
      if call.method == "getCookies" {
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid URL", details: nil))
          return
        }

        // Get cookies from WKWebView's cookie store
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          result(cookieValuesForUrl(cookies: cookies, url: url))
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
