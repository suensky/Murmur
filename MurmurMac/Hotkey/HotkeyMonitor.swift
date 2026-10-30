import AppKit
import MurmurKit
import os

/// Listens to the trigger key and Esc through a `CGEventTap`.
///
/// The tap swallows only Esc, and only while a dictation runs. It neither
/// records nor logs other keys: it notes only that one was pressed, so a
/// shortcut such as Right ⌘-C does not start a dictation. The callback only
/// enqueues, so it stays fast; if macOS disables the tap, it is re-enabled at once.
final class HotkeyMonitor: @unchecked Sendable {
  enum Event: Equatable {
    case trigger(down: Bool, at: Int64)
    case escape(at: Int64)
    /// Another key went down while the trigger was held.
    case otherKey
  }

  private static let escapeKeyCode: Int64 = 53
  private let log = Logger(subsystem: "com.ai.murmur", category: "hotkey")
  private let lock = NSLock()
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var trigger: TriggerKey = .fn
  private var triggerIsDown = false
  private var swallowsEscape = false
  private let onEvent: @MainActor (Event) -> Void

  init(onEvent: @escaping @MainActor (Event) -> Void) {
    self.onEvent = onEvent
  }

  var isRunning: Bool { lock.withLock { tap != nil } }

  func setTrigger(_ key: TriggerKey) {
    lock.withLock {
      trigger = key
      triggerIsDown = false
    }
  }

  /// Whether Esc is swallowed: true while a dictation runs.
  func setSwallowsEscape(_ value: Bool) {
    lock.withLock { swallowsEscape = value }
  }

  /// Starts the tap. Fails without Accessibility permission.
  @discardableResult
  func start() -> Bool {
    if isRunning { return true }
    let mask =
      (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: CGEventMask(mask),
        callback: { _, type, event, refcon in
          guard let refcon else { return Unmanaged.passUnretained(event) }
          let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
          return monitor.handle(type: type, event: event)
        },
        userInfo: Unmanaged.passUnretained(self).toOpaque())
    else {
      log.error("event tap unavailable; Accessibility not granted")
      return false
    }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    lock.withLock {
      self.tap = tap
      self.source = source
    }
    log.info("event tap started")
    return true
  }

  func stop() {
    let (tap, source) = lock.withLock {
      defer {
        self.tap = nil
        self.source = nil
      }
      return (self.tap, self.source)
    }
    if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
  }

  static func now() -> Int64 {
    Int64(ProcessInfo.processInfo.systemUptime * 1000)
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
      log.notice("event tap re-enabled")
    case .flagsChanged:
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      let change: Bool? = lock.withLock {
        guard Self.keyCode(for: trigger) == keyCode else { return nil }
        let down = Self.isDown(trigger, flags: event.flags)
        guard down != triggerIsDown else { return nil }
        triggerIsDown = down
        return down
      }
      if let down = change { enqueue(.trigger(down: down, at: Self.now())) }
    case .keyDown:
      if event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode {
        let swallow = lock.withLock { swallowsEscape }
        enqueue(.escape(at: Self.now()))
        if swallow { return nil }
      } else if lock.withLock({ triggerIsDown }) {
        enqueue(.otherKey)
      }
    default:
      break
    }
    return Unmanaged.passUnretained(event)
  }

  private func enqueue(_ event: Event) {
    let onEvent = onEvent
    DispatchQueue.main.async { onEvent(event) }
  }

  static func keyCode(for key: TriggerKey) -> Int64 {
    switch key {
    case .fn: 63  // kVK_Function, also the 🌐 key
    case .rightOption: 61  // kVK_RightOption
    case .rightCommand: 54  // kVK_RightCommand
    }
  }

  /// Device-dependent masks tell the right-hand modifiers from the left.
  static func isDown(_ key: TriggerKey, flags: CGEventFlags) -> Bool {
    switch key {
    case .fn: flags.contains(.maskSecondaryFn)
    case .rightOption: flags.rawValue & 0x40 != 0  // NX_DEVICERALTKEYMASK
    case .rightCommand: flags.rawValue & 0x10 != 0  // NX_DEVICERCMDKEYMASK
    }
  }
}
