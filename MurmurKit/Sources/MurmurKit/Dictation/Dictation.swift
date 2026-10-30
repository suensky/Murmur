import Foundation

/// How a dictation's text reached the user.
public enum Delivery: String, Sendable, Codable, CaseIterable {
  case pasted
  case copied
}

/// A finished dictation, as kept in `library.db`.
public struct Dictation: Sendable, Equatable, Identifiable {
  public var id: UUID
  public var createdAt: Date
  public var durationMs: Int
  /// BCP-47, e.g. `en-US`.
  public var language: String
  public var rawText: String
  /// `nil` when nothing polished it.
  public var polishedText: String?
  public var transcriber: TranscriberKind
  public var polisher: PolisherKind
  /// Why the chain fell through; a code, never user text.
  public var unpolishedReason: String?
  /// The frontmost app's bundle ID when the dictation started.
  public var targetApp: String?
  public var delivery: Delivery

  public init(
    id: UUID = UUID(),
    createdAt: Date,
    durationMs: Int,
    language: String,
    rawText: String,
    polishedText: String?,
    transcriber: TranscriberKind,
    polisher: PolisherKind,
    unpolishedReason: String?,
    targetApp: String?,
    delivery: Delivery
  ) {
    self.id = id
    self.createdAt = createdAt
    self.durationMs = durationMs
    self.language = language
    self.rawText = rawText
    self.polishedText = polishedText
    self.transcriber = transcriber
    self.polisher = polisher
    self.unpolishedReason = unpolishedReason
    self.targetApp = targetApp
    self.delivery = delivery
  }

  /// The text that was inserted: the polished text, else the raw.
  public var text: String { polishedText ?? rawText }

  /// Whether a model polished it; History marks the others *Not polished*.
  public var isPolished: Bool { polisher == .zoom || polisher == .apple }
}

/// The app and field a dictation started in, captured by the host.
public struct TargetContext: Sendable, Equatable {
  public var bundleID: String?
  public var processID: Int32?
  /// Whether the focused element accepted text at the start.
  public var acceptsText: Bool

  public init(bundleID: String?, processID: Int32?, acceptsText: Bool) {
    self.bundleID = bundleID
    self.processID = processID
    self.acceptsText = acceptsText
  }

  public static let none = TargetContext(bundleID: nil, processID: nil, acceptsText: false)
}

/// Delivers a dictation's text. The Mac's `TextInserter` pastes; a fake records.
public protocol TextDelivering: Sendable {
  /// What `deliver` will try, decided before the dictation is saved.
  @MainActor func plannedDelivery(for target: TargetContext) -> Delivery
  /// Delivers the text and returns what actually happened.
  @MainActor func deliver(_ text: String, planned: Delivery, target: TargetContext) async -> Delivery
}
