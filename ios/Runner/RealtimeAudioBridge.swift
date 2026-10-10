import AVFoundation
import Flutter

private let realtimeAudioChannelName = "app.cogwheel.conduit/realtime_audio"
private let realtimeAudioEventsChannelName =
    "app.cogwheel.conduit/realtime_audio/events"

/// The realtime voice's playback, mirroring Open WebUI's `realtime-audio.js`
/// worklet: speech is queued per item, starts once 80 ms are buffered or its
/// response has ended, and a clear reports how much of each item was played.
///
/// `render` runs on the audio thread; everything else on the main thread.
final class RealtimePlaybackQueue {
    private struct Chunk {
        let responseId: String
        let itemId: String
        let contentIndex: Int
        let samples: [Float]
        var offset = 0
    }

    private struct Rendered {
        let responseId: String
        let itemId: String
        let contentIndex: Int
        var samples: Int
    }

    private static let prebufferSamples = 1920

    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var queued = 0
    private var received = 0
    private var playing = false
    private var ended = Set<String>()
    private var rendered: [String: Rendered] = [:]
    private var clearId = 0
    private var playedSinceReport = 0
    private var outputEnergy: Float = 0
    private var outputSamples = 0

    func enqueue(responseId: String, itemId: String, contentIndex: Int, pcm: Data) {
        let samples: [Float] = pcm.withUnsafeBytes { raw in
            let values = raw.bindMemory(to: Int16.self)
            return values.map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        chunks.append(
            Chunk(
                responseId: responseId,
                itemId: itemId,
                contentIndex: contentIndex,
                samples: samples
            )
        )
        queued += samples.count
        received += samples.count
    }

    func endResponse(_ responseId: String) {
        lock.lock()
        ended.insert(responseId)
        lock.unlock()
    }

    /// Drops everything queued and returns what was played of each item.
    func clear(id: Int) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        clearId = id
        let report = rendered.values.map {
            [
                "responseId": $0.responseId,
                "itemId": $0.itemId,
                "contentIndex": $0.contentIndex,
                "samples": $0.samples,
            ] as [String: Any]
        }
        chunks.removeAll()
        queued = 0
        playing = false
        rendered.removeAll()
        ended.removeAll()
        playedSinceReport = 0
        outputEnergy = 0
        return report
    }

    func reset() {
        _ = clear(id: 0)
        lock.lock()
        received = 0
        lock.unlock()
    }

    func render(into output: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        if !playing,
            queued >= Self.prebufferSamples
                || (chunks.first.map { ended.contains($0.responseId) } ?? false)
        {
            playing = true
        }
        var offset = 0
        while playing, offset < count, !chunks.isEmpty {
            var chunk = chunks[0]
            let take = min(count - offset, chunk.samples.count - chunk.offset)
            for index in 0..<take {
                let sample = chunk.samples[chunk.offset + index]
                output[offset + index] = sample
                outputEnergy += sample * sample
            }
            offset += take
            chunk.offset += take
            queued -= take
            playedSinceReport += take
            let key = "\(chunk.itemId):\(chunk.contentIndex)"
            var position =
                rendered[key]
                ?? Rendered(
                    responseId: chunk.responseId,
                    itemId: chunk.itemId,
                    contentIndex: chunk.contentIndex,
                    samples: 0
                )
            position.samples += take
            rendered[key] = position
            if chunk.offset == chunk.samples.count {
                chunks.removeFirst()
            } else {
                chunks[0] = chunk
            }
        }
        if queued == 0 { playing = false }
        for index in offset..<count { output[index] = 0 }
        outputSamples += count
    }

    /// The playback half of a report; resets the levels it measured.
    func report() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let level = outputSamples > 0 ? sqrt(outputEnergy / Float(outputSamples)) : 0
        let report: [String: Any] = [
            "clearId": clearId,
            "playbackActive": playedSinceReport > 0,
            "queued": queued,
            "received": received,
            "outputLevel": Double(level),
        ]
        playedSinceReport = 0
        outputEnergy = 0
        outputSamples = 0
        return report
    }
}

/// Captures the microphone and plays a realtime voice on one voice-processing
/// engine at 24 kHz, so the system cancels the voice's echo from what the
/// microphone hears. The audio session's category and mode belong to the
/// call's coordinator; this only runs the engine inside it.
final class RealtimeAudioBridge: NSObject, ConduitBridge, FlutterStreamHandler {
    static let shared = RealtimeAudioBridge()

    private static let sampleRate = 24000.0
    private static let frameSamples = 960

    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private var reportTimer: Timer?
    private let playback = RealtimePlaybackQueue()
    private let captureFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    )!

    // Touched only on the main thread.
    private var captureEnabled = false
    private var pendingCapture: [Int16] = []
    private var inputEnergy: Float = 0
    private var inputSamples = 0

    private override init() {}

    func attach(to host: ConduitBridgeHost) {
        let messenger = host.messenger
        let channel = FlutterMethodChannel(
            name: realtimeAudioChannelName,
            binaryMessenger: messenger
        )
        methodChannel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else {
                result(nil)
                return
            }
            let arguments = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "start":
                do {
                    try self.start()
                    result(nil)
                } catch {
                    self.stop()
                    result(
                        FlutterError(
                            code: "realtime_audio_start_failed",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                }
            case "stop":
                self.stop()
                result(nil)
            case "setCaptureEnabled":
                self.captureEnabled = arguments["enabled"] as? Bool ?? false
                self.pendingCapture.removeAll()
                result(nil)
            case "enqueue":
                guard let responseId = arguments["responseId"] as? String,
                    let itemId = arguments["itemId"] as? String,
                    let contentIndex = arguments["contentIndex"] as? Int,
                    let pcm = arguments["pcm"] as? FlutterStandardTypedData
                else {
                    result(nil)
                    return
                }
                self.playback.enqueue(
                    responseId: responseId,
                    itemId: itemId,
                    contentIndex: contentIndex,
                    pcm: pcm.data
                )
                result(nil)
            case "endResponse":
                if let responseId = arguments["responseId"] as? String {
                    self.playback.endResponse(responseId)
                }
                result(nil)
            case "clear":
                result(self.playback.clear(id: arguments["clearId"] as? Int ?? 0))
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        let events = FlutterEventChannel(
            name: realtimeAudioEventsChannelName,
            binaryMessenger: messenger
        )
        eventChannel = events
        events.setStreamHandler(self)
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func start() throws {
        stop()
        let engine = AVAudioEngine()
        // Voice processing on the input runs the output through it too, which
        // is what lets it cancel the voice from the microphone.
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: captureFormat)
        else {
            throw NSError(
                domain: "RealtimeAudio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The microphone is unavailable."]
            )
        }
        self.converter = converter
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) {
            [weak self] buffer, _ in
            self?.captured(buffer)
        }

        let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: 1
        )!
        let playback = self.playback
        let source = AVAudioSourceNode(format: playbackFormat) {
            _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers.first?.mData else { return noErr }
            playback.render(
                into: data.assumingMemoryBound(to: Float.self),
                count: Int(frameCount)
            )
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: playbackFormat)

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }

        engine.prepare()
        try engine.start()
        self.engine = engine
        sourceNode = source
        reportTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            self?.sendReport()
        }
    }

    private func stop() {
        reportTimer?.invalidate()
        reportTimer = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine = nil
        sourceNode = nil
        converter = nil
        captureEnabled = false
        pendingCapture.removeAll()
        inputEnergy = 0
        inputSamples = 0
        playback.reset()
    }

    /// A route change stops the engine; it is started again on the new route.
    private func restartAfterConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            send([
                "type": "failure",
                "message": "The call audio stopped after an audio route change.",
            ])
        }
    }

    /// Runs on the audio thread: converts to 24 kHz PCM16 and hands it over.
    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity)
        else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = converted.int16ChannelData?[0] else { return }
        let samples = Array(
            UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))
        )
        DispatchQueue.main.async { [weak self] in
            self?.deliver(samples)
        }
    }

    private func deliver(_ samples: [Int16]) {
        guard engine != nil, captureEnabled else { return }
        for sample in samples {
            let value = Float(sample) / 32768
            inputEnergy += value * value
        }
        inputSamples += samples.count
        pendingCapture.append(contentsOf: samples)
        while pendingCapture.count >= Self.frameSamples {
            let frame = pendingCapture.prefix(Self.frameSamples)
            pendingCapture.removeFirst(Self.frameSamples)
            let data = frame.withUnsafeBufferPointer { Data(buffer: $0) }
            send(["type": "frame", "pcm": FlutterStandardTypedData(bytes: data)])
        }
    }

    private func sendReport() {
        guard engine != nil else { return }
        var report = playback.report()
        report["type"] = "report"
        report["inputLevel"] =
            inputSamples > 0 ? Double(sqrt(inputEnergy / Float(inputSamples))) : 0.0
        inputEnergy = 0
        inputSamples = 0
        let session = AVAudioSession.sharedInstance()
        report["outputLatencyMs"] = Int(
            ((session.outputLatency + session.ioBufferDuration) * 1000).rounded()
        )
        send(report)
    }

    private func send(_ event: [String: Any]) {
        eventSink?(event)
    }
}
