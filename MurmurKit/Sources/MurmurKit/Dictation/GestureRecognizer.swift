import Foundation

/// Turns the trigger key's presses, and Esc, into start, finish and cancel.
///
/// - Recording starts on the first key-down, so no word is lost while the
///   gesture is decided.
/// - Held 250 ms or more: hold mode; key-up finishes.
/// - Released sooner and pressed again within 300 ms of the first key-down:
///   hands-free; the next press finishes.
/// - A lone short tap discards the recording.
/// - Esc cancels at any stage.
///
/// Times are in milliseconds, from any monotonic origin.
public struct GestureRecognizer: Sendable {
  public static let holdThreshold: Int64 = 250
  public static let doubleTapWindow: Int64 = 300

  public enum Input: Sendable, Equatable {
    case keyDown(at: Int64)
    case keyUp(at: Int64)
    case escape(at: Int64)
    /// The time has come for a pending deadline.
    case tick(at: Int64)
  }

  public enum Action: Sendable, Equatable {
    case start
    /// The gesture is now hands-free; the HUD shows its stop button.
    case handsFree
    case finish
    case cancel
    /// A lone short tap: drop the recording quietly.
    case discard
  }

  enum State: Equatable {
    case idle
    /// The first press is down.
    case pressed(since: Int64)
    /// Released quickly; a second press within the window makes it hands-free.
    case awaitingSecondPress(firstDown: Int64)
    /// Hands-free; `keyIsDown` while the second press is still held.
    case handsFree(keyIsDown: Bool)
    /// Finished on a press; that press's key-up is swallowed.
    case finishingPress
  }

  private(set) var state = State.idle

  public init() {}

  /// Whether a dictation is underway, so Esc is the app's to swallow.
  public var isActive: Bool {
    switch state {
    case .idle, .finishingPress: false
    default: true
    }
  }

  /// Whether the first press is still down and undecided: another key now
  /// means a shortcut, not a dictation.
  public var isFirstPressDown: Bool {
    if case .pressed = state { return true }
    return false
  }

  /// When to send `.tick`, if anything is waiting on time.
  public var deadline: Int64? {
    if case .awaitingSecondPress(let firstDown) = state { return firstDown + Self.doubleTapWindow }
    return nil
  }

  /// Forgets the gesture, after the session ended on its own.
  public mutating func reset() {
    state = .idle
  }

  public mutating func handle(_ input: Input) -> Action? {
    switch (state, input) {
    case (_, .escape):
      guard isActive else { return nil }
      state = .idle
      return .cancel

    case (.idle, .keyDown(let time)):
      state = .pressed(since: time)
      return .start

    case (.pressed(let since), .keyUp(let time)):
      if time - since >= Self.holdThreshold {
        state = .idle
        return .finish
      }
      state = .awaitingSecondPress(firstDown: since)
      return nil

    case (.awaitingSecondPress(let firstDown), .keyDown(let time)):
      if time - firstDown <= Self.doubleTapWindow {
        state = .handsFree(keyIsDown: true)
        return .handsFree
      }
      // The window passed without a tick: the first tap was alone.
      state = .idle
      return .discard

    case (.awaitingSecondPress(let firstDown), .tick(let time)):
      guard time - firstDown >= Self.doubleTapWindow else { return nil }
      state = .idle
      return .discard

    case (.handsFree(true), .keyUp):
      state = .handsFree(keyIsDown: false)
      return nil

    case (.handsFree(false), .keyDown):
      state = .finishingPress
      return .finish

    case (.finishingPress, .keyUp):
      state = .idle
      return nil

    case (.finishingPress, .keyDown(let time)):
      // A key-up went missing; treat this as a fresh start.
      state = .pressed(since: time)
      return .start

    default:
      return nil
    }
  }
}
