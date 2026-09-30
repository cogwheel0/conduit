import AVFoundation
import Flutter

private let conduitVoiceAudioRouteChannelName = "app.cogwheel.conduit/voice_audio_route"

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
            case "setSpeakerphoneEnabled":
                let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                result(self.setSpeakerphoneEnabled(enabled))
            case "currentRoute":
                result(self.currentRoutePayload(operation: "currentRoute"))
            case "setActiveCallKitCallId":
                guard let callId =
                    (call.arguments as? [String: Any])?["callId"] as? String
                else {
                    result(false)
                    return
                }
                result(NativeSttBridge.shared.setActiveCallKitCallId(callId))
            case "beginResponseWaitCapture":
                let callKitCallId =
                    (call.arguments as? [String: Any])?["callKitCallId"] as? String
                guard let transition = NativeSttBridge.shared
                    .prepareResponseWaitCapture(callKitCallId: callKitCallId)
                else {
                    result(false)
                    return
                }
                Task {
                    let accepted = await NativeSttBridge.shared
                        .finishResponseWaitCapture(transition)
                    await MainActor.run {
                        result(accepted)
                    }
                }
            case "endResponseWaitCapture":
                let shutdown = NativeSttBridge.shared
                    .prepareEndResponseWaitCapture()
                Task {
                    let stopped = await NativeSttBridge.shared
                        .finishEndResponseWaitCapture(shutdown)
                    await MainActor.run {
                        result(stopped)
                    }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    func responseWaitCaptureFailed(_ error: Error) {
        let errorDomain = (error as NSError).domain
        let errorCode = (error as NSError).code
        DispatchQueue.main.async { [weak self] in
            self?.methodChannel?.invokeMethod(
                "responseWaitCaptureFailed",
                arguments: [
                    "message": "iOS response-wait audio capture stopped after an audio route change.",
                    "domain": errorDomain,
                    "code": errorCode,
                ]
            )
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

    private func setSpeakerphoneEnabled(_ enabled: Bool) -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            var payload = currentRoutePayload(operation: "setSpeakerphoneEnabled")
            payload["enabled"] = enabled
            return payload
        } catch {
            var payload = currentRoutePayload(operation: "setSpeakerphoneEnabled")
            payload["enabled"] = enabled
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
