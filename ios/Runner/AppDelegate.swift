import AVFoundation
import BackgroundTasks
import Flutter
import AppIntents
import UIKit
import UniformTypeIdentifiers
import WebKit

final class NativeGlassContainerViewFactory: NSObject, FlutterPlatformViewFactory {
    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        NativeGlassContainerPlatformView(frame: frame, arguments: args)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class NativeGlassContainerPlatformView: NSObject, FlutterPlatformView {
    private let shadowView: UIView
    private let containerView: UIView
    private let blurView: UIVisualEffectView
    private let tintOverlay = UIView()

    init(frame: CGRect, arguments args: Any?) {
        shadowView = UIView(frame: frame)
        containerView = UIView(frame: frame)
        blurView = UIVisualEffectView(effect: nil)
        super.init()

        let params = args as? [String: Any] ?? [:]
        let styleName = params["blurStyle"] as? String ?? "systemUltraThinMaterial"
        let cornerRadius = CGFloat(params["cornerRadius"] as? Double ?? 24)
        let isDark = UIScreen.main.traitCollection.userInterfaceStyle == .dark

        shadowView.backgroundColor = .clear
        shadowView.layer.cornerRadius = cornerRadius
        shadowView.layer.masksToBounds = false
        shadowView.layer.shadowColor = UIColor.black.cgColor

        containerView.backgroundColor = .clear
        containerView.layer.cornerRadius = cornerRadius
        containerView.layer.masksToBounds = true
        containerView.frame = shadowView.bounds
        containerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        shadowView.addSubview(containerView)

        if #available(iOS 26.0, *) {
            shadowView.layer.shadowOpacity = 0
            shadowView.layer.shadowRadius = 0
            shadowView.layer.shadowOffset = .zero

            blurView.frame = containerView.bounds
            blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blurView.effect = UIGlassEffect()
            containerView.addSubview(blurView)

            containerView.layer.borderWidth = 0
            containerView.layer.borderColor = UIColor.clear.cgColor
        } else {
            shadowView.layer.shadowOpacity = isDark ? 0.10 : 0.22
            shadowView.layer.shadowRadius = isDark ? 10 : 14
            shadowView.layer.shadowOffset = CGSize(width: 0, height: 4)

            blurView.frame = containerView.bounds
            blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            blurView.effect = UIBlurEffect(style: mapBlurStyle(styleName))
            containerView.addSubview(blurView)

            tintOverlay.frame = containerView.bounds
            tintOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            tintOverlay.backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.04)
                    : UIColor.white.withAlphaComponent(0.10)
            }
            containerView.addSubview(tintOverlay)

            containerView.layer.borderWidth = 0.5
            containerView.layer.borderColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.white.withAlphaComponent(0.28)
                    : UIColor.white.withAlphaComponent(0.30)
            }.cgColor
        }
    }

    func view() -> UIView {
        shadowView
    }

    private func mapBlurStyle(_ name: String) -> UIBlurEffect.Style {
        switch name {
        case "systemThinMaterial":
            return .systemThinMaterial
        case "systemMaterial":
            return .systemMaterial
        case "systemThickMaterial":
            return .systemThickMaterial
        case "systemChromeMaterial":
            return .systemChromeMaterial
        default:
            return .systemUltraThinMaterial
        }
    }
}

final class NativeChatInputViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        NativeChatInputPlatformView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            messenger: messenger
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}

final class NativeChatInputPlatformView: NSObject, FlutterPlatformView, UITextViewDelegate {
    private let containerView: UIView
    private let textView: UITextView
    private let placeholderLabel: UILabel
    private let channel: FlutterMethodChannel

    private var minHeight: CGFloat = 44
    private var maxHeight: CGFloat = 120
    private var lastReportedHeight: CGFloat = -1
    private var sendOnEnter = false

    private var accessoryToolbar: UIToolbar?
    private var plusButton: UIBarButtonItem?
    private var micButton: UIBarButtonItem?
    private var sendButton: UIBarButtonItem?

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        messenger: FlutterBinaryMessenger
    ) {
        containerView = UIView(frame: frame)
        textView = UITextView(frame: .zero)
        placeholderLabel = UILabel(frame: .zero)
        channel = FlutterMethodChannel(
            name: "conduit/native_chat_input_\(viewId)",
            binaryMessenger: messenger
        )

        super.init()

        configureView(args: args)

        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }

        DispatchQueue.main.async { [weak self] in
            self?.reportHeightIfNeeded()
        }
    }

    func view() -> UIView {
        containerView
    }

    private func configureView(args: Any?) {
        let params = args as? [String: Any] ?? [:]

        minHeight = CGFloat(params["minHeight"] as? Double ?? 44)
        maxHeight = CGFloat(params["maxHeight"] as? Double ?? 120)
        let text = params["text"] as? String ?? ""
        let placeholder = params["placeholder"] as? String ?? ""
        let enabled = params["enabled"] as? Bool ?? true
        sendOnEnter = params["sendOnEnter"] as? Bool ?? false
        let fontSize = CGFloat(params["fontSize"] as? Double ?? 17)
        let textColorArgb = (params["textColor"] as? NSNumber)?.uint32Value
        let placeholderColorArgb = (params["placeholderColor"] as? NSNumber)?.uint32Value
        let textLength = (text as NSString).length
        let selectionBase = params["selectionBaseOffset"] as? Int ?? textLength
        let selectionExtent = params["selectionExtentOffset"] as? Int ?? textLength

        let showAccessoryBar = params["showInputAccessoryBar"] as? Bool ?? false
        let accessoryCanSend = params["accessoryCanSend"] as? Bool ?? false
        let accessoryCanUseMic = params["accessoryCanUseMic"] as? Bool ?? false
        let accessoryIsRecording = params["accessoryIsRecording"] as? Bool ?? false

        containerView.backgroundColor = .clear

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.delegate = self
        textView.isScrollEnabled = false
        textView.isEditable = enabled
        textView.isSelectable = enabled
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .yes
        textView.smartDashesType = .yes
        textView.smartQuotesType = .yes
        textView.smartInsertDeleteType = .yes
        // Add vertical inset so single-line placeholder/text is visually
        // centered in the 44pt composer shell, while still allowing multiline
        // growth naturally.
        textView.textContainerInset = UIEdgeInsets(
            top: 12,
            left: 0,
            bottom: 8,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.text = text
        textView.textColor = color(fromARGB: textColorArgb) ?? .label
        textView.returnKeyType = sendOnEnter ? .send : .default

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = placeholder
        placeholderLabel.numberOfLines = 1
        placeholderLabel.font = textView.font
        placeholderLabel.textColor = color(fromARGB: placeholderColorArgb)
            ?? UIColor.secondaryLabel.withAlphaComponent(0.85)

        containerView.addSubview(textView)
        containerView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: containerView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(
                equalTo: textView.topAnchor,
                constant: textView.textContainerInset.top
            ),
        ])

        if let start = textView.position(from: textView.beginningOfDocument, offset: selectionBase),
           let end = textView.position(from: textView.beginningOfDocument, offset: selectionExtent) {
            textView.selectedTextRange = textView.textRange(from: start, to: end)
        }

        configureAccessoryBar(
            show: showAccessoryBar,
            canSend: accessoryCanSend,
            canUseMic: accessoryCanUseMic,
            isRecording: accessoryIsRecording
        )

        updatePlaceholderVisibility()
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {
        case "setText":
            let text = args?["text"] as? String ?? ""
            if textView.text != text {
                textView.text = text
                updatePlaceholderVisibility()
                reportHeightIfNeeded()
            }
            result(nil)
        case "setSelection":
            let base = args?["baseOffset"] as? Int ?? -1
            let extent = args?["extentOffset"] as? Int ?? -1
            setSelection(baseOffset: base, extentOffset: extent)
            result(nil)
        case "focus":
            textView.becomeFirstResponder()
            result(nil)
        case "unfocus":
            textView.resignFirstResponder()
            result(nil)
        case "setEnabled":
            let enabled = args?["enabled"] as? Bool ?? true
            textView.isEditable = enabled
            textView.isSelectable = enabled
            result(nil)
        case "setPlaceholder":
            let placeholder = args?["placeholder"] as? String ?? ""
            placeholderLabel.text = placeholder
            result(nil)
        case "setSendOnEnter":
            sendOnEnter = args?["sendOnEnter"] as? Bool ?? false
            textView.returnKeyType = sendOnEnter ? .send : .default
            textView.reloadInputViews()
            result(nil)
        case "setAccessoryConfig":
            let show = args?["showInputAccessoryBar"] as? Bool ?? false
            let canSend = args?["accessoryCanSend"] as? Bool ?? false
            let canUseMic = args?["accessoryCanUseMic"] as? Bool ?? false
            let isRecording = args?["accessoryIsRecording"] as? Bool ?? false
            configureAccessoryBar(
                show: show,
                canSend: canSend,
                canUseMic: canUseMic,
                isRecording: isRecording
            )
            result(nil)
        case "setTextColor":
            let value = (args?["color"] as? NSNumber)?.uint32Value
            textView.textColor = color(fromARGB: value) ?? .label
            result(nil)
        case "setPlaceholderColor":
            let value = (args?["color"] as? NSNumber)?.uint32Value
            placeholderLabel.textColor = color(fromARGB: value)
                ?? UIColor.secondaryLabel.withAlphaComponent(0.85)
            result(nil)
        case "setFontSize":
            let fontSize = CGFloat(args?["fontSize"] as? Double ?? 17)
            textView.font = UIFont.systemFont(ofSize: fontSize)
            placeholderLabel.font = textView.font
            reportHeightIfNeeded()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderVisibility()
        channel.invokeMethod("onTextChanged", arguments: [
            "text": textView.text ?? "",
        ])
        reportHeightIfNeeded()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        channel.invokeMethod("onFocusChanged", arguments: ["hasFocus": true])
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        channel.invokeMethod("onFocusChanged", arguments: ["hasFocus": false])
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        let range = textView.selectedRange
        channel.invokeMethod("onSelectionChanged", arguments: [
            "baseOffset": range.location,
            "extentOffset": range.location + range.length,
        ])
        reportHeightIfNeeded()
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if sendOnEnter && text == "\n" {
            channel.invokeMethod("onSubmitted", arguments: [
                "text": textView.text ?? "",
            ])
            return false
        }
        return true
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
    }

    private func reportHeightIfNeeded() {
        let width = max(textView.bounds.width, 1)
        let fitting = textView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let clamped = min(max(fitting.height, minHeight), maxHeight)
        textView.isScrollEnabled = fitting.height > maxHeight

        guard abs(clamped - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = clamped
        channel.invokeMethod("onHeightChanged", arguments: [
            "height": Double(clamped),
        ])
    }

    private func setSelection(baseOffset: Int, extentOffset: Int) {
        let textLength = (textView.text as NSString?)?.length ?? 0
        let clampedBase = min(max(baseOffset, 0), textLength)
        let clampedExtent = min(max(extentOffset, 0), textLength)
        let startOffset = min(clampedBase, clampedExtent)
        let endOffset = max(clampedBase, clampedExtent)

        guard let start = textView.position(from: textView.beginningOfDocument, offset: startOffset),
              let end = textView.position(from: textView.beginningOfDocument, offset: endOffset),
              let range = textView.textRange(from: start, to: end) else {
            return
        }

        textView.selectedTextRange = range
    }

    private func configureAccessoryBar(
        show: Bool,
        canSend: Bool,
        canUseMic: Bool,
        isRecording: Bool
    ) {
        guard show else {
            if textView.inputAccessoryView != nil {
                textView.inputAccessoryView = nil
                textView.reloadInputViews()
            }
            return
        }

        if accessoryToolbar == nil {
            let toolbar = UIToolbar()
            toolbar.translatesAutoresizingMaskIntoConstraints = false
            toolbar.sizeToFit()

            let plusItem = UIBarButtonItem(
                image: UIImage(systemName: "plus"),
                style: .plain,
                target: self,
                action: #selector(accessoryPlusTapped)
            )
            let micItem = UIBarButtonItem(
                image: UIImage(systemName: "mic"),
                style: .plain,
                target: self,
                action: #selector(accessoryMicTapped)
            )
            let sendItem = UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.circle.fill"),
                style: .done,
                target: self,
                action: #selector(accessorySendTapped)
            )

            plusButton = plusItem
            micButton = micItem
            sendButton = sendItem

            toolbar.items = [
                plusItem,
                UIBarButtonItem(
                    barButtonSystemItem: .flexibleSpace,
                    target: nil,
                    action: nil
                ),
                micItem,
                UIBarButtonItem(
                    barButtonSystemItem: .flexibleSpace,
                    target: nil,
                    action: nil
                ),
                sendItem,
            ]
            accessoryToolbar = toolbar
            textView.inputAccessoryView = toolbar
        }

        micButton?.image = UIImage(systemName: isRecording ? "mic.fill" : "mic")
        plusButton?.isEnabled = true
        micButton?.isEnabled = canUseMic
        sendButton?.isEnabled = canSend
        textView.reloadInputViews()
    }

    @objc
    private func accessoryPlusTapped() {
        channel.invokeMethod("onAccessoryAction", arguments: ["action": "plus"])
    }

    @objc
    private func accessoryMicTapped() {
        channel.invokeMethod("onAccessoryAction", arguments: ["action": "mic"])
    }

    @objc
    private func accessorySendTapped() {
        channel.invokeMethod("onAccessoryAction", arguments: ["action": "send"])
    }

    private func color(fromARGB argb: UInt32?) -> UIColor? {
        guard let argb else { return nil }

        let alpha = CGFloat((argb >> 24) & 0xFF) / 255.0
        let red = CGFloat((argb >> 16) & 0xFF) / 255.0
        let green = CGFloat((argb >> 8) & 0xFF) / 255.0
        let blue = CGFloat(argb & 0xFF) / 255.0

        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
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

    static let processingTaskIdentifier = "app.cogwheel.conduit.refresh"

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
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ConduitStreaming") { [weak self] in
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
            let newTask = UIApplication.shared.beginBackgroundTask(withName: "ConduitStreaming") { [weak self] in
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
            name: "conduit/app_intents",
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
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let parameters: [String: Any] = prompt?.isEmpty == false
            ? ["prompt": prompt ?? ""]
            : [:]
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.ask_chat",
            parameters: parameters
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Opening chat"
            return .result(value: value)
        }

        let message = result["error"] as? String
            ?? "Unable to open Conduit chat"
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
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.start_voice_call",
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
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_text",
            parameters: ["text": trimmed ?? ""]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Sent to Conduit"
            return .result(value: value)
        }

        let message = result["error"] as? String ?? "Unable to send text"
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
        guard let channel = AppIntentMethodChannel.shared else {
            throw AppIntentError.executionFailed("App not ready")
        }

        let result = await channel.invokeIntent(
            identifier: "app.cogwheel.conduit.send_url",
            parameters: ["url": url.absoluteString]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Sent link to Conduit"
            return .result(value: value)
        }

        let message = result["error"] as? String ?? "Unable to send link"
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
            identifier: "app.cogwheel.conduit.send_image",
            parameters: [
                "filename": name,
                "bytes": base64,
            ]
        )

        if let success = result["success"] as? Bool, success {
            let value = result["value"] as? String ?? "Sent image to Conduit"
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
@objc class AppDelegate: FlutterAppDelegate {
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
    GeneratedPluginRegistrant.register(with: self)

    // Register native chat input platform view.
    if let registrar = self.registrar(forPlugin: "ConduitNativeChatInput") {
      let factory = NativeChatInputViewFactory(messenger: registrar.messenger())
      registrar.register(factory, withId: "conduit/native_chat_input")
    }

    // Register native iOS glass container platform view.
    if let registrar = self.registrar(forPlugin: "ConduitNativeGlassContainer") {
      let factory = NativeGlassContainerViewFactory()
      registrar.register(factory, withId: "conduit/native_glass_container")
    }

    // Setup App Intents method channel for native -> Flutter communication
    if let registrar = self.registrar(forPlugin: "AppIntentMethodChannel") {
      AppIntentMethodChannel.shared = AppIntentMethodChannel(
        messenger: registrar.messenger()
      )
    }

    // Setup background streaming handler using the plugin registry messenger
    if let registrar = self.registrar(forPlugin: "BackgroundStreamingHandler") {
      let channel = FlutterMethodChannel(
        name: "conduit/background_streaming",
        binaryMessenger: registrar.messenger()
      )

      backgroundStreamingHandler = BackgroundStreamingHandler()
      backgroundStreamingHandler?.setup(with: channel)

      // Register BGTaskScheduler tasks
      backgroundStreamingHandler?.registerBackgroundTasks()

      // Register method call handler
      channel.setMethodCallHandler { [weak self] (call, result) in
        self?.backgroundStreamingHandler?.handle(call, result: result)
      }
    }

    // Setup cookie manager channel for WebView cookie access
    if let registrar = self.registrar(forPlugin: "CookieManagerChannel") {
      let cookieChannel = FlutterMethodChannel(
        name: "com.conduit.app/cookies",
        binaryMessenger: registrar.messenger()
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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
