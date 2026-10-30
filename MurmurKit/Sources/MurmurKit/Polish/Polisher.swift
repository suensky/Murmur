import Foundation

public enum PolisherKind: String, Sendable, Codable, CaseIterable {
  case zoom
  case apple
  case basic
  case none
}

/// Why a polisher returned no text. Codes are stored as `unpolished_reason`.
public enum PolishFailure: Error, Sendable, Equatable {
  case unavailable(String)
  case refused
  case timedOut
  case rejected(String)
  case failed(String)

  public var code: String {
    switch self {
    case .unavailable(let reason): "unavailable:\(reason)"
    case .refused: "refused"
    case .timedOut: "timed-out"
    case .rejected(let reason): "rejected:\(reason)"
    case .failed(let reason): "failed:\(reason)"
    }
  }
}

public enum PolisherAvailability: Sendable, Equatable {
  case available
  case unavailable(String)
}

/// Rewrites raw dictated text as polished text.
public protocol Polisher: Sendable {
  var kind: PolisherKind { get }
  func availability(for language: String) async -> PolisherAvailability
  func polish(_ raw: String, language: String) async -> Result<String, PolishFailure>
}

/// The guards every polisher's output passes.
public enum PolishGuard {
  public static let minRatio = 0.3
  public static let maxRatio = 2.0

  /// `nil` if the output is a plausible rewrite of `raw`, else why not.
  public static func check(raw: String, output: String) -> PolishFailure? {
    let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { return .rejected("empty") }
    let rawCount = Double(WordCount.count(raw))
    guard rawCount > 0 else { return nil }
    let ratio = Double(WordCount.count(output)) / rawCount
    if ratio < minRatio { return .rejected("too-short") }
    if ratio > maxRatio { return .rejected("too-long") }
    return nil
  }
}

/// Counts words; for scripts without spaces, counts characters.
public enum WordCount {
  public static func count(_ text: String) -> Int {
    var count = 0
    text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
      count += 1
    }
    return count
  }
}

/// What a polishing chain produced.
public struct PolishOutcome: Sendable, Equatable {
  /// `nil` when no polisher succeeded.
  public var text: String?
  public var polisher: PolisherKind
  /// Why the polishers before the one that succeeded fell through.
  public var unpolishedReason: String?

  public init(text: String?, polisher: PolisherKind, unpolishedReason: String?) {
    self.text = text
    self.polisher = polisher
    self.unpolishedReason = unpolishedReason
  }
}

/// Runs polishers in order until one produces text that passes the guards.
/// One that is unavailable for the language is skipped.
public struct PolishChain: Sendable {
  public let polishers: [any Polisher]

  public init(_ polishers: [any Polisher]) {
    self.polishers = polishers
  }

  public func run(raw: String, language: String) async -> PolishOutcome {
    var reasons: [String] = []
    for polisher in polishers {
      if Task.isCancelled { break }
      if case .unavailable(let reason) = await polisher.availability(for: language) {
        Log.polish.info("\(polisher.kind.rawValue, privacy: .public) skipped: \(reason, privacy: .public)")
        // The basic cleanup always runs; only a smarter polisher's absence is a reason.
        reasons.append("\(polisher.kind.rawValue):unavailable:\(reason)")
        continue
      }
      let result = await polisher.polish(raw, language: language)
      let failure: PolishFailure
      switch result {
      case .success(let text):
        if let rejection = PolishGuard.check(raw: raw, output: text) {
          failure = rejection
        } else {
          Log.polish.info("polished by \(polisher.kind.rawValue, privacy: .public)")
          return PolishOutcome(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            polisher: polisher.kind,
            unpolishedReason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
        }
      case .failure(let error):
        failure = error
      }
      Log.polish.info("\(polisher.kind.rawValue, privacy: .public) fell through: \(failure.code, privacy: .public)")
      reasons.append("\(polisher.kind.rawValue):\(failure.code)")
    }
    return PolishOutcome(
      text: nil, polisher: .none, unpolishedReason: reasons.isEmpty ? "no-polisher" : reasons.joined(separator: "; "))
  }
}

/// A polisher with a fixed answer, for tests and previews.
public final class FakePolisher: Polisher, @unchecked Sendable {
  public let kind: PolisherKind
  private let lock = NSLock()
  private let availabilityValue: PolisherAvailability
  private let answer: @Sendable (String) -> Result<String, PolishFailure>
  private var inputs: [String] = []

  public init(
    kind: PolisherKind,
    availability: PolisherAvailability = .available,
    answer: @escaping @Sendable (String) -> Result<String, PolishFailure>
  ) {
    self.kind = kind
    self.availabilityValue = availability
    self.answer = answer
  }

  public convenience init(kind: PolisherKind, returning text: String) {
    self.init(kind: kind) { _ in .success(text) }
  }

  public convenience init(kind: PolisherKind, failing failure: PolishFailure) {
    self.init(kind: kind) { _ in .failure(failure) }
  }

  /// The raw texts this polisher was given.
  public var calls: [String] { lock.withLock { inputs } }

  public func availability(for language: String) async -> PolisherAvailability {
    availabilityValue
  }

  public func polish(_ raw: String, language: String) async -> Result<String, PolishFailure> {
    lock.withLock { inputs.append(raw) }
    return answer(raw)
  }
}
