import AVFoundation
import Flutter
import Speech
import UIKit

private let nativeSttMethodChannelName = "app.cogwheel.conduit/native_stt"
private let nativeSttEventChannelName = "app.cogwheel.conduit/native_stt/events"

private protocol NativeSttSession: AnyObject {
  func stop() async
}

private enum NativeSttAvailability {
  static func available(_ engine: String) -> [String: Any] {
    ["available": true, "engine": engine]
  }

  static func unavailable(_ reason: String) -> [String: Any] {
    ["available": false, "reason": reason]
  }
}

private enum NativeSttText {
  static func merge(_ committed: String, _ next: String) -> String {
    let trimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return committed }
    guard !committed.isEmpty else { return trimmed }
    if committed.hasSuffix(trimmed) { return committed }
    return "\(committed) \(trimmed)".trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

final class NativeSttBridge: NSObject, FlutterStreamHandler {
  static let shared = NativeSttBridge()

  private var methodChannel: FlutterMethodChannel?
  private var eventSink: FlutterEventSink?
  private var session: NativeSttSession?

  private override init() {
    super.init()
  }

  func configure(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: nativeSttMethodChannelName,
      binaryMessenger: messenger
    )
    self.methodChannel = methodChannel
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }

    FlutterEventChannel(
      name: nativeSttEventChannelName,
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
    let arguments = call.arguments as? [String: Any]
    let localeId = arguments?["localeId"] as? String
    let deviceLocaleId = arguments?["deviceLocaleId"] as? String
    let preserveAudioSession = arguments?["preserveAudioSession"] as? Bool ?? false
    let emitPartialResults = arguments?["emitPartialResults"] as? Bool ?? true
    let accumulateResults = arguments?["accumulateResults"] as? Bool ?? true

    switch call.method {
    case "checkAvailability":
      Task {
        let availability = await checkAvailability(localeId: localeId)
        await MainActor.run { result(availability) }
      }
    case "getLocales":
      result(localesPayload(deviceLocaleId: deviceLocaleId ?? localeId))
    case "start":
      Task {
        let availability = await start(
          localeId: localeId,
          preserveAudioSession: preserveAudioSession,
          emitPartialResults: emitPartialResults,
          accumulateResults: accumulateResults
        )
        await MainActor.run { result(availability) }
      }
    case "stop":
      Task {
        await stopCurrentSession()
        await MainActor.run { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func checkAvailability(localeId: String?) async -> [String: Any] {
    if #available(iOS 26.0, *) {
      if await SpeechAnalyzerSttSession.isAvailable(localeId: localeId) {
        return NativeSttAvailability.available("speechAnalyzer")
      }
    }

    if sfSpeechRecognizer(localeId: localeId)?.supportsOnDeviceRecognition == true {
      return NativeSttAvailability.available("sfSpeech")
    }

    return NativeSttAvailability.unavailable(
      "No on-device iOS speech recognizer is available for this locale"
    )
  }

  private func start(
    localeId: String?,
    preserveAudioSession: Bool,
    emitPartialResults: Bool,
    accumulateResults: Bool
  ) async -> [String: Any] {
    await stopCurrentSession()

    if #available(iOS 26.0, *) {
      do {
        let speechAnalyzerSession = try await SpeechAnalyzerSttSession(
          localeId: localeId,
          preserveAudioSession: preserveAudioSession,
          emitPartialResults: emitPartialResults,
          accumulateResults: accumulateResults,
          emit: emit
        )
        session = speechAnalyzerSession
        try await speechAnalyzerSession.start()
        return NativeSttAvailability.available("speechAnalyzer")
      } catch {
        await stopCurrentSession()
        emitError(
          code: "SPEECH_ANALYZER_START_FAILED",
          message: error.localizedDescription,
          engine: "speechAnalyzer"
        )
      }
    }

    do {
      let fallbackSession = try SFSpeechNativeSttSession(
        localeId: localeId,
        preserveAudioSession: preserveAudioSession,
        emitPartialResults: emitPartialResults,
        accumulateResults: accumulateResults,
        emit: emit,
        onFinished: { [weak self] in
          Task { await self?.stopCurrentSession() }
        }
      )
      session = fallbackSession
      try await fallbackSession.start()
      return NativeSttAvailability.available("sfSpeech")
    } catch {
      await stopCurrentSession()
      return NativeSttAvailability.unavailable(error.localizedDescription)
    }
  }

  private func stopCurrentSession() async {
    let current = session
    session = nil
    await current?.stop()
  }

  private func sfSpeechRecognizer(localeId: String?) -> SFSpeechRecognizer? {
    let locale = locale(from: localeId)
    return SFSpeechRecognizer(locale: locale)
  }

  private func locale(from localeId: String?) -> Locale {
    guard let localeId, !localeId.isEmpty else {
      return Locale.current
    }
    return Locale(identifier: localeId.replacingOccurrences(of: "-", with: "_"))
  }

  private func localesPayload(deviceLocaleId: String?) -> [String: Any] {
    let systemLocale = locale(from: deviceLocaleId)
    var locales = Array(SFSpeechRecognizer.supportedLocales()).filter { locale in
      SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }
    if !locales.contains(where: { $0.identifier == systemLocale.identifier }),
       SFSpeechRecognizer(locale: systemLocale)?.supportsOnDeviceRecognition == true {
      locales.append(systemLocale)
    }
    locales.sort { localeIdentifier($0) < localeIdentifier($1) }

    return [
      "systemLocale": localeIdentifier(systemLocale),
      "locales": locales.map(localePayload),
    ]
  }

  private func localePayload(_ locale: Locale) -> [String: Any] {
    let identifier = localeIdentifier(locale)
    let displayName = Locale.current.localizedString(forIdentifier: locale.identifier) ??
      locale.localizedString(forIdentifier: locale.identifier) ??
      identifier
    return [
      "localeId": identifier,
      "name": displayName,
    ]
  }

  private func localeIdentifier(_ locale: Locale) -> String {
    locale.identifier.replacingOccurrences(of: "_", with: "-")
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(event)
    }
  }

  private func emitError(code: String, message: String, engine: String) {
    emit([
      "type": "error",
      "code": code,
      "message": message,
      "engine": engine,
    ])
  }
}

@available(iOS 26.0, *)
private final class SpeechAnalyzerSttSession: NativeSttSession {
  private let localeId: String?
  private let preserveAudioSession: Bool
  private let emitPartialResults: Bool
  private let accumulateResults: Bool
  private let emit: ([String: Any]) -> Void
  private let audioEngine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var resultTask: Task<Void, Never>?
  private var analyzerTask: Task<Void, Never>?
  private var stopped = false
  private var tapInstalled = false

  init(
    localeId: String?,
    preserveAudioSession: Bool,
    emitPartialResults: Bool,
    accumulateResults: Bool,
    emit: @escaping ([String: Any]) -> Void
  ) async throws {
    self.localeId = localeId
    self.preserveAudioSession = preserveAudioSession
    self.emitPartialResults = emitPartialResults
    self.accumulateResults = accumulateResults
    self.emit = emit
  }

  static func isAvailable(localeId: String?) async -> Bool {
    guard let supportedLocale = await supportedLocale(localeId: localeId) else {
      return false
    }
    let transcriber = makeTranscriber(locale: supportedLocale)
    return await AssetInventory.status(forModules: [transcriber]) != .unsupported
  }

  func start() async throws {
    let requestedLocale = try await Self.requiredSupportedLocale(localeId: localeId)
    let transcriber = Self.makeTranscriber(locale: requestedLocale)
    let modules: [any SpeechModule] = [transcriber]

    if let installationRequest = try await AssetInventory.assetInstallationRequest(
      supporting: modules
    ) {
      emit(["type": "status", "message": "downloading", "engine": "speechAnalyzer"])
      try await installationRequest.downloadAndInstall()
    }

    let analyzer = SpeechAnalyzer(
      modules: modules,
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
    )
    self.analyzer = analyzer

    guard await Self.requestSpeechAuthorization() else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted"]
      )
    }
    try await Self.requestMicrophonePermission()
    try configureAudioSession()
    let inputNode = audioEngine.inputNode
    Self.enableVoiceProcessingIfAvailable(inputNode, preserveAudioSession: preserveAudioSession)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    try Self.validateInputFormat(inputFormat)
    let analyzerFormat = try await Self.analyzerFormat(
      compatibleWith: modules,
      naturalFormat: inputFormat
    )
    let converter = try Self.makeConverter(from: inputFormat, to: analyzerFormat)
    try await analyzer.prepareToAnalyze(in: analyzerFormat)

    let inputStream = AsyncStream<AnalyzerInput> { continuation in
      self.inputContinuation = continuation
    }

    var committedText = ""
    resultTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in transcriber.results {
          let text = String(result.text.characters)
          if result.isFinal {
            let emittedText: String
            if self.accumulateResults {
              committedText = NativeSttText.merge(committedText, text)
              emittedText = committedText
            } else {
              emittedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            self.emitResult(emittedText, isFinal: true)
          } else if self.emitPartialResults {
            let emittedText = self.accumulateResults
              ? NativeSttText.merge(committedText, text)
              : text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.emitResult(emittedText, isFinal: false)
          }
        }
        self.emitDone()
      } catch is CancellationError {
      } catch {
        self.emitError(code: "SPEECH_ANALYZER_ERROR", message: error.localizedDescription)
      }
    }

    analyzerTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await analyzer.start(inputSequence: inputStream)
      } catch is CancellationError {
      } catch {
        self.emitError(code: "SPEECH_ANALYZER_ERROR", message: error.localizedDescription)
      }
    }

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
      guard let self,
            let analyzerBuffer = Self.copyOrConvert(
              buffer: buffer,
              targetFormat: analyzerFormat,
              converter: converter
            )
      else {
        return
      }
      self.inputContinuation?.yield(AnalyzerInput(buffer: analyzerBuffer))
    }
    tapInstalled = true

    do {
      audioEngine.prepare()
      try audioEngine.start()
      emit(["type": "status", "message": "listening", "engine": "speechAnalyzer"])
    } catch {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
      throw error
    }
  }

  func stop() async {
    guard !stopped else { return }
    stopped = true
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    inputContinuation?.finish()
    inputContinuation = nil
    analyzerTask?.cancel()
    resultTask?.cancel()
    await analyzer?.cancelAndFinishNow()
    analyzer = nil
    if !preserveAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private static func supportedLocale(localeId: String?) async -> Locale? {
    let locale = localeId
      .map { Locale(identifier: $0.replacingOccurrences(of: "-", with: "_")) } ?? Locale.current
    return await DictationTranscriber.supportedLocale(equivalentTo: locale)
  }

  private static func requiredSupportedLocale(localeId: String?) async throws -> Locale {
    if let locale = await supportedLocale(localeId: localeId) {
      return locale
    }
    throw NSError(
      domain: "NativeSttBridge",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "SpeechAnalyzer does not support this locale"]
    )
  }

  private static func makeTranscriber(locale: Locale) -> DictationTranscriber {
    var preset = DictationTranscriber.Preset.progressiveLongDictation
    preset.reportingOptions.insert(.volatileResults)
    preset.reportingOptions.insert(.frequentFinalization)
    preset.transcriptionOptions.insert(.punctuation)
    return DictationTranscriber(locale: locale, preset: preset)
  }

  private func configureAudioSession() throws {
    guard !preserveAudioSession else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetooth, .defaultToSpeaker]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private static func enableVoiceProcessingIfAvailable(
    _ inputNode: AVAudioInputNode,
    preserveAudioSession: Bool
  ) {
    guard preserveAudioSession else { return }
    if #available(iOS 13.0, *) {
      try? inputNode.setVoiceProcessingEnabled(true)
    }
  }

  private static func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  private static func requestMicrophonePermission() async throws {
    let granted = await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    guard granted else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Microphone permission was not granted"]
      )
    }
  }

  private static func analyzerFormat(
    compatibleWith modules: [any SpeechModule],
    naturalFormat: AVAudioFormat
  ) async throws -> AVAudioFormat {
    if let format = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: modules,
      considering: naturalFormat
    ) {
      return format
    }
    if let format = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: modules
    ) {
      return format
    }
    throw NSError(
      domain: "NativeSttBridge",
      code: 9,
      userInfo: [NSLocalizedDescriptionKey: "SpeechAnalyzer has no compatible audio format"]
    )
  }

  private static func validateInputFormat(_ format: AVAudioFormat) throws {
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 6,
        userInfo: [NSLocalizedDescriptionKey: "Microphone input format is unavailable"]
      )
    }
  }

  private static func makeConverter(
    from inputFormat: AVAudioFormat,
    to outputFormat: AVAudioFormat
  ) throws -> AVAudioConverter? {
    guard !formatsMatch(inputFormat, outputFormat) else {
      return nil
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 10,
        userInfo: [NSLocalizedDescriptionKey: "Unable to convert microphone audio for SpeechAnalyzer"]
      )
    }
    return converter
  }

  private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.sampleRate == rhs.sampleRate &&
      lhs.channelCount == rhs.channelCount &&
      lhs.commonFormat == rhs.commonFormat &&
      lhs.isInterleaved == rhs.isInterleaved
  }

  private func emitResult(_ text: String, isFinal: Bool) {
    emit([
      "type": "result",
      "text": text,
      "final": isFinal,
      "engine": "speechAnalyzer",
    ])
  }

  private func emitError(code: String, message: String) {
    emit([
      "type": "error",
      "code": code,
      "message": message,
      "engine": "speechAnalyzer",
    ])
  }

  private func emitDone() {
    emit(["type": "done", "engine": "speechAnalyzer"])
  }

  private static func copyOrConvert(
    buffer: AVAudioPCMBuffer,
    targetFormat: AVAudioFormat,
    converter: AVAudioConverter?
  ) -> AVAudioPCMBuffer? {
    guard let converter else {
      return copy(buffer: buffer)
    }
    return convert(buffer: buffer, to: targetFormat, using: converter)
  }

  private static func convert(
    buffer: AVAudioPCMBuffer,
    to outputFormat: AVAudioFormat,
    using converter: AVAudioConverter
  ) -> AVAudioPCMBuffer? {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let frameCapacity = max(
      AVAudioFrameCount(1),
      AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
    )
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: outputFormat,
      frameCapacity: frameCapacity
    ) else {
      return nil
    }

    var didProvideInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
      if didProvideInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      didProvideInput = true
      outStatus.pointee = .haveData
      return buffer
    }

    guard status != .error, outputBuffer.frameLength > 0 else {
      return nil
    }
    return outputBuffer
  }

  private static func copy(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(
      pcmFormat: buffer.format,
      frameCapacity: buffer.frameLength
    ) else {
      return nil
    }
    copy.frameLength = buffer.frameLength

    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)
    if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
      for channel in 0..<channelCount {
        memcpy(destination[channel], source[channel], frameLength * MemoryLayout<Float>.size)
      }
    } else if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
      for channel in 0..<channelCount {
        memcpy(destination[channel], source[channel], frameLength * MemoryLayout<Int16>.size)
      }
    } else if let source = buffer.int32ChannelData, let destination = copy.int32ChannelData {
      for channel in 0..<channelCount {
        memcpy(destination[channel], source[channel], frameLength * MemoryLayout<Int32>.size)
      }
    }

    return copy
  }
}

private final class SFSpeechNativeSttSession: NativeSttSession {
  private static let segmentFinalizationDelay: TimeInterval = 1.2

  private let localeId: String?
  private let preserveAudioSession: Bool
  private let emitPartialResults: Bool
  private let accumulateResults: Bool
  private let emit: ([String: Any]) -> Void
  private let onFinished: () -> Void
  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var finalizationWorkItem: DispatchWorkItem?
  private var committedFormattedText = ""
  private var pendingFinalText = ""
  private var pendingFormattedText = ""
  private var stopped = false
  private var tapInstalled = false

  init(
    localeId: String?,
    preserveAudioSession: Bool,
    emitPartialResults: Bool,
    accumulateResults: Bool,
    emit: @escaping ([String: Any]) -> Void,
    onFinished: @escaping () -> Void
  ) throws {
    self.localeId = localeId
    self.preserveAudioSession = preserveAudioSession
    self.emitPartialResults = emitPartialResults
    self.accumulateResults = accumulateResults
    self.emit = emit
    self.onFinished = onFinished
  }

  func start() async throws {
    guard await requestSpeechAuthorization() else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted"]
      )
    }

    let recognizer = try makeRecognizer()
    try await Self.requestMicrophonePermission()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = emitPartialResults
    request.requiresOnDeviceRecognition = true
    if #available(iOS 16.0, *) {
      request.addsPunctuation = true
    }
    recognitionRequest = request

    try configureAudioSession()
    let inputNode = audioEngine.inputNode
    Self.enableVoiceProcessingIfAvailable(inputNode, preserveAudioSession: preserveAudioSession)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    try Self.validateInputFormat(inputFormat)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
      request.append(buffer)
    }
    tapInstalled = true

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      guard !self.stopped else { return }
      if let result {
        self.handleRecognitionResult(result)
      }

      if let error {
        self.cancelSegmentFinalization()
        self.emit([
          "type": "error",
          "code": "SFSPEECH_ERROR",
          "message": error.localizedDescription,
          "engine": "sfSpeech",
        ])
        self.emit(["type": "done", "engine": "sfSpeech"])
        self.onFinished()
      }
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
      emit(["type": "status", "message": "listening", "engine": "sfSpeech"])
    } catch {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
      throw error
    }
  }

  func stop() async {
    guard !stopped else { return }
    stopped = true
    cancelSegmentFinalization()
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    if !preserveAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func handleRecognitionResult(_ result: SFSpeechRecognitionResult) {
    let transcription = result.bestTranscription
    let formattedText = transcription.formattedString.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let segmentText = uncommittedText(from: formattedText)
    guard !segmentText.isEmpty else { return }

    let emittedText = accumulateResults
      ? formattedText
      : segmentText
    guard !emittedText.isEmpty else { return }

    pendingFinalText = emittedText
    pendingFormattedText = formattedText

    if result.isFinal {
      cancelSegmentFinalization()
      emitResult(emittedText, isFinal: true)
      commitPendingSegment()
      emit(["type": "done", "engine": "sfSpeech"])
      onFinished()
      return
    }

    if emitPartialResults {
      emitResult(emittedText, isFinal: false)
    }
    scheduleSegmentFinalization()
  }

  private func scheduleSegmentFinalization() {
    cancelSegmentFinalization()
    let workItem = DispatchWorkItem { [weak self] in
      self?.finalizePendingSegment()
    }
    finalizationWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.segmentFinalizationDelay,
      execute: workItem
    )
  }

  private func cancelSegmentFinalization() {
    finalizationWorkItem?.cancel()
    finalizationWorkItem = nil
  }

  private func finalizePendingSegment() {
    guard !stopped else { return }
    let text = pendingFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    emitResult(text, isFinal: true)
    commitPendingSegment()
  }

  private func commitPendingSegment() {
    if !pendingFormattedText.isEmpty {
      committedFormattedText = pendingFormattedText
    }
    pendingFinalText = ""
    pendingFormattedText = ""
    finalizationWorkItem = nil
  }

  private func emitResult(_ text: String, isFinal: Bool) {
    emit([
      "type": "result",
      "text": text,
      "final": isFinal,
      "engine": "sfSpeech",
    ])
  }

  private func uncommittedText(from formatted: String) -> String {
    guard !formatted.isEmpty else { return "" }
    guard !committedFormattedText.isEmpty else { return formatted }
    if formatted == committedFormattedText {
      return ""
    }

    let prefixRange = formatted.range(
      of: committedFormattedText,
      options: [.anchored, .caseInsensitive]
    )
    guard let prefixRange else {
      // SFSpeech can reset its formatted string between utterances. Treat a
      // non-prefixed result as a fresh turn instead of blocking future finals.
      return formatted
    }

    return String(formatted[prefixRange.upperBound...])
      .trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
      )
  }

  private func makeRecognizer() throws -> SFSpeechRecognizer {
    let locale = localeId
      .map { Locale(identifier: $0.replacingOccurrences(of: "-", with: "_")) } ?? Locale.current
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "SFSpeechRecognizer is unavailable"]
      )
    }
    guard recognizer.supportsOnDeviceRecognition else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "SFSpeechRecognizer does not support on-device recognition for this locale"]
      )
    }
    return recognizer
  }

  private func configureAudioSession() throws {
    guard !preserveAudioSession else { return }
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .measurement,
      options: [.allowBluetooth, .defaultToSpeaker]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private static func enableVoiceProcessingIfAvailable(
    _ inputNode: AVAudioInputNode,
    preserveAudioSession: Bool
  ) {
    guard preserveAudioSession else { return }
    if #available(iOS 13.0, *) {
      try? inputNode.setVoiceProcessingEnabled(true)
    }
  }

  private func requestSpeechAuthorization() async -> Bool {
    await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
  }

  private static func requestMicrophonePermission() async throws {
    let granted = await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    guard granted else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 7,
        userInfo: [NSLocalizedDescriptionKey: "Microphone permission was not granted"]
      )
    }
  }

  private static func validateInputFormat(_ format: AVAudioFormat) throws {
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Microphone input format is unavailable"]
      )
    }
  }
}
