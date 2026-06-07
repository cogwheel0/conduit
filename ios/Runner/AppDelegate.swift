import AVFoundation
import BackgroundTasks
import Flutter
import AppIntents
import UIKit
import WebKit

private func appLocalized(_ key: String, _ fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}

/// Manages AVAudioSession for voice calls in the background.
///
/// IMPORTANT: This manager is ONLY used for server-side STT (speech-to-text).
/// When using local STT via speech_to_text plugin, that plugin manages its own
/// audio session. Do NOT activate this manager when local STT is in use to
/// avoid audio session conflicts.
///
/// The voice_call_service.dart checks `useServerMic` before calling
/// startBackgroundExecution with requiresMicrophone:true.
final class VoiceBackgroundAudioManager {
    static let shared = VoiceBackgroundAudioManager()

    private var isActive = false
    private let lock = NSLock()
    
    /// Flag indicating another component (e.g., speech_to_text plugin) owns the audio session.
    /// When true, this manager will skip activation to avoid conflicts.
    private var externalSessionOwner = false

    private init() {}
    
    /// Mark that an external component (e.g., speech_to_text) is managing the audio session.
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
            // This helps prevent conflicts if speech_to_text already configured the session
            let currentCategory = session.category
            let needsReconfiguration = currentCategory != .playAndRecord
            
            if needsReconfiguration {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [
                        // Keep the session on duplex-capable routes while the
                        // server-side recorder is streaming PCM from the mic.
                        .allowBluetooth,
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
final class AppIntentBridge {
    static var shared: AppIntentBridge?

    private let api: AppIntentFlutterApi

    init(messenger: FlutterBinaryMessenger) {
        api = AppIntentFlutterApi(binaryMessenger: messenger)
    }

    /// Invokes a Flutter handler for the given intent identifier.
    func invokeIntent(
        identifier: String,
        parameters: [String: Any]
    ) async -> [String: Any] {
        switch identifier {
        case "app.cogwheel.conduit.ask_chat":
            return await invoke { completion in
                self.api.askChat(
                    prompt: parameters["prompt"] as? String,
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.start_voice_call":
            return await invoke { completion in
                self.api.startVoiceCall(completion: completion)
            }
        case "app.cogwheel.conduit.send_text":
            return await invoke { completion in
                self.api.sendText(
                    text: parameters["text"] as? String ?? "",
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_url":
            return await invoke { completion in
                self.api.sendUrl(
                    url: parameters["url"] as? String ?? "",
                    completion: completion
                )
            }
        case "app.cogwheel.conduit.send_image":
            guard let data = parameters["bytes"] as? Data else {
                return [
                    "success": false,
                    "error": "No image data provided."
                ]
            }
            let payload = PlatformAppIntentImagePayload(
                filename: parameters["filename"] as? String ?? "shared_image.jpg",
                bytes: FlutterStandardTypedData(bytes: data)
            )
            return await invoke { completion in
                self.api.sendImage(payload: payload, completion: completion)
            }
        default:
            return [
                "success": false,
                "error": "Unknown intent: \(identifier)"
            ]
        }
    }

    private func invoke(
        _ call: @escaping (@escaping (Result<PlatformAppIntentResponse, PigeonError>) -> Void) -> Void
    ) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                call { result in
                    switch result {
                    case .success(let response):
                        var payload: [String: Any] = [
                            "success": response.success,
                        ]
                        payload["value"] = response.value
                        payload["error"] = response.error
                        continuation.resume(returning: payload)
                    case .failure(let error):
                        continuation.resume(returning: [
                            "success": false,
                            "error": error.message ?? error.localizedDescription,
                        ])
                    }
                }
            }
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
        guard let channel = AppIntentBridge.shared else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let parameters: [String: Any] = prompt?.isEmpty == false
            ? ["prompt": prompt ?? ""]
            : [:]
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.ask_chat",
            parameters: parameters
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
        guard let channel = AppIntentBridge.shared else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.start_voice_call",
            parameters: [:]
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
        guard let channel = AppIntentBridge.shared else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_text",
            parameters: ["text": trimmed ?? ""]
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
        guard let channel = AppIntentBridge.shared else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_url",
            parameters: ["url": url.absoluteString]
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
        guard let channel = AppIntentBridge.shared else {
            throw AppIntentError.executionFailed(appLocalized("appIntent.appNotReady", "App not ready"))
        }

        if let type = image.type, !type.conforms(to: .image) {
            throw AppIntentError.executionFailed(
                appLocalized("appIntent.onlyImagesSupported", "Only image files are supported.")
            )
        }

        let data = try image.data
        let name = image.filename ?? "shared_image.jpg"

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_image",
            parameters: [
                "filename": name,
                "bytes": data,
            ]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? appLocalized("appIntent.sentImageToConduit", "Sent image to Conduit")
            return .result(value: value)
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

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var backgroundStreamingHandler: BackgroundStreamingHandler?
  private var sharedFlutterEngine: FlutterEngine?
  private weak var sharedFlutterWindowScene: UIWindowScene?
  private var didConfigureSharedFlutterEngine = false
  private var cookieChannel: FlutterMethodChannel?

  /// Checks if a cookie matches a given URL based on domain.
  private func cookieMatchesUrl(cookie: HTTPCookie, url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let domain = cookie.domain.lowercased()

    // Remove leading dot from cookie domain if present
    let cleanDomain = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain

    // Exact match or subdomain match
    return host == cleanDomain || host.hasSuffix(".\(cleanDomain)")
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
    backgroundStreamingHandler?.setup(messenger: messenger)

    let cookieChannel = FlutterMethodChannel(
      name: "com.conduit.app/cookies",
      binaryMessenger: messenger
    )
    self.cookieChannel = cookieChannel

    cookieChannel.setMethodCallHandler { [weak self] (call, result) in
      if call.method == "getCookies" {
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString) else {
          result(FlutterError(code: "INVALID_ARGS", message: "Invalid URL", details: nil))
          return
        }

        // Get cookies from WKWebView's cookie store
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
          guard let self = self else {
            // Always call result to avoid leaving Dart side hanging
            result([:])
            return
          }
          var cookieDict: [String: String] = [:]

          for cookie in cookies {
            // Filter cookies for this domain
            if self.cookieMatchesUrl(cookie: cookie, url: url) {
              cookieDict[cookie.name] = cookie.value
            }
          }

          result(cookieDict)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
