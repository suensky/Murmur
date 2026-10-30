import Foundation
import Testing

@testable import MurmurKit

/// A clock that moves only when the test advances it.
final class TestClock: Clock, @unchecked Sendable {
  struct Instant: InstantProtocol {
    var offset: Duration

    func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
    func duration(to other: Instant) -> Duration { other.offset - offset }
    static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
  }

  private struct Sleeper {
    let deadline: Instant
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var current = Instant(offset: .zero)
  private var sleepers: [UUID: Sleeper] = [:]

  var now: Instant { lock.withLock { current } }
  var minimumResolution: Duration { .zero }

  /// Tasks sleeping on this clock.
  var sleeperCount: Int { lock.withLock { sleepers.count } }

  func sleep(until deadline: Instant, tolerance: Duration?) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let resume: Result<Void, any Error>? = lock.withLock {
          if Task.isCancelled { return .failure(CancellationError()) }
          if deadline <= current { return .success(()) }
          sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return nil
        }
        if let resume { continuation.resume(with: resume) }
      }
    } onCancel: {
      lock.withLock { sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let due = lock.withLock {
      current = current.advanced(by: duration)
      let due = sleepers.filter { $0.value.deadline <= current }
      for id in due.keys { sleepers.removeValue(forKey: id) }
      return due.values
    }
    for sleeper in due { sleeper.continuation.resume() }
  }
}

/// Polls until `condition` holds, failing the test after `timeout`.
@MainActor
func waitUntil(
  _ description: String = "condition",
  timeout: Duration = .seconds(5),
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    if ContinuousClock.now > deadline {
      Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
      return
    }
    try? await Task.sleep(for: .milliseconds(2))
  }
}

/// Records deliveries; answers with a fixed plan and result.
final class RecordingDelivery: TextDelivering, @unchecked Sendable {
  private let lock = NSLock()
  private var texts: [String] = []
  let planned: Delivery
  let actual: Delivery?

  init(planned: Delivery = .pasted, actual: Delivery? = nil) {
    self.planned = planned
    self.actual = actual
  }

  var delivered: [String] { lock.withLock { texts } }

  func plannedDelivery(for target: TargetContext) -> Delivery { planned }

  func deliver(_ text: String, planned: Delivery, target: TargetContext) async -> Delivery {
    lock.withLock { texts.append(text) }
    return actual ?? planned
  }
}

struct FixedAvailability: EngineAvailability {
  var transcriber = true
  var polisher = PolisherAvailability.available

  func appleTranscriberAvailable(language: String) async -> Bool { transcriber }
  func applePolisher(language: String) async -> PolisherAvailability { polisher }
}

/// A store whose writes fail.
struct FailingStore: DictationStore {
  struct Failure: Error {}

  func save(_ dictation: Dictation) throws { throw Failure() }
  func updateDelivery(id: UUID, to delivery: Delivery) throws { throw Failure() }
  func updatePolish(id: UUID, outcome: PolishOutcome) throws { throw Failure() }
  func delete(id: UUID) throws { throw Failure() }
  func deleteAll() throws { throw Failure() }
  func recent(limit: Int) throws -> [Dictation] { [] }
  func search(_ query: String, limit: Int) throws -> [Dictation] { [] }
  func prune(before cutoff: Date) throws -> Int { 0 }
}

/// A chunk of 100 ms of quiet audio.
func chunk(_ value: Int16 = 100) -> AudioChunk {
  AudioChunk(samples: Array(repeating: value, count: 1_600))
}

func sampleDictation(
  text: String = "Hello there.",
  raw: String = "hello there",
  createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
  polisher: PolisherKind = .apple
) -> Dictation {
  Dictation(
    createdAt: createdAt,
    durationMs: 1_200,
    language: "en-US",
    rawText: raw,
    polishedText: text,
    transcriber: .apple,
    polisher: polisher,
    unpolishedReason: nil,
    targetApp: "com.apple.TextEdit",
    delivery: .pasted)
}
