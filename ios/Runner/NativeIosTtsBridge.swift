import AVFoundation
import Flutter

private let nativeIosTtsMethodChannelName = "app.cogwheel.conduit/native_ios_tts"
private let nativeIosTtsEventChannelName = "app.cogwheel.conduit/native_ios_tts/events"

final class NativeIosTtsStartAcknowledgement {
    private let lock = NSLock()
    private var completion: FlutterResult?
    private var timeoutTimer: Timer?

    init(completion: @escaping FlutterResult) {
        self.completion = completion
    }

    func armTimeout(after seconds: TimeInterval, onTimeout: @escaping () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            onTimeout()
        }
        lock.lock()
        guard completion != nil else {
            lock.unlock()
            return
        }
        timeoutTimer = timer
        lock.unlock()
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    func resolve(started: Bool) -> Bool {
        lock.lock()
        guard let completion else {
            lock.unlock()
            return false
        }
        self.completion = nil
        let timer = timeoutTimer
        timeoutTimer = nil
        lock.unlock()
        timer?.invalidate()
        completion(started)
        return true
    }
}

final class NativeIosTtsPendingStarts {
    private let lock = NSLock()
    private var acknowledgements: [
        ObjectIdentifier: NativeIosTtsStartAcknowledgement
    ] = [:]

    func register(
        _ acknowledgement: NativeIosTtsStartAcknowledgement,
        for utteranceId: ObjectIdentifier
    ) {
        lock.lock()
        acknowledgements[utteranceId] = acknowledgement
        lock.unlock()
    }

    @discardableResult
    func resolve(_ utteranceId: ObjectIdentifier, started: Bool) -> Bool {
        lock.lock()
        let acknowledgement = acknowledgements.removeValue(forKey: utteranceId)
        lock.unlock()
        return acknowledgement?.resolve(started: started) ?? false
    }

    func resolveAll(started: Bool) {
        lock.lock()
        let pending = Array(acknowledgements.values)
        acknowledgements.removeAll(keepingCapacity: false)
        lock.unlock()
        pending.forEach { $0.resolve(started: started) }
    }
}

final class NativeIosTtsBridge: NSObject, ConduitBridge, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
    static let shared = NativeIosTtsBridge()
    private static let startAcknowledgementTimeout: TimeInterval = 2

    private let synthesizer = AVSpeechSynthesizer()
    private let pendingStarts = NativeIosTtsPendingStarts()
    private var methodChannel: FlutterMethodChannel?
    private var fileSynthesis: NativeIosTtsAudioFile?
    private var eventSink: FlutterEventSink?

    private override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
        synthesizer.delegate = self
    }

    deinit {}

    func attach(to host: ConduitBridgeHost) {
        let messenger = host.messenger
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

    /// File synthesis requires nonempty text and replaces any pending task.
    /// Returns a local path and durationMs, or a FlutterError on failure.
    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isAvailable":
            result(true)
        case "getVoices":
            loadVoicesForPicker(result: result)
        case "synthesize":
            guard let arguments = call.arguments as? [String: Any],
                  let text = arguments["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: "INVALID_TEXT", message: "Speech text is empty", details: nil))
                return
            }
            fileSynthesis?.cancel()
            let utterance = AVSpeechUtterance(string: text)
            if let identifier = arguments["voiceIdentifier"] as? String {
                utterance.voice = resolveVoice(identifier)
            }
            utterance.rate = Self.speechRate(from: arguments["rate"])
            utterance.pitchMultiplier = Self.floatValue(arguments["pitch"], fallback: 1, min: 0.5, max: 2)
            utterance.volume = Self.floatValue(arguments["volume"], fallback: 1, min: 0, max: 1)
            let task = NativeIosTtsAudioFile(utterance: utterance) { [weak self] value in
                self?.fileSynthesis = nil
                result(value)
            }
            fileSynthesis = task
            task.start()
        case "cancelSynthesis":
            fileSynthesis?.cancel()
            result(true)
        case "speak":
            guard let arguments = call.arguments as? [String: Any],
                  let text = arguments["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                result(false)
                return
            }

            if arguments["voiceCall"] as? Bool == true {
                do {
                    try AVAudioSession.sharedInstance().setActive(
                        true,
                        options: .notifyOthersOnDeactivation
                    )
                } catch {
                    result(FlutterError(
                        code: "AUDIO_SESSION_ACTIVATION_FAILED",
                        message: "Unable to activate voice-call audio for speech",
                        details: error.localizedDescription
                    ))
                    return
                }
            }

            if synthesizer.isSpeaking || synthesizer.isPaused {
                resolveAllPendingStarts(started: false)
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
            let utteranceId = ObjectIdentifier(utterance)
            let acknowledgement = NativeIosTtsStartAcknowledgement(
                completion: result
            )
            pendingStarts.register(acknowledgement, for: utteranceId)
            acknowledgement.armTimeout(
                after: Self.startAcknowledgementTimeout
            ) { [weak self] in
                guard let self,
                      self.pendingStarts.resolve(
                        utteranceId,
                        started: false
                      ) else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
            }
            synthesizer.speak(utterance)
        case "stop":
            resolveAllPendingStarts(started: false)
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

    @discardableResult
    private func resolvePendingStart(
        _ utteranceId: ObjectIdentifier,
        started: Bool
    ) -> Bool {
        pendingStarts.resolve(utteranceId, started: started)
    }

    private func resolveAllPendingStarts(started: Bool) {
        pendingStarts.resolveAll(started: started)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard resolvePendingStart(ObjectIdentifier(utterance), started: true)
        else { return }
        emit(["type": "start"])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        _ = resolvePendingStart(ObjectIdentifier(utterance), started: false)
        emit(["type": "complete"])
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        _ = resolvePendingStart(ObjectIdentifier(utterance), started: false)
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

/// File synthesis is separate from live conversational speech. Generated
/// buffers are written serially on the main queue.
private final class NativeIosTtsAudioFile: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let utterance: AVSpeechUtterance
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit-speech-\(UUID().uuidString).caf")
    private var completion: FlutterResult?
    private var file: AVAudioFile?
    private var seconds: Double = 0
    private var timeout: DispatchWorkItem?

    init(utterance: AVSpeechUtterance, completion: @escaping FlutterResult) {
        self.utterance = utterance
        self.completion = completion
        super.init()
        synthesizer.delegate = self
    }

    /// Starts file synthesis with a two-minute deadline; buffers are written on the main queue.
    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        synthesizer.write(utterance) { [weak self] buffer in
            guard let buffer = buffer as? AVAudioPCMBuffer else { return }
            DispatchQueue.main.async { self?.append(buffer) }
        }
    }

    /// Writes admitted buffers until the empty end marker; empty audio and write errors cancel.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard completion != nil else { return }
        if buffer.frameLength == 0 {
            if seconds > 0 {
                finish(["path": url.path, "durationMs": seconds * 1000])
            } else {
                cancel()
            }
            return
        }
        do {
            if file == nil {
                file = try AVAudioFile(
                    forWriting: url, settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try file?.write(from: buffer)
            seconds += Double(buffer.frameLength) / buffer.format.sampleRate
        } catch {
            cancel()
        }
    }

    func cancel() {
        finish(FlutterError(code: "SYNTHESIS_FAILED", message: "Device speech could not be prepared", details: nil))
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        cancel()
    }

    /// Closes the file and delivers one result, retaining audio only on success.
    private func finish(_ value: Any) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        file = nil
        if value is FlutterError { try? FileManager.default.removeItem(at: url) }
        completion(value)
    }
}
