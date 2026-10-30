import Foundation

public enum TranscriberKind: String, Sendable, Codable, CaseIterable {
  case apple
  case zoom
}

/// What a transcriber reports while it runs.
public enum TranscriptEvent: Sendable, Equatable {
  /// The text of the segment in progress; replaces the previous draft.
  case draft(String)
  /// A finished segment.
  case final(String)
  /// Polished text for one or more segments (Zoom with Text Polishing).
  case polished(String)
  /// The language detected for the segment just finished, as BCP-47 (Zoom with auto-detect).
  case language(String)
  /// All input is transcribed; nothing follows.
  case ended
  /// The transcriber stopped; nothing follows.
  case failed(TranscriberFailure)
}

public enum TranscriberFailure: Error, Sendable, Equatable {
  /// The engine or its model is not available for the language.
  case unavailable
  /// The connection could not be made: network, 429 or 5xx.
  case connectFailed(status: Int?)
  /// The API key was refused: 401 or 403.
  case keyRejected
  /// The connection dropped mid-dictation.
  case dropped
  /// Any other error, by code.
  case engine(String)

  /// A code for logs, free of user data.
  public var code: String {
    switch self {
    case .unavailable: "unavailable"
    case .connectFailed(let status): "connect-failed-\(status.map(String.init) ?? "network")"
    case .keyRejected: "key-rejected"
    case .dropped: "dropped"
    case .engine(let code): "engine-\(code)"
    }
  }
}

/// Turns audio into text.
///
/// The transcriber reads `audio` until it ends, which tells it the input is
/// over; it then yields what remains and `ended`, or `failed`. Cancelling the
/// consuming task stops it.
public protocol Transcriber: Sendable {
  var kind: TranscriberKind { get }
  func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent>
}

/// How a dictation's transcriber is set up.
public struct TranscriberOptions: Sendable, Equatable {
  public var language: String
  /// Zoom's Text Polishing; en-US only.
  public var textPolishing: Bool

  public init(language: String, textPolishing: Bool) {
    self.language = language
    self.textPolishing = textPolishing
  }
}

/// A scripted transcriber for tests and previews.
public struct FakeTranscriber: Transcriber {
  public struct Script: Sendable {
    /// Fails before reading any audio.
    public var failAtStart: TranscriberFailure?
    /// Events after the chunk at each index (0-based).
    public var afterChunk: [Int: [TranscriptEvent]]
    /// Events once the input ends; `ended` unless set.
    public var atEnd: [TranscriptEvent]

    public init(
      failAtStart: TranscriberFailure? = nil,
      afterChunk: [Int: [TranscriptEvent]] = [:],
      atEnd: [TranscriptEvent] = [.ended]
    ) {
      self.failAtStart = failAtStart
      self.afterChunk = afterChunk
      self.atEnd = atEnd
    }

    /// Each chunk becomes one final, with the given words.
    public static func words(_ words: [String], atEnd: [TranscriptEvent] = [.ended]) -> Script {
      var afterChunk: [Int: [TranscriptEvent]] = [:]
      for (index, word) in words.enumerated() {
        afterChunk[index] = [.draft(word), .final(word)]
      }
      return Script(afterChunk: afterChunk, atEnd: atEnd)
    }
  }

  public let kind: TranscriberKind
  public let script: Script
  /// Counts the chunks this transcriber received, for assertions.
  public let received: ChunkCounter

  public init(kind: TranscriberKind, script: Script, received: ChunkCounter = ChunkCounter()) {
    self.kind = kind
    self.script = script
    self.received = received
  }

  public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
    let script = script
    let received = received
    return AsyncStream { continuation in
      let task = Task {
        if let failure = script.failAtStart {
          continuation.yield(.failed(failure))
          continuation.finish()
          return
        }
        var index = 0
        for await _ in audio {
          received.increment()
          for event in script.afterChunk[index] ?? [] {
            continuation.yield(event)
            if case .failed = event {
              continuation.finish()
              return
            }
          }
          index += 1
        }
        guard !Task.isCancelled else { return continuation.finish() }
        for event in script.atEnd { continuation.yield(event) }
        // Without `ended` in the script, hang until cancelled, as a slow engine would.
        if !script.atEnd.contains(.ended) && !script.atEnd.contains(where: \.isFailure) {
          while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

extension TranscriptEvent {
  var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}

/// A thread-safe counter.
public final class ChunkCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  public init() {}

  public var value: Int { lock.withLock { count } }

  func increment() { lock.withLock { count += 1 } }
}
