import AVFoundation
import Flutter
import Speech
import UIKit

private let nativeSttMethodChannelName = "app.cogwheel.conduit/native_stt"
private let nativeSttEventChannelName = "app.cogwheel.conduit/native_stt/events"

protocol NativeSttSession: AnyObject {
  func stop() async
}

/// A one-shot completion shared by every caller joining an in-progress stop.
/// `stopped` closes audio admission, while this latch marks the later point at
/// which queued conversion, analyzer teardown, and audio-session release have
/// all finished.
final class NativeSttShutdownCompletion {
  private let lock = NSLock()
  private var completed = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  func wait() async {
    if Task.isCancelled { return }
    let waiterId = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        lock.lock()
        if completed || Task.isCancelled {
          lock.unlock()
          continuation.resume()
          return
        }
        waiters[waiterId] = continuation
        lock.unlock()
      }
    } onCancel: {
      self.resolveWaiter(waiterId)
    }
  }

  func wait(timeoutNanoseconds: UInt64) async -> Bool {
    if isCompleted { return true }
    guard timeoutNanoseconds > 0 else { return false }
    return await withTaskGroup(of: Bool.self) { group in
      group.addTask { [weak self] in
        guard let self else { return true }
        await self.wait()
        return self.isCompleted
      }
      group.addTask {
        do {
          try await Task.sleep(nanoseconds: timeoutNanoseconds)
        } catch {
          return false
        }
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  var isCompleted: Bool {
    lock.lock()
    let value = completed
    lock.unlock()
    return value
  }

  func complete() {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    let pendingWaiters = Array(waiters.values)
    waiters.removeAll(keepingCapacity: false)
    lock.unlock()
    pendingWaiters.forEach { $0.resume() }
  }

  private func resolveWaiter(_ waiterId: UUID) {
    lock.lock()
    let waiter = waiters.removeValue(forKey: waiterId)
    lock.unlock()
    waiter?.resume()
  }
}

/// Waits for an existing teardown task without cancelling that teardown when
/// the caller's acknowledgement deadline expires.
func waitForNativeSttTask(
  _ task: Task<Void, Never>,
  timeoutNanoseconds: UInt64
) async -> Bool {
  let completion = NativeSttShutdownCompletion()
  Task {
    await task.value
    completion.complete()
  }
  return await completion.wait(timeoutNanoseconds: timeoutNanoseconds)
}

struct NativeSttLifecycleTransition {
  let generation: Int
  let shutdownTask: Task<Void, Never>
}

/// Lock-backed outer lifecycle registry. Every transition atomically retires
/// the visible session and chains its full teardown after any predecessor.
/// Stop may acknowledge on a deadline, but a later start always awaits this
/// full chain before publishing new audio resources.
final class NativeSttLifecycleState {
  private let lock = NSLock()
  private var generation = 0
  private var session: NativeSttSession?
  private var pendingShutdown: Task<Void, Never>?

  func beginStart() -> NativeSttLifecycleTransition {
    beginTransition(invalidateGeneration: true)
  }

  func beginStop(
    invalidateGeneration: Bool = true
  ) -> NativeSttLifecycleTransition {
    beginTransition(invalidateGeneration: invalidateGeneration)
  }

  func install(_ candidate: NativeSttSession, generation: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard self.generation == generation, session == nil else { return false }
    session = candidate
    return true
  }

  func isCurrent(_ generation: Int) -> Bool {
    lock.lock()
    let result = self.generation == generation
    lock.unlock()
    return result
  }

  func isInstalled(_ candidate: NativeSttSession, generation: Int) -> Bool {
    lock.lock()
    let result = self.generation == generation && session === candidate
    lock.unlock()
    return result
  }

  /// Retires a failed current candidate without invalidating the start token.
  func retireIfCurrent(
    _ candidate: NativeSttSession,
    generation: Int
  ) -> Task<Void, Never> {
    lock.lock()
    if self.generation == generation, session === candidate {
      session = nil
      let task = enqueueShutdownLocked(candidate)
      lock.unlock()
      return task
    }
    let existing = pendingShutdown ?? Task {}
    lock.unlock()
    return existing
  }

  /// Atomically ends a naturally finished session and invalidates every
  /// callback guard from that start before asynchronous teardown begins.
  func finishIfCurrent(
    _ candidate: NativeSttSession,
    generation: Int
  ) -> Task<Void, Never> {
    lock.lock()
    if self.generation == generation, session === candidate {
      self.generation &+= 1
      session = nil
      let task = enqueueShutdownLocked(candidate)
      lock.unlock()
      return task
    }
    let existing = pendingShutdown ?? Task {}
    lock.unlock()
    return existing
  }

  private func beginTransition(
    invalidateGeneration: Bool
  ) -> NativeSttLifecycleTransition {
    lock.lock()
    if invalidateGeneration {
      generation &+= 1
    }
    let token = generation
    let retiring = session
    session = nil
    let task = enqueueShutdownLocked(retiring)
    lock.unlock()
    return NativeSttLifecycleTransition(
      generation: token,
      shutdownTask: task
    )
  }

  private func enqueueShutdownLocked(
    _ retiring: NativeSttSession?
  ) -> Task<Void, Never> {
    let predecessor = pendingShutdown
    let task = Task {
      await predecessor?.value
      await retiring?.stop()
    }
    pendingShutdown = task
    return task
  }
}

struct NativeSttEventDeliveryToken: Equatable {
  let lifecycleGeneration: Int
  let subscriptionGeneration: Int
  let activationGeneration: Int
}

/// Binds queued Flutter events to both the STT start that produced them and
/// the exact EventChannel subscription that was listening at that time.
final class NativeSttEventDeliveryGate {
  private let lock = NSLock()
  private var subscriptionGeneration = 0
  private var activationGeneration = 0
  private var activeToken: NativeSttEventDeliveryToken?
  private var terminalReservedToken: NativeSttEventDeliveryToken?
  private var eventSink: FlutterEventSink?

  func listen(_ sink: @escaping FlutterEventSink) {
    lock.lock()
    subscriptionGeneration &+= 1
    activeToken = nil
    terminalReservedToken = nil
    eventSink = sink
    lock.unlock()
  }

  func cancelSubscription() {
    lock.lock()
    subscriptionGeneration &+= 1
    activeToken = nil
    terminalReservedToken = nil
    eventSink = nil
    lock.unlock()
  }

  func activate(lifecycleGeneration: Int) -> NativeSttEventDeliveryToken {
    lock.lock()
    activationGeneration &+= 1
    let token = NativeSttEventDeliveryToken(
      lifecycleGeneration: lifecycleGeneration,
      subscriptionGeneration: subscriptionGeneration,
      activationGeneration: activationGeneration
    )
    activeToken = token
    terminalReservedToken = nil
    lock.unlock()
    return token
  }

  func deactivate() {
    lock.lock()
    activeToken = nil
    terminalReservedToken = nil
    lock.unlock()
  }

  /// Deactivates only the producer that still owns delivery admission. A
  /// delayed failure from an older start must not silence its replacement.
  @discardableResult
  func deactivate(_ token: NativeSttEventDeliveryToken) -> Bool {
    lock.lock()
    guard activeToken == token else {
      lock.unlock()
      return false
    }
    activeToken = nil
    terminalReservedToken = nil
    lock.unlock()
    return true
  }

  /// Reserves delivery order under the same lock that closes terminal
  /// admission. Dispatching to main while holding this lock means every event
  /// admitted before `done` is queued before it, while any producer racing
  /// after `done` is rejected rather than appearing after the terminal event.
  @discardableResult
  func enqueue(
    _ event: [String: Any],
    token: NativeSttEventDeliveryToken,
    isTerminal: Bool
  ) -> Bool {
    lock.lock()
    guard activeToken == token,
          terminalReservedToken == nil else {
      lock.unlock()
      return false
    }
    if isTerminal {
      terminalReservedToken = token
    }
    guard eventSink != nil else {
      if isTerminal {
        activeToken = nil
        terminalReservedToken = nil
      }
      lock.unlock()
      return false
    }
    DispatchQueue.main.async { [weak self] in
      self?.deliverQueued(event, token: token, isTerminal: isTerminal)
    }
    lock.unlock()
    return true
  }

  @discardableResult
  func deliver(
    _ event: [String: Any],
    token: NativeSttEventDeliveryToken
  ) -> Bool {
    lock.lock()
    guard activeToken == token,
          terminalReservedToken == nil,
          let sink = eventSink else {
      lock.unlock()
      return false
    }
    lock.unlock()
    sink(event)
    return true
  }

  private func deliverQueued(
    _ event: [String: Any],
    token: NativeSttEventDeliveryToken,
    isTerminal: Bool
  ) {
    lock.lock()
    guard activeToken == token,
          token.subscriptionGeneration == subscriptionGeneration,
          (!isTerminal || terminalReservedToken == token),
          let sink = eventSink else {
      lock.unlock()
      return
    }
    if isTerminal {
      // Natural completion consumes the token at the terminal delivery
      // boundary. Previously queued events still precede this block on main;
      // no later producer can be admitted after the reservation above.
      activeToken = nil
      terminalReservedToken = nil
    }
    lock.unlock()
    sink(event)
  }
}

/// Prevents teardown from touching AVAudioEngine while prepare/start is in
/// progress, without holding a mutex on the real-time audio callback path.
final class NativeSttResourceMutationGate {
  private let lock = NSLock()
  private var closed = false
  private var activeMutations = 0
  private let drained = NativeSttShutdownCompletion()

  func begin() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return false }
    activeMutations += 1
    return true
  }

  func end() {
    lock.lock()
    precondition(activeMutations > 0)
    activeMutations -= 1
    let didDrain = closed && activeMutations == 0
    lock.unlock()
    if didDrain { drained.complete() }
  }

  func close() {
    lock.lock()
    closed = true
    let didDrain = activeMutations == 0
    lock.unlock()
    if didDrain { drained.complete() }
  }

  func waitUntilDrained() async {
    close()
    await drained.wait()
  }
}

/// Closes an individual SFSpeech request to new audio and synchronously drains
/// appends that were admitted before request teardown or segment restart.
final class NativeSttAudioAppendGate {
  private let condition = NSCondition()
  private var closed = false
  private var activeAppends = 0

  func begin() -> Bool {
    condition.lock()
    guard !closed else {
      condition.unlock()
      return false
    }
    activeAppends += 1
    condition.unlock()
    return true
  }

  func end() {
    condition.lock()
    precondition(activeAppends > 0)
    activeAppends -= 1
    if closed && activeAppends == 0 {
      condition.broadcast()
    }
    condition.unlock()
  }

  func closeAndWait() {
    condition.lock()
    closed = true
    while activeAppends > 0 {
      condition.wait()
    }
    condition.unlock()
  }
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
    if committed == trimmed || committed.hasSuffix(trimmed) { return committed }
    if trimmed.hasPrefix(committed) { return trimmed }
    return "\(committed) \(trimmed)".trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Copies only initialized linear-PCM frames from an engine-owned tap buffer.
/// AudioBufferList byte sizes preserve interleaved channel stride, unlike the
/// planar channel-pointer APIs which are not valid for every PCM layout.
func copyNativeSttPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
  let format = buffer.format
  guard let copy = AVAudioPCMBuffer(
    pcmFormat: format,
    frameCapacity: buffer.frameLength
  ), copyNativeSttPCMBuffer(buffer, into: copy) else { return nil }
  return copy
}

@discardableResult
func copyNativeSttPCMBuffer(
  _ sourceBuffer: AVAudioPCMBuffer,
  into destinationBuffer: AVAudioPCMBuffer
) -> Bool {
  let format = sourceBuffer.format
  let description = format.streamDescription.pointee
  let destinationFormat = destinationBuffer.format
  guard description.mFormatID == kAudioFormatLinearPCM,
        sourceBuffer.frameLength > 0,
        sourceBuffer.frameLength <= sourceBuffer.frameCapacity,
        sourceBuffer.frameLength <= destinationBuffer.frameCapacity,
        format.channelCount > 0,
        description.mBytesPerFrame > 0,
        format.channelCount == destinationFormat.channelCount,
        format.commonFormat == destinationFormat.commonFormat,
        format.isInterleaved == destinationFormat.isInterleaved,
        format.sampleRate == destinationFormat.sampleRate else {
    return false
  }
  switch format.commonFormat {
  case .pcmFormatFloat32, .pcmFormatInt16, .pcmFormatInt32:
    break
  default:
    return false
  }

  let frameLength = Int(sourceBuffer.frameLength)
  let bytesPerFrame = Int(description.mBytesPerFrame)
  guard frameLength <= Int.max / bytesPerFrame else { return false }
  let initializedByteCount = frameLength * bytesPerFrame
  destinationBuffer.frameLength = sourceBuffer.frameLength

  let sourceBuffers = UnsafeMutableAudioBufferListPointer(
    sourceBuffer.mutableAudioBufferList
  )
  let destinationBuffers = UnsafeMutableAudioBufferListPointer(
    destinationBuffer.mutableAudioBufferList
  )
  let expectedBufferCount = format.isInterleaved
    ? 1
    : Int(format.channelCount)
  guard sourceBuffers.count == expectedBufferCount,
        destinationBuffers.count == expectedBufferCount
  else {
    return false
  }

  for index in 0..<expectedBufferCount {
    let source = sourceBuffers[index]
    let destination = destinationBuffers[index]
    guard source.mNumberChannels == destination.mNumberChannels,
          Int(source.mDataByteSize) >= initializedByteCount,
          Int(destination.mDataByteSize) >= initializedByteCount,
          let sourceData = source.mData,
          let destinationData = destination.mData
    else {
      return false
    }
    memcpy(destinationData, sourceData, initializedByteCount)
  }
  return true
}

struct NativeSttPCMBufferLease {
  let buffer: AVAudioPCMBuffer
  fileprivate let pool: NativeSttPCMBufferPool
  fileprivate let index: Int

  fileprivate init(
    buffer: AVAudioPCMBuffer,
    pool: NativeSttPCMBufferPool,
    index: Int
  ) {
    self.buffer = buffer
    self.pool = pool
    self.index = index
  }

  func release() {
    pool.returnBuffer(at: index)
  }
}

/// A fixed-capacity copy pool for AVAudioEngine's real-time tap callback.
/// Acquisition is non-blocking; a saturated pool drops the newest frame.
final class NativeSttPCMBufferPool {
  private let lock = NSLock()
  private let buffers: [AVAudioPCMBuffer]
  private var availableIndices: [Int]

  init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, count: Int) {
    guard frameCapacity > 0, count > 0 else { return nil }
    var allocated: [AVAudioPCMBuffer] = []
    allocated.reserveCapacity(count)
    for _ in 0..<count {
      guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCapacity
      ) else { return nil }
      allocated.append(buffer)
    }
    buffers = allocated
    availableIndices = Array(allocated.indices.reversed())
  }

  func copyFromTap(_ source: AVAudioPCMBuffer) -> NativeSttPCMBufferLease? {
    guard lock.try() else { return nil }
    guard let index = availableIndices.popLast() else {
      lock.unlock()
      return nil
    }
    lock.unlock()

    let destination = buffers[index]
    guard copyNativeSttPCMBuffer(source, into: destination) else {
      returnBuffer(at: index)
      return nil
    }
    return NativeSttPCMBufferLease(
      buffer: destination,
      pool: self,
      index: index
    )
  }

  var availableCount: Int {
    lock.lock()
    let value = availableIndices.count
    lock.unlock()
    return value
  }

  fileprivate func returnBuffer(at index: Int) {
    lock.lock()
    availableIndices.append(index)
    lock.unlock()
  }
}

final class NativeSttBridge: NSObject, FlutterStreamHandler {
  static let shared = NativeSttBridge()
  private static let stopAcknowledgementTimeoutNanoseconds: UInt64 =
    1_000_000_000

  private var methodChannel: FlutterMethodChannel?
  private let lifecycle = NativeSttLifecycleState()
  private let eventDeliveryGate = NativeSttEventDeliveryGate()

  private override init() {
    super.init()
  }

  deinit {
    _ = lifecycle.beginStop()
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
    eventDeliveryGate.listen(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventDeliveryGate.cancelSubscription()
    let transition = lifecycle.beginStop()
    Task {
      await waitForStopTransition(
        transition,
        waitForFullShutdown: false
      )
    }
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    let localeId = arguments?["localeId"] as? String
    let deviceLocaleId = arguments?["deviceLocaleId"] as? String
    let preserveAudioSession = arguments?["preserveAudioSession"] as? Bool ?? false
    let emitPartialResults = arguments?["emitPartialResults"] as? Bool ?? true
    let accumulateResults = arguments?["accumulateResults"] as? Bool ?? true
    let allowOnlineFallback = arguments?["allowOnlineFallback"] as? Bool ?? true

    switch call.method {
    case "checkAvailability":
      Task {
        let availability = await checkAvailability(
          localeId: localeId,
          allowOnlineFallback: allowOnlineFallback
        )
        await MainActor.run { result(availability) }
      }
    case "getLocales":
      result(localesPayload(deviceLocaleId: deviceLocaleId ?? localeId))
    case "start":
      // Invalidate the retiring producer at command-receipt time. The new
      // start may await a long shutdown chain before it can activate its own
      // token, and teardown events from the prior session must not leak into
      // that gap.
      eventDeliveryGate.deactivate()
      let transition = lifecycle.beginStart()
      Task {
        let availability = await start(
          transition: transition,
          localeId: localeId,
          preserveAudioSession: preserveAudioSession,
          emitPartialResults: emitPartialResults,
          accumulateResults: accumulateResults,
          allowOnlineFallback: allowOnlineFallback
        )
        await MainActor.run { result(availability) }
      }
    case "stop":
      eventDeliveryGate.deactivate()
      let transition = lifecycle.beginStop()
      Task {
        await waitForStopTransition(
          transition,
          waitForFullShutdown: false
        )
        await MainActor.run { result(nil) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func checkAvailability(
    localeId: String?,
    allowOnlineFallback: Bool
  ) async -> [String: Any] {
    if #available(iOS 26.0, *) {
      if await SpeechAnalyzerSttSession.isAvailable(localeId: localeId) {
        return NativeSttAvailability.available("speechAnalyzer")
      }
    }

    if let recognizer = sfSpeechRecognizer(localeId: localeId) {
      if allowOnlineFallback, recognizer.isAvailable {
        return NativeSttAvailability.available("sfSpeech")
      }
      if recognizer.supportsOnDeviceRecognition {
        return NativeSttAvailability.available("sfSpeech")
      }
    }

    return NativeSttAvailability.unavailable(
      "No on-device iOS speech recognizer is available for this locale"
    )
  }

  private func start(
    transition: NativeSttLifecycleTransition,
    localeId: String?,
    preserveAudioSession: Bool,
    emitPartialResults: Bool,
    accumulateResults: Bool,
    allowOnlineFallback: Bool
  ) async -> [String: Any] {
    let generation = transition.generation
    await transition.shutdownTask.value
    guard lifecycle.isCurrent(generation) else {
      return NativeSttAvailability.unavailable(
        "Speech recognition start was cancelled"
      )
    }
    let analyzerEventToken = eventDeliveryGate.activate(
      lifecycleGeneration: generation
    )
    let analyzerEmit: ([String: Any]) -> Void = { [weak self] event in
      self?.emit(event, token: analyzerEventToken)
    }
    var speechAnalyzerFailure: Error?

    if #available(iOS 26.0, *) {
      do {
        let speechAnalyzerSession = try await SpeechAnalyzerSttSession(
          localeId: localeId,
          preserveAudioSession: preserveAudioSession,
          emitPartialResults: emitPartialResults,
          accumulateResults: accumulateResults,
          emit: analyzerEmit,
          isCurrent: { [weak self] in
            self?.lifecycle.isCurrent(generation) == true
          },
          onFinished: { [weak self] finishedSession in
            self?.finishCurrentSession(
              finishedSession,
              generation: generation
            )
          }
        )
        guard lifecycle.install(
          speechAnalyzerSession,
          generation: generation
        ) else {
          eventDeliveryGate.deactivate(analyzerEventToken)
          return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
        }
        do {
          try await speechAnalyzerSession.start()
        } catch {
          eventDeliveryGate.deactivate(analyzerEventToken)
          let shutdown = lifecycle.retireIfCurrent(
            speechAnalyzerSession,
            generation: generation
          )
          await shutdown.value
          throw error
        }
        guard lifecycle.isInstalled(
          speechAnalyzerSession,
          generation: generation
        ) else {
          // A newer transition already owns the serialized shutdown chain.
          eventDeliveryGate.deactivate(analyzerEventToken)
          await lifecycle.retireIfCurrent(
            speechAnalyzerSession,
            generation: generation
          ).value
          return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
        }
        return NativeSttAvailability.available("speechAnalyzer")
      } catch is CancellationError {
        eventDeliveryGate.deactivate(analyzerEventToken)
        return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
      } catch {
        eventDeliveryGate.deactivate(analyzerEventToken)
        guard lifecycle.isCurrent(generation) else {
          return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
        }
        speechAnalyzerFailure = error
      }
    }

    guard lifecycle.isCurrent(generation) else {
      return NativeSttAvailability.unavailable(
        "Speech recognition start was cancelled"
      )
    }
    let fallbackEventToken = eventDeliveryGate.activate(
      lifecycleGeneration: generation
    )
    let fallbackEmit: ([String: Any]) -> Void = { [weak self] event in
      self?.emit(event, token: fallbackEventToken)
    }
    do {
      let fallbackSession = try SFSpeechNativeSttSession(
        localeId: localeId,
        preserveAudioSession: preserveAudioSession,
        emitPartialResults: emitPartialResults,
        accumulateResults: accumulateResults,
        allowOnlineFallback: allowOnlineFallback,
        emit: fallbackEmit,
        isCurrent: { [weak self] in
          self?.lifecycle.isCurrent(generation) == true
        },
        onFinished: { [weak self] finishedSession in
          self?.finishCurrentSession(
            finishedSession,
            generation: generation
          )
        }
      )
      guard lifecycle.install(fallbackSession, generation: generation) else {
        eventDeliveryGate.deactivate(fallbackEventToken)
        return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
      }
      do {
        try await fallbackSession.start()
      } catch {
        eventDeliveryGate.deactivate(fallbackEventToken)
        let shutdown = lifecycle.retireIfCurrent(
          fallbackSession,
          generation: generation
        )
        await shutdown.value
        throw error
      }
      guard lifecycle.isInstalled(
        fallbackSession,
        generation: generation
      ) else {
        // A concurrent stop/start already retired this session. Join that
        // serialized teardown instead of invoking stop concurrently.
        eventDeliveryGate.deactivate(fallbackEventToken)
        await lifecycle.retireIfCurrent(
          fallbackSession,
          generation: generation
        ).value
        return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
      }
      return NativeSttAvailability.available("sfSpeech")
    } catch is CancellationError {
      eventDeliveryGate.deactivate(fallbackEventToken)
      return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
    } catch {
      eventDeliveryGate.deactivate(fallbackEventToken)
      guard lifecycle.isCurrent(generation) else {
        return NativeSttAvailability.unavailable("Speech recognition start was cancelled")
      }
      let analyzerMessage = speechAnalyzerFailure.map { "; SpeechAnalyzer: \($0.localizedDescription)" } ?? ""
      return NativeSttAvailability.unavailable("\(error.localizedDescription)\(analyzerMessage)")
    }
  }

  private func waitForStopTransition(
    _ transition: NativeSttLifecycleTransition,
    waitForFullShutdown: Bool
  ) async {
    if waitForFullShutdown {
      await transition.shutdownTask.value
    } else {
      _ = await waitForNativeSttTask(
        transition.shutdownTask,
        timeoutNanoseconds: Self.stopAcknowledgementTimeoutNanoseconds
      )
    }
  }

  private func finishCurrentSession(
    _ session: NativeSttSession,
    generation: Int
  ) {
    let shutdown = lifecycle.finishIfCurrent(
      session,
      generation: generation
    )
    Task {
      _ = await waitForNativeSttTask(
        shutdown,
        timeoutNanoseconds: Self.stopAcknowledgementTimeoutNanoseconds
      )
    }
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

  private func emit(
    _ event: [String: Any],
    token: NativeSttEventDeliveryToken
  ) {
    _ = eventDeliveryGate.enqueue(
      event,
      token: token,
      isTerminal: event["type"] as? String == "done"
    )
  }
}

@available(iOS 26.0, *)
private final class SpeechAnalyzerSttSession: NativeSttSession {
  private let localeId: String?
  private let preserveAudioSession: Bool
  private let emitPartialResults: Bool
  private let accumulateResults: Bool
  private let emit: ([String: Any]) -> Void
  private let isCurrent: () -> Bool
  private let onFinished: (SpeechAnalyzerSttSession) -> Void
  private let audioEngine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var resultTask: Task<Void, Never>?
  private var analyzerTask: Task<Void, Never>?
  private let audioLifecycleLock = NSLock()
  private var stopped = false
  private var acceptsAudioConversions = false
  private var tapInstalled = false
  private let audioConversionQueue = DispatchQueue(
    label: "app.cogwheel.conduit.speech-analyzer-audio",
    qos: .userInteractive
  )
  private let audioConversionQueueKey = DispatchSpecificKey<UInt8>()
  private let engineMutationGate = NativeSttResourceMutationGate()
  private let startupCompletion = NativeSttShutdownCompletion()
  private let shutdownCompletion = NativeSttShutdownCompletion()
  private let finishNotificationLock = NSLock()
  private var didNotifyFinished = false

  init(
    localeId: String?,
    preserveAudioSession: Bool,
    emitPartialResults: Bool,
    accumulateResults: Bool,
    emit: @escaping ([String: Any]) -> Void,
    isCurrent: @escaping () -> Bool,
    onFinished: @escaping (SpeechAnalyzerSttSession) -> Void
  ) async throws {
    self.localeId = localeId
    self.preserveAudioSession = preserveAudioSession
    self.emitPartialResults = emitPartialResults
    self.accumulateResults = accumulateResults
    self.emit = emit
    self.isCurrent = isCurrent
    self.onFinished = onFinished
    audioConversionQueue.setSpecific(
      key: audioConversionQueueKey,
      value: 1
    )
  }

  deinit {
    cleanupForDeinit()
  }

  static func isAvailable(localeId: String?) async -> Bool {
    guard let supportedLocale = await supportedLocale(localeId: localeId) else {
      return false
    }
    let transcriber = makeTranscriber(locale: supportedLocale)
    return await AssetInventory.status(forModules: [transcriber]) != .unsupported
  }

  func start() async throws {
    do {
      try await performStart()
      startupCompletion.complete()
    } catch {
      // Publish the end of startup before joining stop; an external stop may
      // already be waiting to make its final rollback pass.
      startupCompletion.complete()
      await stop()
      throw error
    }
  }

  private func performStart() async throws {
    let requestedLocale = try await Self.requiredSupportedLocale(localeId: localeId)
    try checkActive()
    let transcriber = Self.makeTranscriber(locale: requestedLocale)
    let modules: [any SpeechModule] = [transcriber]

    if let installationRequest = try await AssetInventory.assetInstallationRequest(
      supporting: modules
    ) {
      emit(["type": "status", "message": "downloading", "engine": "speechAnalyzer"])
      try await installationRequest.downloadAndInstall()
      try checkActive()
    }

    let analyzer = SpeechAnalyzer(
      modules: modules,
      options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
    )
    try withActiveResourceMutation {
      self.analyzer = analyzer
    }

    guard await Self.requestSpeechAuthorization() else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 8,
        userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted"]
      )
    }
    try checkActive()
    try await Self.requestMicrophonePermission()
    try checkActive()

    // Hold engine mutation admission before the first input-node access. Voice
    // processing and format discovery can mutate AVAudioEngine internally;
    // stop() must not remove taps or stop the engine concurrently with them.
    guard engineMutationGate.begin() else {
      throw CancellationError()
    }
    defer { engineMutationGate.end() }
    try withActiveResourceMutation {
      try configureAudioSession()
    }
    let inputNode = audioEngine.inputNode
    Self.enableVoiceProcessingIfAvailable(inputNode, preserveAudioSession: preserveAudioSession)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    try Self.validateInputFormat(inputFormat)
    guard let tapBufferPool = NativeSttPCMBufferPool(
      format: inputFormat,
      frameCapacity: 1024,
      count: 4
    ) else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Unable to allocate microphone buffers"]
      )
    }
    let analyzerFormat = try await Self.analyzerFormat(
      compatibleWith: modules,
      naturalFormat: inputFormat
    )
    let converter = try Self.makeConverter(from: inputFormat, to: analyzerFormat)
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    try checkActive()

    let inputStream = AsyncStream<AnalyzerInput>(
      bufferingPolicy: .bufferingNewest(4)
    ) { continuation in
      self.syncOnAudioConversionQueue {
        self.inputContinuation = continuation
      }
    }

    if isStopped {
      await finishAudioInputAfterDraining()
      throw CancellationError()
    }

    var committedText = ""
    let pendingResultTask = Task { [weak self] in
      guard let self else { return }
      do {
        for try await result in transcriber.results {
          guard !self.isStopped, self.isCurrent() else { return }
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
        self.finishIfActive { self.emitDone() }
      } catch is CancellationError {
        self.finishIfActive { self.emitDone() }
      } catch {
        self.finishIfActive {
          self.emitError(
            code: "SPEECH_ANALYZER_ERROR",
            message: error.localizedDescription
          )
          self.emitDone()
        }
      }
    }

    let pendingAnalyzerTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await analyzer.start(inputSequence: inputStream)
        // `start(inputSequence:)` returns once SpeechAnalyzer has accepted the
        // sequence; it is not a terminal recognition signal. The transcriber
        // results task owns natural completion and emits the single `done`
        // event. Retiring here would tear down a successfully started session
        // before its first result arrives.
      } catch is CancellationError {
        self.finishIfActive { self.emitDone() }
      } catch {
        self.finishIfActive {
          self.emitError(
            code: "SPEECH_ANALYZER_ERROR",
            message: error.localizedDescription
          )
          self.emitDone()
        }
      }
    }

    do {
      try withActiveResourceMutation {
        resultTask = pendingResultTask
        analyzerTask = pendingAnalyzerTask
      }
    } catch {
      pendingAnalyzerTask.cancel()
      pendingResultTask.cancel()
      await finishAudioInputAfterDraining()
      throw error
    }

    let didInstallTap = installAudioTapIfActive {
      inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
        guard let self,
              let inputLease = tapBufferPool.copyFromTap(buffer) else { return }
        // AVAudioEngine owns the tap buffer. The render callback only performs
        // a bounded copy into one of four preallocated buffers plus a
        // non-blocking queue admission. Conversion and any durable allocation
        // happen on the serial worker.
        let didEnqueue = self.enqueueAudioConversionIfActive { [weak self] in
          defer { inputLease.release() }
          guard let self else { return }
          guard self.isAcceptingAudioConversions, self.isCurrent() else { return }
          let analyzerBuffer: AVAudioPCMBuffer
          if let converter {
            guard let converted = Self.convert(
              buffer: inputLease.buffer,
              to: analyzerFormat,
              using: converter
            ) else { return }
            analyzerBuffer = converted
          } else {
            // AnalyzerInput retains its AVAudioPCMBuffer. Make the durable
            // buffer on this worker before returning the pool slot.
            guard let copied = copyNativeSttPCMBuffer(inputLease.buffer) else {
              return
            }
            analyzerBuffer = copied
          }
          guard self.isAcceptingAudioConversions else { return }
          self.inputContinuation?.yield(AnalyzerInput(buffer: analyzerBuffer))
        }
        if !didEnqueue {
          inputLease.release()
        }
      }
    }
    guard didInstallTap else {
      await finishAudioInputAfterDraining()
      analyzerTask?.cancel()
      resultTask?.cancel()
      throw CancellationError()
    }

    try checkActive()
    audioEngine.prepare()
    try audioEngine.start()
    try checkActive()
    if !isStopped {
      emit(["type": "status", "message": "listening", "engine": "speechAnalyzer"])
    }
  }

  func stop() async {
    let stopState = beginStopping()
    guard stopState.shouldStop else {
      await shutdownCompletion.wait()
      return
    }
    await engineMutationGate.waitUntilDrained()
    await tearDownResources(hadTap: stopState.hadTap, finalPass: false)
    // Permission, asset, and analyzer APIs are not synchronously cancellable.
    // Wait until their startup continuation exits, then make a second pass so
    // anything created after the first stop pass cannot survive stop().
    await startupCompletion.wait()
    await tearDownResources(
      hadTap: takeInstalledTapForCleanup(),
      finalPass: true
    )
    shutdownCompletion.complete()
  }

  private func tearDownResources(hadTap: Bool, finalPass: Bool) async {
    if hadTap {
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    audioEngine.stop()
    // beginStopping() closes admission under the same lock used when a tap
    // callback enqueues conversion work. The queue barrier therefore runs
    // after every accepted conversion and no later callback can enqueue
    // behind it. Finish the AsyncStream only after that barrier drains.
    await finishAudioInputAfterDraining()
    analyzerTask?.cancel()
    resultTask?.cancel()
    let analyzerToCancel = analyzer
    await analyzerToCancel?.cancelAndFinishNow()
    // Keep the analyzer reachable through the first pass. Startup may still
    // resume an async prepare call with its local reference; the final pass
    // cancels that same object again after startup has definitely exited.
    if finalPass {
      analyzer = nil
    }
    if !preserveAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  private func cleanupForDeinit() {
    engineMutationGate.close()
    let stopState = beginStopping()
    if stopState.hadTap {
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    audioEngine.stop()
    syncOnAudioConversionQueue {
      inputContinuation?.finish()
      inputContinuation = nil
    }
    analyzerTask?.cancel()
    resultTask?.cancel()
    startupCompletion.complete()
    shutdownCompletion.complete()
  }

  private func checkActive() throws {
    if isStopped || !isCurrent() || Task.isCancelled {
      throw CancellationError()
    }
  }

  private var isStopped: Bool {
    audioLifecycleLock.lock()
    let value = stopped
    audioLifecycleLock.unlock()
    return value
  }

  private var isAcceptingAudioConversions: Bool {
    audioLifecycleLock.lock()
    let value = acceptsAudioConversions && !stopped
    audioLifecycleLock.unlock()
    return value
  }

  private func installAudioTapIfActive(_ install: () -> Void) -> Bool {
    audioLifecycleLock.lock()
    defer { audioLifecycleLock.unlock() }
    guard !stopped else { return false }
    install()
    tapInstalled = true
    acceptsAudioConversions = true
    return true
  }

  private func enqueueAudioConversionIfActive(
    _ conversion: @escaping () -> Void
  ) -> Bool {
    // Never block AVAudioEngine's real-time callback behind teardown.
    guard audioLifecycleLock.try() else { return false }
    defer { audioLifecycleLock.unlock() }
    guard acceptsAudioConversions, !stopped else { return false }
    // Enqueue while holding the lifecycle lock. beginStopping() acquires the
    // same lock before it closes admission, so its later queue barrier cannot
    // overtake any conversion that was already accepted here.
    audioConversionQueue.async(execute: conversion)
    return true
  }

  private func beginStopping() -> (shouldStop: Bool, hadTap: Bool) {
    engineMutationGate.close()
    audioLifecycleLock.lock()
    defer { audioLifecycleLock.unlock() }
    guard !stopped else { return (false, false) }
    stopped = true
    acceptsAudioConversions = false
    let hadTap = tapInstalled
    tapInstalled = false
    return (true, hadTap)
  }

  private func takeInstalledTapForCleanup() -> Bool {
    audioLifecycleLock.lock()
    let hadTap = tapInstalled
    tapInstalled = false
    acceptsAudioConversions = false
    audioLifecycleLock.unlock()
    return hadTap
  }

  private func withActiveResourceMutation(_ mutation: () throws -> Void) throws {
    audioLifecycleLock.lock()
    defer { audioLifecycleLock.unlock() }
    guard !stopped, isCurrent(), !Task.isCancelled else {
      throw CancellationError()
    }
    try mutation()
  }

  private func finishAudioInputAfterDraining() async {
    await withCheckedContinuation { continuation in
      let finishWork = DispatchWorkItem { [weak self] in
        self?.inputContinuation?.finish()
        self?.inputContinuation = nil
        continuation.resume()
      }
      audioConversionQueue.async(execute: finishWork)
    }
  }

  private func syncOnAudioConversionQueue(_ work: () -> Void) {
    if DispatchQueue.getSpecific(key: audioConversionQueueKey) == 1 {
      work()
    } else {
      audioConversionQueue.sync(execute: work)
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
      options: [.allowBluetoothHFP, .defaultToSpeaker]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private static func enableVoiceProcessingIfAvailable(
    _ inputNode: AVAudioInputNode,
    preserveAudioSession: Bool
  ) {
    guard preserveAudioSession else { return }
    try? inputNode.setVoiceProcessingEnabled(true)
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

  private func finishIfActive(_ emitTerminalEvent: () -> Void) {
    guard !isStopped, isCurrent() else { return }
    finishNotificationLock.lock()
    guard !didNotifyFinished else {
      finishNotificationLock.unlock()
      return
    }
    didNotifyFinished = true
    finishNotificationLock.unlock()

    // An explicit stop can win after the initial eligibility check. Its
    // lifecycle transition owns teardown and has already deactivated events.
    guard !isStopped, isCurrent() else { return }
    emitTerminalEvent()
    onFinished(self)
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

}

private final class SFSpeechNativeSttSession: NativeSttSession {
  private static let segmentFinalizationDelay: TimeInterval = 1.2

  private let localeId: String?
  private let preserveAudioSession: Bool
  private let emitPartialResults: Bool
  private let accumulateResults: Bool
  private let allowOnlineFallback: Bool
  private let emit: ([String: Any]) -> Void
  private let isCurrent: () -> Bool
  private let onFinished: (SFSpeechNativeSttSession) -> Void
  private let audioEngine = AVAudioEngine()
  private var recognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var finalizationWorkItem: DispatchWorkItem?
  private var committedFormattedText = ""
  private var pendingFinalText = ""
  private var pendingFormattedText = ""
  private var didNotifyFinished = false
  private let lifecycleLock = NSLock()
  private var stopped = false
  private var tapInstalled = false
  private var audioAppendGate: NativeSttAudioAppendGate?
  private let stateQueue = DispatchQueue(
    label: "app.cogwheel.conduit.sf-speech-state",
    qos: .userInitiated
  )
  private let stateQueueKey = DispatchSpecificKey<UInt8>()
  private let engineMutationGate = NativeSttResourceMutationGate()
  private let startupCompletion = NativeSttShutdownCompletion()
  private let shutdownCompletion = NativeSttShutdownCompletion()

  init(
    localeId: String?,
    preserveAudioSession: Bool,
    emitPartialResults: Bool,
    accumulateResults: Bool,
    allowOnlineFallback: Bool,
    emit: @escaping ([String: Any]) -> Void,
    isCurrent: @escaping () -> Bool,
    onFinished: @escaping (SFSpeechNativeSttSession) -> Void
  ) throws {
    self.localeId = localeId
    self.preserveAudioSession = preserveAudioSession
    self.emitPartialResults = emitPartialResults
    self.accumulateResults = accumulateResults
    self.allowOnlineFallback = allowOnlineFallback
    self.emit = emit
    self.isCurrent = isCurrent
    self.onFinished = onFinished
    stateQueue.setSpecific(key: stateQueueKey, value: 1)
  }

  deinit {
    cleanupForDeinit()
  }

  func start() async throws {
    do {
      try await performStart()
      startupCompletion.complete()
    } catch {
      startupCompletion.complete()
      await stop()
      throw error
    }
  }

  private func performStart() async throws {
    guard await requestSpeechAuthorization() else {
      throw NSError(
        domain: "NativeSttBridge",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted"]
      )
    }
    try checkActive()

    let recognizer = try makeRecognizer()
    try withActiveResourceMutation {
      syncOnStateQueue {
        self.recognizer = recognizer
      }
    }
    try await Self.requestMicrophonePermission()
    try checkActive()

    guard engineMutationGate.begin() else { throw CancellationError() }
    defer { engineMutationGate.end() }
    try withActiveResourceMutation {
      try syncOnStateQueue {
        try configureAudioSession()
        try startRecognitionTaskOnStateQueue(recognizer)
        audioEngine.prepare()
        try audioEngine.start()
      }
    }
    try checkActive()
    if !isStopped {
      emit(["type": "status", "message": "listening", "engine": "sfSpeech"])
    }
  }

  func stop() async {
    guard beginStopping() else {
      await shutdownCompletion.wait()
      return
    }
    await engineMutationGate.waitUntilDrained()
    syncOnStateQueue {
      stopRecognitionResources(deactivateAudioSession: !preserveAudioSession)
    }
    await startupCompletion.wait()
    // A permission continuation can resume after the first cleanup. Repeat
    // teardown after startup exits so late recognizer/audio resources cannot
    // outlive the acknowledged stop.
    syncOnStateQueue {
      stopRecognitionResources(deactivateAudioSession: !preserveAudioSession)
    }
    shutdownCompletion.complete()
  }

  private func stopRecognitionResources(deactivateAudioSession: Bool) {
    cancelSegmentFinalization()
    audioAppendGate?.closeAndWait()
    audioAppendGate = nil
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil
    recognizer = nil
    if deactivateAudioSession {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  /// Runs only on `stateQueue`; lifecycle admission is held by the caller.
  private func startRecognitionTaskOnStateQueue(
    _ recognizer: SFSpeechRecognizer
  ) throws {
    cancelSegmentFinalization()
    audioAppendGate?.closeAndWait()
    audioAppendGate = nil
    recognitionTask?.cancel()
    recognitionRequest?.endAudio()
    recognitionTask = nil
    recognitionRequest = nil
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = emitPartialResults
    request.requiresOnDeviceRecognition = !allowOnlineFallback
    if #available(iOS 16.0, *) {
      request.addsPunctuation = true
    }
    recognitionRequest = request
    let appendGate = NativeSttAudioAppendGate()
    audioAppendGate = appendGate

    let inputNode = audioEngine.inputNode
    Self.enableVoiceProcessingIfAvailable(inputNode, preserveAudioSession: preserveAudioSession)
    let inputFormat = inputNode.outputFormat(forBus: 0)
    try Self.validateInputFormat(inputFormat)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
      guard appendGate.begin() else { return }
      defer { appendGate.end() }
      // Admission is the request's ownership boundary. Do not acquire the
      // session lifecycle lock from AVAudioEngine's real-time callback: a
      // segment restart closes this gate while holding that lifecycle lock
      // and must be able to drain every callback already admitted here.
      request.append(buffer)
    }
    tapInstalled = true

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      self.stateQueue.async { [weak self] in
        guard let self,
              !self.isStopped,
              self.isCurrent(),
              self.recognitionRequest === request else { return }
        if let result {
          self.handleRecognitionResult(result)
        }

        if let error {
          self.handleRecognitionError(error)
        }
      }
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
      restartRecognitionAfterFinal()
      return
    }

    if emitPartialResults {
      emitResult(emittedText, isFinal: false)
    }
    scheduleSegmentFinalization()
  }

  private func restartRecognitionAfterFinal() {
    guard !isStopped, isCurrent() else { return }
    stateQueue.async { [weak self] in
      guard let self, !self.isStopped, self.isCurrent() else { return }
      guard self.engineMutationGate.begin() else { return }
      defer { self.engineMutationGate.end() }
      do {
        var recognizer: SFSpeechRecognizer?
        try self.withActiveResourceMutation {
          recognizer = self.recognizer
        }
        guard let recognizer else {
          self.emit(["type": "done", "engine": "sfSpeech"])
          self.notifyFinished()
          return
        }
        var shouldStartEngine = false
        try self.withActiveResourceMutation {
          try self.startRecognitionTaskOnStateQueue(recognizer)
          shouldStartEngine = !self.audioEngine.isRunning
        }
        if shouldStartEngine {
          try self.checkActive()
          self.audioEngine.prepare()
          try self.audioEngine.start()
        }
        try self.checkActive()
        if !self.isStopped {
          self.emit(["type": "status", "message": "listening", "engine": "sfSpeech"])
        }
      } catch is CancellationError {
      } catch {
        self.handleRecognitionError(error)
      }
    }
  }

  private func handleRecognitionError(_ error: Error) {
    guard !isStopped, isCurrent() else { return }
    emit([
      "type": "error",
      "code": "SFSPEECH_ERROR",
      "message": error.localizedDescription,
      "engine": "sfSpeech",
    ])
    emit(["type": "done", "engine": "sfSpeech"])
    notifyFinished()
  }

  private func scheduleSegmentFinalization() {
    cancelSegmentFinalization()
    let workItem = DispatchWorkItem { [weak self] in
      self?.finalizePendingSegment()
    }
    finalizationWorkItem = workItem
    stateQueue.asyncAfter(
      deadline: .now() + Self.segmentFinalizationDelay,
      execute: workItem
    )
  }

  private func cancelSegmentFinalization() {
    finalizationWorkItem?.cancel()
    finalizationWorkItem = nil
  }

  private func finalizePendingSegment() {
    guard !isStopped, isCurrent() else { return }
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

  private func notifyFinished() {
    guard !didNotifyFinished else { return }
    didNotifyFinished = true
    onFinished(self)
  }

  private func cleanupForDeinit() {
    engineMutationGate.close()
    _ = beginStopping()
    syncOnStateQueue {
      stopRecognitionResources(deactivateAudioSession: false)
    }
    startupCompletion.complete()
    shutdownCompletion.complete()
  }

  private func checkActive() throws {
    if isStopped || !isCurrent() || Task.isCancelled {
      throw CancellationError()
    }
  }

  private var isStopped: Bool {
    lifecycleLock.lock()
    let value = stopped
    lifecycleLock.unlock()
    return value
  }

  private func beginStopping() -> Bool {
    engineMutationGate.close()
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard !stopped else { return false }
    stopped = true
    return true
  }

  private func withActiveResourceMutation(_ mutation: () throws -> Void) throws {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard !stopped, isCurrent(), !Task.isCancelled else {
      throw CancellationError()
    }
    try mutation()
  }

  private func syncOnStateQueue<T>(
    _ work: () throws -> T
  ) rethrows -> T {
    if DispatchQueue.getSpecific(key: stateQueueKey) == 1 {
      return try work()
    }
    return try stateQueue.sync(execute: work)
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
    guard allowOnlineFallback || recognizer.supportsOnDeviceRecognition else {
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
      options: [.allowBluetoothHFP, .defaultToSpeaker]
    )
    try session.setActive(true, options: .notifyOthersOnDeactivation)
  }

  private static func enableVoiceProcessingIfAvailable(
    _ inputNode: AVAudioInputNode,
    preserveAudioSession: Bool
  ) {
    guard preserveAudioSession else { return }
    try? inputNode.setVoiceProcessingEnabled(true)
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
