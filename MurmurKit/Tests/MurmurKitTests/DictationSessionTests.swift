import Foundation
import Testing

@testable import MurmurKit

@MainActor
@Suite("DictationSession")
struct DictationSessionTests {
  /// Builds a session around fakes.
  @MainActor
  final class Harness {
    let audio: FakeAudioSource
    let store: any DictationStore
    let library: LibraryStore
    let delivery: RecordingDelivery
    let clock = TestClock()
    let appleReceived = ChunkCounter()
    let zoomReceived = ChunkCounter()
    let applePolisher: FakePolisher
    let session: DictationSession
    var made: [TranscriberOptions] = []

    init(
      chunks: Int = 3,
      keepOpen: Bool = true,
      audioFailure: AudioError? = nil,
      apple: FakeTranscriber.Script = .words(["hello", "there", "friend"]),
      zoom: FakeTranscriber.Script = .words(["zoom", "words", "here"]),
      availability: FixedAvailability = FixedAvailability(),
      applePolisher: FakePolisher = FakePolisher(kind: .apple) { .success("Polished: " + $0) },
      polisherOverride: (any Polisher)? = nil,
      failingStore: Bool = false,
      delivery: RecordingDelivery = RecordingDelivery()
    ) throws {
      audio = FakeAudioSource(
        chunks: (0..<chunks).map { _ in chunk() }, failure: audioFailure, keepOpen: keepOpen)
      library = try LibraryStore.inMemory()
      store = failingStore ? FailingStore() : library
      self.delivery = delivery
      self.applePolisher = applePolisher
      let appleReceived = appleReceived
      let zoomReceived = zoomReceived
      let made = MadeOptions()
      self.madeOptions = made
      let environment = DictationEnvironment(
        audio: audio,
        makeTranscriber: { kind, options in
          made.append(options)
          return switch kind {
          case .apple: FakeTranscriber(kind: .apple, script: apple, received: appleReceived)
          case .zoom: FakeTranscriber(kind: .zoom, script: zoom, received: zoomReceived)
          }
        },
        makePolisher: { kind in
          switch kind {
          case .apple: polisherOverride ?? applePolisher
          case .basic: BasicCleanup()
          case .zoom, .none: nil
          }
        },
        availability: availability,
        store: store,
        delivery: delivery,
        clock: clock,
        now: { Date(timeIntervalSince1970: 1_800_000_000) })
      session = DictationSession(environment: environment)
    }

    let madeOptions: MadeOptions

    func start(engine: Engine = .apple, language: String = "en-US", zoomKey: Bool = false) -> Task<
      DictationOutcome, Never
    > {
      let session = session
      return Task { @MainActor in
        await session.run(
          config: DictationConfig(engine: engine, language: language, zoomKeyStored: zoomKey),
          target: TargetContext(bundleID: "com.apple.TextEdit", processID: 42, acceptsText: true))
      }
    }
  }

  final class MadeOptions: @unchecked Sendable {
    private let lock = NSLock()
    private var options: [TranscriberOptions] = []
    func append(_ value: TranscriberOptions) { lock.withLock { options.append(value) } }
    var all: [TranscriberOptions] { lock.withLock { options } }
  }

  @Test func appleDictationIsPolishedSavedAndPasted() async throws {
    let harness = try Harness()
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    #expect(harness.session.phase == .recording)
    #expect(harness.session.committedText == "hello there friend")
    harness.session.finish()
    let outcome = await run.value

    guard case .delivered(let dictation, let saved) = outcome else {
      Issue.record("expected delivery, got \(outcome)")
      return
    }
    #expect(saved)
    #expect(dictation.rawText == "hello there friend")
    #expect(dictation.polishedText == "Polished: hello there friend")
    #expect(dictation.transcriber == .apple)
    #expect(dictation.polisher == .apple)
    #expect(dictation.unpolishedReason == nil)
    #expect(dictation.delivery == .pasted)
    #expect(dictation.durationMs == 300)
    #expect(dictation.targetApp == "com.apple.TextEdit")
    #expect(harness.delivery.delivered == ["Polished: hello there friend"])
    #expect(try harness.library.recent(limit: 10) == [dictation])
    #expect(harness.session.phase == .done)
    #expect(harness.audio.stopCount >= 1)
  }

  @Test func cancelSavesAndDeliversNothing() async throws {
    let harness = try Harness()
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.cancel()
    #expect(await run.value == .cancelled)
    #expect(try harness.library.recent(limit: 10).isEmpty)
    #expect(harness.delivery.delivered.isEmpty)
  }

  @Test func cancelWhilePolishingDropsTheResult() async throws {
    let gate = AsyncSignal()
    let slow = SlowPolisher(gate: gate, inner: FakePolisher(kind: .apple, returning: "never"))
    let harness = try Harness(polisherOverride: slow)
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    await waitUntil("polishing") { harness.session.phase == .polishing }
    harness.session.cancel()
    #expect(await run.value == .cancelled)
    #expect(harness.delivery.delivered.isEmpty)
    #expect(try harness.library.recent(limit: 10).isEmpty)
    gate.fire()
  }

  @Test func emptyTranscriptIsNotSaved() async throws {
    let harness = try Harness(apple: FakeTranscriber.Script())
    let run = harness.start()
    await waitUntil("recording") { harness.session.phase == .recording && harness.session.recorded > .zero }
    harness.session.finish()
    #expect(await run.value == .failed(.nothingHeard))
    #expect(try harness.library.recent(limit: 10).isEmpty)
    #expect(harness.delivery.delivered.isEmpty)
  }

  @Test func capsTheDictationAtTenMinutes() async throws {
    let harness = try Harness()
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    await waitUntil("cap timer") { harness.clock.sleeperCount == 1 }
    harness.clock.advance(by: .seconds(540))
    await waitUntil("warning") { harness.session.nearingLimit }
    #expect(harness.session.phase == .recording)
    await waitUntil("second cap timer") { harness.clock.sleeperCount == 1 }
    harness.clock.advance(by: .seconds(60))
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected the cap to finish the dictation")
      return
    }
    #expect(dictation.rawText == "hello there friend")
  }

  @Test func waitsTenSecondsThenUsesFinalsAndTheLastDraft() async throws {
    let script = FakeTranscriber.Script(
      afterChunk: [0: [.final("first part")], 2: [.draft("still going")]], atEnd: [])
    let harness = try Harness(apple: script)
    let run = harness.start()
    await waitUntil("draft") { harness.session.draft == "still going" }
    harness.session.finish()
    await waitUntil("finishing") { harness.session.phase == .finishing }
    await waitUntil("finish timer") { harness.clock.sleeperCount == 1 }
    harness.clock.advance(by: .seconds(10))
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery after the timeout")
      return
    }
    #expect(dictation.rawText == "first part still going")
  }

  @Test func zoomFailingAtConnectFallsBackToApple() async throws {
    let harness = try Harness(zoom: FakeTranscriber.Script(failAtStart: .connectFailed(status: 503)))
    let run = harness.start(engine: .zoom, zoomKey: true)
    await waitUntil("apple finals") { harness.session.finals.count == 3 }
    #expect(harness.session.notice == .zoomUnavailable)
    #expect(harness.session.transcriber == .apple)
    #expect(!harness.session.zoomKeyRejected)
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.transcriber == .apple)
    #expect(dictation.rawText == "hello there friend")
    #expect(harness.appleReceived.value == 3)
    #expect(harness.madeOptions.all.first == TranscriberOptions(language: "en-US", textPolishing: true))
  }

  @Test func zoomRejectingTheKeyIsReported() async throws {
    let harness = try Harness(zoom: FakeTranscriber.Script(failAtStart: .keyRejected))
    let run = harness.start(engine: .zoom, zoomKey: true)
    await waitUntil("apple finals") { harness.session.finals.count == 3 }
    #expect(harness.session.zoomKeyRejected)
    harness.session.finish()
    _ = await run.value
  }

  @Test func zoomDroppingMidDictationRetranscribesFromMemory() async throws {
    let zoom = FakeTranscriber.Script(afterChunk: [
      0: [.final("zoom partial")], 1: [.failed(.dropped)],
    ])
    let harness = try Harness(chunks: 2, zoom: zoom)
    let run = harness.start(engine: .zoom, language: "fr-FR", zoomKey: true)
    await waitUntil("fallback") { harness.session.transcriber == .apple }
    harness.audio.send(chunk())
    await waitUntil("apple finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(!dictation.rawText.contains("zoom partial"))
    #expect(dictation.rawText == "hello there friend")
    #expect(harness.appleReceived.value == 3)
    #expect(harness.madeOptions.all.first == TranscriberOptions(language: "fr-FR", textPolishing: false))
  }

  @Test func zoomFailingWithoutAppleKeepsZoomFinals() async throws {
    let zoom = FakeTranscriber.Script(afterChunk: [0: [.final("kept words")], 1: [.failed(.dropped)]])
    let harness = try Harness(zoom: zoom, availability: FixedAvailability(transcriber: false))
    let run = harness.start(engine: .zoom, zoomKey: true)
    await waitUntil("finals") { harness.session.finals == ["kept words"] }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.rawText == "kept words")
    #expect(dictation.transcriber == .zoom)
  }

  @Test func zoomFailingWithNoTextAndNoAppleCannotTranscribe() async throws {
    let zoom = FakeTranscriber.Script(failAtStart: .connectFailed(status: nil))
    let harness = try Harness(zoom: zoom, availability: FixedAvailability(transcriber: false))
    let run = harness.start(engine: .zoom, zoomKey: true)
    await waitUntil("recording") { harness.session.recorded > .zero }
    harness.session.finish()
    #expect(await run.value == .failed(.couldntTranscribe))
    #expect(try harness.library.recent(limit: 10).isEmpty)
  }

  @Test func zoomPolishedTextIsUsedFirst() async throws {
    let zoom = FakeTranscriber.Script(
      afterChunk: [0: [.final("um so the plan is"), .final("ready")]],
      atEnd: [.polished("So, the plan is ready."), .ended])
    let harness = try Harness(zoom: zoom)
    let run = harness.start(engine: .zoom, zoomKey: true)
    await waitUntil("finals") { harness.session.finals.count == 2 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.polisher == .zoom)
    #expect(dictation.polishedText == "So, the plan is ready.")
    #expect(dictation.rawText == "um so the plan is ready")
    #expect(harness.applePolisher.calls.isEmpty)
  }

  @Test func autoDetectSavesTheLanguageHeardMost() async throws {
    let zoom = FakeTranscriber.Script(
      afterChunk: [
        0: [
          .language("fr"), .final("Bonjour à tous"), .language("en"), .final("hello"), .language("fr"),
          .final("merci"),
        ]
      ])
    let harness = try Harness(zoom: zoom)
    let run = harness.start(engine: .zoom, language: Language.auto, zoomKey: true)
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.language == "fr")
    #expect(harness.madeOptions.all.first?.language == Language.auto)
  }

  @Test func autoDetectWithNoDetectionKeepsAuto() async throws {
    let harness = try Harness()
    let run = harness.start(engine: .zoom, language: Language.auto, zoomKey: true)
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.language == Language.auto)
  }

  @Test func appleUnavailableWithoutAKeyNeedsTheSpeechModel() async throws {
    let harness = try Harness(availability: FixedAvailability(transcriber: false))
    let outcome = await harness.start(language: "ja-JP").value
    #expect(outcome == .failed(.speechModelMissing(language: "ja-JP")))
    #expect(harness.audio.stopCount == 1)
  }

  @Test func microphoneFailureEndsTheDictation() async throws {
    let harness = try Harness(audioFailure: .permissionDenied)
    #expect(await harness.start().value == .failed(.microphoneUnavailable))
  }

  @Test func failedSaveStillInserts() async throws {
    let harness = try Harness(failingStore: true)
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    guard case .delivered(_, let saved) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(!saved)
    #expect(harness.delivery.delivered == ["Polished: hello there friend"])
  }

  @Test func deliveryThatFallsBackToCopyIsRecorded() async throws {
    let harness = try Harness(delivery: RecordingDelivery(planned: .pasted, actual: .copied))
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.delivery == .copied)
    #expect(try harness.library.recent(limit: 1).first?.delivery == .copied)
  }

  @Test func lostInputFinishesWithWhatItHas() async throws {
    let harness = try Harness()
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.audio.loseInput()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.rawText == "hello there friend")
  }

  @Test func unavailablePolisherFallsToBasicCleanupWithAReason() async throws {
    let harness = try Harness(
      chunks: 4, apple: .words(["um", "the", "the", "plan"]),
      availability: FixedAvailability(polisher: .unavailable("apple-intelligence-off")))
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 4 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.polisher == .basic)
    #expect(dictation.polishedText == "The plan")
    #expect(dictation.unpolishedReason == "apple:unavailable:apple-intelligence-off")
    #expect(!dictation.isPolished)
    #expect(harness.applePolisher.calls.isEmpty)
  }

  @Test func rejectedPolishFallsThroughTheChain() async throws {
    let harness = try Harness(
      applePolisher: FakePolisher(
        kind: .apple, returning: "Sure! Here is an email to Bob with lots of extra words added"))
    let run = harness.start()
    await waitUntil("finals") { harness.session.finals.count == 3 }
    harness.session.finish()
    guard case .delivered(let dictation, _) = await run.value else {
      Issue.record("expected delivery")
      return
    }
    #expect(dictation.polisher == .basic)
    #expect(dictation.polishedText == "Hello there friend")
    #expect(dictation.unpolishedReason == "apple:rejected:too-long")
  }
}

/// Waits on a gate before answering.
struct SlowPolisher: Polisher {
  let gate: AsyncSignal
  let inner: FakePolisher
  var kind: PolisherKind { inner.kind }

  func availability(for language: String) async -> PolisherAvailability { .available }

  func polish(_ raw: String, language: String) async -> Result<String, PolishFailure> {
    await gate.wait()
    return await inner.polish(raw, language: language)
  }
}
