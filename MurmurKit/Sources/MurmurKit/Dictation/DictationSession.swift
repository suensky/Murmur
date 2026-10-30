import Foundation
import Observation

/// The settings a dictation starts with.
public struct DictationConfig: Sendable, Equatable {
  public var engine: Engine
  public var language: String
  public var zoomKeyStored: Bool

  public init(engine: Engine, language: String, zoomKeyStored: Bool) {
    self.engine = engine
    self.language = language
    self.zoomKeyStored = zoomKeyStored
  }
}

/// A dictation's time limits.
public struct DictationLimits: Sendable, Equatable {
  /// A dictation finishes by itself after this long.
  public var maxDuration: Duration
  /// The HUD warns at this point.
  public var warnAt: Duration
  /// How long to wait for the rest of the transcript with nothing arriving.
  public var finishTimeout: Duration

  public init(
    maxDuration: Duration = .seconds(600), warnAt: Duration = .seconds(540), finishTimeout: Duration = .seconds(10)
  ) {
    self.maxDuration = maxDuration
    self.warnAt = warnAt
    self.finishTimeout = finishTimeout
  }
}

/// Whether the Apple engines can run for a language.
public protocol EngineAvailability: Sendable {
  func appleTranscriberAvailable(language: String) async -> Bool
  func applePolisher(language: String) async -> PolisherAvailability
}

/// The Apple engines as the system reports them.
public struct SystemEngineAvailability: EngineAvailability {
  public init() {}

  public func appleTranscriberAvailable(language: String) async -> Bool {
    await AppleSpeech.status(for: language) == .installed
  }

  public func applePolisher(language: String) async -> PolisherAvailability {
    FoundationModelsGenerator().availability(for: language)
  }
}

/// Everything a dictation depends on, so tests can fake each part.
public struct DictationEnvironment: Sendable {
  public var audio: any AudioSource
  public var makeTranscriber: @Sendable (TranscriberKind, TranscriberOptions) -> any Transcriber
  public var makePolisher: @Sendable (PolisherKind) -> (any Polisher)?
  public var availability: any EngineAvailability
  public var store: any DictationStore
  public var delivery: any TextDelivering
  public var clock: any Clock<Duration>
  public var now: @Sendable () -> Date
  public var limits: DictationLimits

  public init(
    audio: any AudioSource,
    makeTranscriber: @escaping @Sendable (TranscriberKind, TranscriberOptions) -> any Transcriber,
    makePolisher: @escaping @Sendable (PolisherKind) -> (any Polisher)?,
    availability: any EngineAvailability,
    store: any DictationStore,
    delivery: any TextDelivering,
    clock: any Clock<Duration> = ContinuousClock(),
    now: @escaping @Sendable () -> Date = Date.init,
    limits: DictationLimits = DictationLimits()
  ) {
    self.audio = audio
    self.makeTranscriber = makeTranscriber
    self.makePolisher = makePolisher
    self.availability = availability
    self.store = store
    self.delivery = delivery
    self.clock = clock
    self.now = now
    self.limits = limits
  }

  /// The real engines: the microphone, Apple and Zoom, Foundation Models.
  public static func live(
    store: any DictationStore, delivery: any TextDelivering, zoomKeys: any ZoomKeyStore
  ) -> DictationEnvironment {
    DictationEnvironment(
      audio: MicrophoneCapture(),
      makeTranscriber: { kind, options in
        switch kind {
        case .apple: AppleTranscriber(language: options.language)
        case .zoom: ZoomTranscriber(apiKey: zoomKeys.read() ?? "", options: options)
        }
      },
      makePolisher: { kind in
        switch kind {
        case .apple: ApplePolisher()
        case .basic: BasicCleanup()
        case .zoom, .none: nil
        }
      },
      availability: SystemEngineAvailability(),
      store: store,
      delivery: delivery)
  }
}

public enum DictationPhase: Sendable, Equatable {
  case starting
  case recording
  case finishing
  case polishing
  case done
}

/// Something the HUD notes while recording.
public enum DictationNotice: Sendable, Equatable {
  /// Zoom failed; the Apple transcriber took over.
  case zoomUnavailable
}

public enum DictationFailure: Error, Sendable, Equatable {
  case microphoneUnavailable
  /// The Apple speech model for the language is not installed, and no Zoom key is stored.
  case speechModelMissing(language: String)
  /// The transcript was empty.
  case nothingHeard
  /// The transcriber failed with no text and nothing to fall back to.
  case couldntTranscribe
}

public enum DictationOutcome: Sendable, Equatable {
  /// The text was delivered; `saved` is false when the history write failed.
  case delivered(Dictation, saved: Bool)
  case cancelled
  case failed(DictationFailure)
}

/// One dictation, from the first key-down to the inserted text:
/// starting → recording → finishing → polishing → done.
///
/// `run` drives it and returns the outcome; `finish` and `cancel` end the
/// recording. The HUD observes the published state.
@MainActor
@Observable
public final class DictationSession {
  public private(set) var phase = DictationPhase.starting
  /// Finished segments so far.
  public private(set) var finals: [String] = []
  /// The segment in progress.
  public private(set) var draft = ""
  public private(set) var level: Float = 0
  /// Audio recorded so far.
  public private(set) var recorded = Duration.zero
  /// Set at the warning point before the cap.
  public private(set) var nearingLimit = false
  public private(set) var notice: DictationNotice?
  /// Zoom answered 401 or 403; the host flags the key in Settings.
  public private(set) var zoomKeyRejected = false
  /// The transcriber in use.
  public private(set) var transcriber: TranscriberKind?

  /// The finished text, for the HUD.
  public var committedText: String { TextJoin.join(finals) }

  @ObservationIgnored private let environment: DictationEnvironment
  @ObservationIgnored private let stopSignal = AsyncSignal()
  @ObservationIgnored private let cancelSignal = AsyncSignal()
  @ObservationIgnored private let transcriberDone = AsyncSignal()
  @ObservationIgnored private var cancelRequested = false
  @ObservationIgnored private var language = Language.fallback
  @ObservationIgnored private var fallback: TranscriberKind?
  @ObservationIgnored private var polishedParts: [String] = []
  /// Zoom's detected language per segment, with auto-detect.
  @ObservationIgnored private var detectedLanguages: [String] = []
  @ObservationIgnored private var transcriberFailure: TranscriberFailure?
  @ObservationIgnored private var eventCount = 0
  @ObservationIgnored private var generation = 0
  /// The dictation's audio, held in memory only, for a fallback transcriber.
  @ObservationIgnored private var buffer: [AudioChunk] = []
  @ObservationIgnored private var sampleCount = 0
  @ObservationIgnored private var audioEnded = false
  @ObservationIgnored private var input: AsyncStream<AudioChunk>.Continuation?
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var transcriberTask: Task<Void, Never>?

  public init(environment: DictationEnvironment) {
    self.environment = environment
  }

  /// Ends the recording; the dictation goes on to polish and deliver.
  public func finish() {
    stopSignal.fire()
  }

  /// Cancels at any stage; nothing is saved or delivered.
  public func cancel() {
    cancelRequested = true
    cancelSignal.fire()
    stopSignal.fire()
  }

  /// Runs the dictation to its end.
  public func run(config: DictationConfig, target: TargetContext) async -> DictationOutcome {
    let outcome = await perform(config: config, target: target)
    phase = .done
    tearDown()
    switch outcome {
    case .delivered(let dictation, let saved):
      Log.session.info(
        "done: \(dictation.transcriber.rawValue, privacy: .public)/\(dictation.polisher.rawValue, privacy: .public), \(dictation.durationMs, privacy: .public) ms, \(dictation.delivery.rawValue, privacy: .public), saved \(saved, privacy: .public)"
      )
    case .cancelled:
      Log.session.info("cancelled")
    case .failed(let failure):
      Log.session.info("failed: \(String(describing: failure), privacy: .public)")
    }
    return outcome
  }

  private func perform(config: DictationConfig, target: TargetContext) async -> DictationOutcome {
    language = config.language
    let startedAt = environment.now()

    // Audio first, so no word is lost while the engines are chosen.
    let audio: AsyncStream<AudioChunk>
    do {
      audio = try await environment.audio.start()
    } catch {
      Log.session.error("microphone unavailable: \(String(describing: error), privacy: .public)")
      return .failed(.microphoneUnavailable)
    }
    phase = .recording
    let pump = Task { [weak self] in
      for await chunk in audio { self?.receive(chunk) }
      self?.inputEnded()
    }
    let limits = environment.limits
    let clock = environment.clock
    let cap = Task { [weak self] in
      do {
        try await clock.sleep(for: limits.warnAt)
        self?.nearingLimit = true
        try await clock.sleep(for: limits.maxDuration - limits.warnAt)
        Log.session.info("reached the time cap")
        self?.finish()
      } catch {}
    }
    tasks += [pump, cap]

    let availability = environment.availability
    let applePolisher = await availability.applePolisher(language: language)
    let plan = EngineRouter.plan(
      RouterInputs(
        engine: config.engine,
        language: language,
        zoomKeyStored: config.zoomKeyStored,
        appleTranscriberAvailable: await availability.appleTranscriberAvailable(language: language),
        applePolisherAvailable: applePolisher == .available))
    guard let kind = plan.transcriber else {
      await stopAudio(pump: pump)
      return cancelRequested ? .cancelled : .failed(.speechModelMissing(language: language))
    }
    fallback = plan.fallback
    Log.session.info("recording with \(kind.rawValue, privacy: .public)")
    startTranscriber(kind, textPolishing: plan.textPolishing)

    await stopSignal.wait()
    cap.cancel()
    await stopAudio(pump: pump)
    if cancelRequested { return .cancelled }

    phase = .finishing
    let complete = await waitForTranscriber()
    if cancelRequested { return .cancelled }
    if !complete { Log.session.info("transcript timed out; using what arrived") }
    let raw = TextJoin.join(complete ? finals : finals + [draft])
    guard !raw.isEmpty else {
      return .failed(transcriberFailure == nil ? .nothingHeard : .couldntTranscribe)
    }

    // With auto-detect, polish and save in the language heard most.
    if language == Language.auto, let spoken = Language.mostCommon(detectedLanguages) { language = spoken }

    phase = .polishing
    guard var polish = await polish(raw: raw, plan: plan) else { return .cancelled }
    if case .unavailable(let reason) = applePolisher, polish.polisher != .zoom {
      let skipped = "apple:unavailable:\(reason)"
      polish.unpolishedReason = [skipped, polish.unpolishedReason].compactMap(\.self).joined(separator: "; ")
    }
    if cancelRequested { return .cancelled }

    // Saved before it is inserted.
    let planned = environment.delivery.plannedDelivery(for: target)
    var dictation = Dictation(
      createdAt: startedAt,
      durationMs: sampleCount * 1000 / AudioChunk.sampleRate,
      language: language,
      rawText: raw,
      polishedText: polish.text,
      transcriber: transcriber ?? kind,
      polisher: polish.polisher,
      unpolishedReason: polish.unpolishedReason,
      targetApp: target.bundleID,
      delivery: planned)
    var saved = true
    do {
      try environment.store.save(dictation)
    } catch {
      saved = false
    }
    let delivered = await environment.delivery.deliver(dictation.text, planned: planned, target: target)
    if delivered != planned {
      dictation.delivery = delivered
      if saved { try? environment.store.updateDelivery(id: dictation.id, to: delivered) }
    }
    return .delivered(dictation, saved: saved)
  }

  // MARK: Audio

  private func receive(_ chunk: AudioChunk) {
    buffer.append(chunk)
    sampleCount += chunk.samples.count
    recorded = .milliseconds(sampleCount * 1000 / AudioChunk.sampleRate)
    level = chunk.level
    input?.yield(chunk)
  }

  /// The audio stream ended: after `stop`, or because the input was lost, in
  /// which case the dictation finishes with what it has.
  private func inputEnded() {
    audioEnded = true
    input?.finish()
    stopSignal.fire()
  }

  private func stopAudio(pump: Task<Void, Never>) async {
    await environment.audio.stop()
    await pump.value
    level = 0
  }

  // MARK: Transcription

  private func startTranscriber(_ kind: TranscriberKind, textPolishing: Bool) {
    generation += 1
    let current = generation
    transcriber = kind
    let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .unbounded)
    // A transcriber always hears the dictation from its start.
    for chunk in buffer { continuation.yield(chunk) }
    if audioEnded { continuation.finish() }
    input?.finish()
    input = continuation

    let engine = environment.makeTranscriber(kind, TranscriberOptions(language: language, textPolishing: textPolishing))
    transcriberTask?.cancel()
    transcriberTask = Task { [weak self] in
      var terminated = false
      for await event in engine.transcribe(stream) {
        self?.handle(event, generation: current)
        if event == .ended || event.isFailure {
          terminated = true
          break
        }
      }
      if !terminated && !Task.isCancelled { self?.handle(.ended, generation: current) }
    }
  }

  private func handle(_ event: TranscriptEvent, generation: Int) {
    guard generation == self.generation else { return }
    eventCount += 1
    switch event {
    case .draft(let text):
      draft = text
    case .final(let text):
      finals.append(text)
      draft = ""
    case .polished(let text):
      polishedParts.append(text)
    case .language(let tag):
      detectedLanguages.append(tag)
    case .ended:
      transcriberDone.fire()
    case .failed(let failure):
      transcriberFailed(failure)
    }
  }

  private func transcriberFailed(_ failure: TranscriberFailure) {
    Log.session.error(
      "\(self.transcriber?.rawValue ?? "-", privacy: .public) failed: \(failure.code, privacy: .public)")
    if failure == .keyRejected { zoomKeyRejected = true }
    if let next = fallback {
      // Zoom's partial text is discarded; the fallback hears it all from memory.
      fallback = nil
      notice = .zoomUnavailable
      finals = []
      draft = ""
      polishedParts = []
      detectedLanguages = []
      startTranscriber(next, textPolishing: false)
      return
    }
    transcriberFailure = failure
    transcriberDone.fire()
  }

  /// Waits for the transcriber to end. Returns false if nothing arrived for
  /// the finish timeout.
  private func waitForTranscriber() async -> Bool {
    let clock = environment.clock
    let timeout = environment.limits.finishTimeout
    let done = transcriberDone
    let cancelled = cancelSignal
    while !done.isFired {
      let before = eventCount
      let signalled = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
          await done.wait()
          return true
        }
        group.addTask {
          await cancelled.wait()
          return true
        }
        group.addTask {
          try? await clock.sleep(for: timeout)
          return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
      }
      if cancelRequested { return false }
      if !signalled && eventCount == before { return false }
    }
    return true
  }

  // MARK: Polishing

  /// Zoom's polished text if it came, else the chain; `nil` if cancelled.
  private func polish(raw: String, plan: EnginePlan) async -> PolishOutcome? {
    let zoomText = TextJoin.join(polishedParts)
    if transcriber == .zoom, !zoomText.isEmpty, PolishGuard.check(raw: raw, output: zoomText) == nil {
      return PolishOutcome(text: zoomText, polisher: .zoom, unpolishedReason: nil)
    }
    let chain = PolishChain(plan.polishers.compactMap(environment.makePolisher))
    let language = language
    let cancelled = cancelSignal
    return await withTaskGroup(of: PolishOutcome?.self) { group in
      group.addTask { await chain.run(raw: raw, language: language) }
      group.addTask {
        await cancelled.wait()
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  private func tearDown() {
    for task in tasks { task.cancel() }
    transcriberTask?.cancel()
    input?.finish()
    input = nil
    buffer = []
  }
}

/// A one-shot signal that any number of tasks can wait on.
final class AsyncSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var fired = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  var isFired: Bool { lock.withLock { fired } }

  func fire() {
    let waiting = lock.withLock {
      fired = true
      defer { waiters = [:] }
      return waiters
    }
    for continuation in waiting.values { continuation.resume() }
  }

  /// Returns once fired, or when the waiting task is cancelled.
  func wait() async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let resumeNow = lock.withLock {
          if fired || Task.isCancelled { return true }
          waiters[id] = continuation
          return false
        }
        if resumeNow { continuation.resume() }
      }
    } onCancel: {
      lock.withLock { waiters.removeValue(forKey: id) }?.resume()
    }
  }
}
