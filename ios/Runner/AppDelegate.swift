import AVFoundation
import BackgroundTasks
import Flutter
import AppIntents
import UIKit
import WebKit
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
                        .allowBluetooth,
                        .allowBluetoothA2DP,
                        .mixWithOthers,
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

// Background streaming handler class
class BackgroundStreamingHandler: NSObject {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var bgProcessingTask: BGTask?
    private var activeStreams: Set<String> = []
    private var microphoneStreams: Set<String> = []
    private var channel: FlutterMethodChannel?

    static let processingTaskIdentifier = "app.cogwheel.qonduit.refresh"

    override init() {
        super.init()
        setupNotifications()
    }
    
    func setup(with channel: FlutterMethodChannel) {
        self.channel = channel
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
        if !activeStreams.isEmpty {
            startBackgroundTask()
            scheduleBGProcessingTask()
        }
    }
    
    @objc private func appWillEnterForeground() {
        endBackgroundTask()
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startBackgroundExecution":
            if let args = call.arguments as? [String: Any],
               let streamIds = args["streamIds"] as? [String] {
                let requiresMic = args["requiresMicrophone"] as? Bool ?? false
                startBackgroundExecution(streamIds: streamIds, requiresMic: requiresMic)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            }
            
        case "stopBackgroundExecution":
            if let args = call.arguments as? [String: Any],
               let streamIds = args["streamIds"] as? [String] {
                stopBackgroundExecution(streamIds: streamIds)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            }
            
        case "keepAlive":
            keepAlive()
            result(nil)
            
        case "checkBackgroundRefreshStatus":
            // Check if background app refresh is enabled by the user
            let status = UIApplication.shared.backgroundRefreshStatus
            switch status {
            case .available:
                result(true)
            case .denied, .restricted:
                result(false)
            @unknown default:
                result(true) // Assume available for future cases
            }
        
        case "setExternalAudioSessionOwner":
            // Coordinate with speech_to_text plugin to prevent audio session conflicts
            if let args = call.arguments as? [String: Any],
               let isExternal = args["isExternal"] as? Bool {
                VoiceBackgroundAudioManager.shared.setExternalSessionOwner(isExternal)
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing isExternal argument", details: nil))
            }
            
        case "getActiveStreamCount":
            // Return count for Flutter-native state reconciliation
            result(activeStreams.count)
            
        case "stopAllBackgroundExecution":
            // Stop all streams (used for reconciliation when orphaned service detected)
            let allStreams = Array(activeStreams)
            stopBackgroundExecution(streamIds: allStreams)
            result(nil)
            
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func startBackgroundExecution(streamIds: [String], requiresMic: Bool) {
        // Add new stream IDs to active set
        activeStreams.formUnion(streamIds)
        
        // Clean up any mic streams that are no longer active (e.g., completed streams)
        // This ensures microphoneStreams stays in sync with activeStreams
        microphoneStreams.formIntersection(activeStreams)
        
        // If these new streams require microphone, add them to the mic set
        if requiresMic {
            microphoneStreams.formUnion(streamIds)
        }

        // Activate audio session for microphone access in background
        if !microphoneStreams.isEmpty {
            VoiceBackgroundAudioManager.shared.activate()
        }

        // Start background tasks if app is already backgrounded
        if UIApplication.shared.applicationState == .background {
            startBackgroundTask()
            scheduleBGProcessingTask()
        }
    }

    private func stopBackgroundExecution(streamIds: [String]) {
        streamIds.forEach { activeStreams.remove($0) }
        streamIds.forEach { microphoneStreams.remove($0) }

        if activeStreams.isEmpty {
            endBackgroundTask()
            cancelBGProcessingTask()
        }

        if microphoneStreams.isEmpty {
            VoiceBackgroundAudioManager.shared.deactivate()
        }
    }
    
    private func startBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "QonduitStreaming") { [weak self] in
            guard let self = self else { return }
            // Notify Flutter about streams being suspended before task expires
            self.notifyStreamsSuspending(reason: "background_task_expiring")
            self.channel?.invokeMethod("backgroundTaskExpiring", arguments: nil)
            self.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    
    private func keepAlive() {
        // Use atomic task refresh: start new task before ending old one
        // This prevents the brief window where iOS could suspend the app
        if backgroundTask != .invalid {
            let oldTask = backgroundTask
            
            // Begin a new task BEFORE marking old one invalid
            // This ensures continuous background execution coverage
            let newTask = UIApplication.shared.beginBackgroundTask(withName: "QonduitStreaming") { [weak self] in
                guard let self = self else { return }
                self.notifyStreamsSuspending(reason: "keepalive_task_expiring")
                self.channel?.invokeMethod("backgroundTaskExpiring", arguments: nil)
                // End this specific task, not whatever is in backgroundTask
                if self.backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundTask)
                    self.backgroundTask = .invalid
                }
            }
            
            // Only update state if we successfully got a new task
            if newTask != .invalid {
                backgroundTask = newTask
                // Now safe to end old task
                UIApplication.shared.endBackgroundTask(oldTask)
            }
            // If newTask is .invalid, keep the old task running (it's better than nothing)
        } else if !activeStreams.isEmpty {
            // No current task but we have active streams - start one
            startBackgroundTask()
        }

        // Keep audio session active for microphone streams
        if !microphoneStreams.isEmpty {
            VoiceBackgroundAudioManager.shared.activate()
        }
    }
    
    private func notifyStreamsSuspending(reason: String) {
        guard !activeStreams.isEmpty else { return }
        channel?.invokeMethod("streamsSuspending", arguments: [
            "streamIds": Array(activeStreams),
            "reason": reason
        ])
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
            self?.handleBGProcessingTask(task: task as! BGProcessingTask)
        }
    }

    private func scheduleBGProcessingTask() {
        // Cancel any existing task
        cancelBGProcessingTask()

        let request = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Request execution as soon as possible (best-effort only)
        // WARNING: iOS heavily throttles BGProcessingTask - it may run hours later or not at all.
        // This is supplementary to beginBackgroundTask, which is the primary mechanism.
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

        // Schedule a new task for continuation if streams are still active
        if !activeStreams.isEmpty {
            scheduleBGProcessingTask()
        }

        // Set expiration handler
        task.expirationHandler = { [weak self] in
            guard let self = self else { return }
            print("BackgroundStreamingHandler: BGProcessingTask expiring")
            // Notify Flutter about streams being suspended
            self.notifyStreamsSuspending(reason: "bg_processing_task_expiring")
            self.channel?.invokeMethod("backgroundTaskExpiring", arguments: nil)
            self.bgProcessingTask = nil
        }

        // Notify Flutter that we have extended background time
        channel?.invokeMethod("backgroundTaskExtended", arguments: [
            "streamIds": Array(activeStreams),
            "estimatedTime": 180 // ~3 minutes typical for BGProcessingTask
        ])

        // Keep task alive while streams are active using async Task
        Task { [weak self] in
            guard let self = self else {
                task.setTaskCompleted(success: false)
                return
            }

            let keepAliveInterval: UInt64 = 30_000_000_000 // 30 seconds in nanoseconds
            var elapsedTime: TimeInterval = 0
            let maxTime: TimeInterval = 180 // 3 minutes

            while !self.activeStreams.isEmpty && elapsedTime < maxTime {
                try? await Task.sleep(nanoseconds: keepAliveInterval)
                elapsedTime += 30

                // Notify Flutter to keep streams alive
                await MainActor.run {
                    self.channel?.invokeMethod("backgroundKeepAlive", arguments: nil)
                }
            }

            // Mark task as complete
            task.setTaskCompleted(success: true)
            self.bgProcessingTask = nil
        }
    }


    deinit {
        NotificationCenter.default.removeObserver(self)
        endBackgroundTask()
        VoiceBackgroundAudioManager.shared.deactivate()
  }
}

/// Manages the method channel for App Intent invocations to Flutter.
/// Native Swift intents call this to invoke Flutter-side business logic.
final class AppIntentMethodChannel {
    static var shared: AppIntentMethodChannel?

    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(
            name: "qonduit/app_intents",
            binaryMessenger: messenger
        )
    }

    /// Invokes a Flutter handler for the given intent identifier.
    func invokeIntent(
        identifier: String,
        parameters: [String: Any]
    ) async -> [String: Any] {
        // No [weak self] needed here - the closure executes immediately on the
        // main queue and there's no retain cycle risk. Using weak self would
        // risk the continuation never resuming if self became nil.
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.channel.invokeMethod(
                    identifier,
                    arguments: parameters
                ) { result in
                    if let dict = result as? [String: Any] {
                        continuation.resume(returning: dict)
                    } else {
                        continuation.resume(returning: [
                            "success": false,
                            "error": "Invalid response from Flutter"
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
struct AskQonduitIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Qonduit"
    static var description = IntentDescription(
        "Start a Qonduit chat with an optional prompt."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Prompt",
        requestValueDialog: IntentDialog("What should Qonduit answer?")
    )
    var prompt: String?

    init() {}

    init(prompt: String?) {
        self.prompt = prompt
    }

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let parameters: [String: Any] = prompt?.isEmpty == false
            ? ["prompt": prompt ?? ""]
            : [:]
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.qonduit.ask_chat",
            parameters: parameters
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Opening chat"
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? "Unable to open Qonduit chat"
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct StartVoiceCallIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Voice Call"
    static var description = IntentDescription(
        "Start a live voice call with Qonduit."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.qonduit.start_voice_call",
            parameters: [:]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Starting voice call"
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? "Unable to start voice call"
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct QonduitSendTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Qonduit"
    static var description = IntentDescription(
        "Start a Qonduit chat with provided text."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Text",
        requestValueDialog: IntentDialog("What should Qonduit process?")
    )
    var text: String?

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.qonduit.send_text",
            parameters: ["text": trimmed ?? ""]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Sent to Qonduit"
            return .result(value: value)
        }

        let message = result["error"] as? String ?? "Unable to send text"
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct QonduitSendUrlIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Link to Qonduit"
    static var description = IntentDescription(
        "Send a URL into Qonduit for summary or analysis."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "URL",
        requestValueDialog: IntentDialog("Which link should Qonduit analyze?")
    )
    var url: URL

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.qonduit.send_url",
            parameters: ["url": url.absoluteString]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Sent link to Qonduit"
            return .result(value: value)
        }

        let message = result["error"] as? String ?? "Unable to send link"
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct QonduitSendImageIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Image to Qonduit"
    static var description = IntentDescription(
        "Send an image into Qonduit for analysis."
    )
    static var isDiscoverable = true
    static var openAppWhenRun = true

    @Parameter(
        title: "Image",
        requestValueDialog: IntentDialog("Choose an image for Qonduit.")
    )
    var image: IntentFile

    func perform() async throws
        -> some IntentResult & ReturnsValue<String> & OpensIntent
    {
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        if let type = image.type, !type.conforms(to: .image) {
            throw AppIntentError.executionFailed(
                "Only image files are supported."
            )
        }

        let data = try image.data
        let base64 = data.base64EncodedString()
        let name = image.filename ?? "shared_image.jpg"

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.qonduit.send_image",
            parameters: [
                "filename": name,
                "bytes": base64,
            ]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Sent image to Qonduit"
            return .result(value: value)
        }

        let message = result["error"] as? String ?? "Unable to send image"
        throw AppIntentError.executionFailed(message)
    }
}

@available(iOS 16.0, *)
struct AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: AskQonduitIntent(),
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
                intent: QonduitSendTextIntent(),
                phrases: [
                    "Send text to \(.applicationName)",
                    "Share text with \(.applicationName)",
                    "Summarize this in \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: QonduitSendUrlIntent(),
                phrases: [
                    "Summarize link in \(.applicationName)",
                    "Analyze link with \(.applicationName)",
                    "Send URL to \(.applicationName)",
                ]
            ),
            AppShortcut(
                intent: QonduitSendImageIntent(),
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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(
    _ engineBridge: FlutterImplicitEngineBridge
  ) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Setup App Intents method channel for native -> Flutter communication
    let appIntentRegistrar = engineBridge.applicationRegistrar
    AppIntentMethodChannel.shared = AppIntentMethodChannel(
      messenger: appIntentRegistrar.messenger()
    )

    let pasteRegistrar = engineBridge.applicationRegistrar
    NativePasteBridge.shared.configure(messenger: pasteRegistrar.messenger())

    // Setup background streaming handler
    let bgRegistrar = engineBridge.applicationRegistrar
    let channel = FlutterMethodChannel(
      name: "qonduit/background_streaming",
      binaryMessenger: bgRegistrar.messenger()
    )

    backgroundStreamingHandler = BackgroundStreamingHandler()
    backgroundStreamingHandler?.setup(with: channel)

    // Register BGTaskScheduler tasks
    backgroundStreamingHandler?.registerBackgroundTasks()

    // Register method call handler
    channel.setMethodCallHandler { [weak self] (call, result) in
      self?.backgroundStreamingHandler?.handle(call, result: result)
    }

    // Setup cookie manager channel for WebView cookie access
    let cookieRegistrar = engineBridge.applicationRegistrar
    let cookieChannel = FlutterMethodChannel(
      name: "com.qonduit.app/cookies",
      binaryMessenger: cookieRegistrar.messenger()
    )

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
