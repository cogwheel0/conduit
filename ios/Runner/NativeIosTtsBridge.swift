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

final class NativeIosTtsBridge: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
    static let shared = NativeIosTtsBridge()
    private static let startAcknowledgementTimeout: TimeInterval = 2

    private let synthesizer = AVSpeechSynthesizer()
    private let pendingStarts = NativeIosTtsPendingStarts()
    private var methodChannel: FlutterMethodChannel?
    private var eventSink: FlutterEventSink?

    private override init() {
        super.init()
        synthesizer.usesApplicationAudioSession = true
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
