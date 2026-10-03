import AVFoundation
import BackgroundTasks
import Flutter
import UIKit

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
class BackgroundStreamingHandler: NSObject, ConduitBridge, BackgroundStreamingHostApi {
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var bgProcessingTask: BGTask?
    private var activeLeases: [String: BackgroundStreamingLease] = [:]
    private var flutterApi: BackgroundStreamingFlutterApi?

    static let shared = BackgroundStreamingHandler()
    static let processingTaskIdentifier = "app.cogwheel.conduit.refresh"

    override init() {
        super.init()
        setupNotifications()
    }
    
    func attach(to host: ConduitBridgeHost) {
        let messenger = host.messenger
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
                // keepAlive replaces the task before ending the old one. A
                // replaced task expiring is not a suspension: the newer
                // task still holds background time.
                guard self.backgroundTask == taskIdentifier else {
                    if taskIdentifier != .invalid {
                        UIApplication.shared.endBackgroundTask(taskIdentifier)
                    }
                    return
                }
                self.notifyStreamsSuspending(reason: "background_task_expiring")
                self.flutterApi?.backgroundTaskExpiring { _ in }
                self.endBackgroundTask()
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
