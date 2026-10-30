import AppKit
import ApplicationServices
import MurmurKit
import os

/// The pasteboard, as the inserter uses it.
@MainActor
protocol PasteboardAccess: AnyObject {
  var changeCount: Int { get }
  /// The current items, copied so they can be restored.
  func saveItems() -> [NSPasteboardItem]
  func restore(_ items: [NSPasteboardItem])
  /// Writes `text`; `transient` marks it `org.nspasteboard.TransientType` so
  /// clipboard managers skip it.
  func write(_ text: String, transient: Bool)
}

/// Posts ⌘V.
@MainActor
protocol PasteEventPoster {
  /// Returns false if the events could not be made or posted.
  func postPaste() -> Bool
}

/// The app in front and its focused element.
@MainActor
protocol FocusInspecting {
  var frontmostProcessID: Int32? { get }
  func capture() -> TargetContext
}

/// Delivers a dictation's text into the app it started in.
///
/// If that app is still frontmost and its focused element accepted text:
/// save the pasteboard, write the text marked transient, post ⌘V, and restore
/// the saved items after 500 ms unless the pasteboard changed meanwhile.
/// Otherwise the text is copied. It never pastes into another app.
@MainActor
final class TextInserter: TextDelivering {
  static let restoreDelay = Duration.milliseconds(500)

  private let pasteboard: any PasteboardAccess
  private let poster: any PasteEventPoster
  private let focus: any FocusInspecting
  private let sleep: @Sendable (Duration) async -> Void
  private let log = Logger(subsystem: "com.ai.murmur", category: "insertion")

  init(
    pasteboard: any PasteboardAccess = SystemPasteboard(),
    poster: any PasteEventPoster = SystemPastePoster(),
    focus: any FocusInspecting = SystemFocus(),
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) {
    self.pasteboard = pasteboard
    self.poster = poster
    self.focus = focus
    self.sleep = sleep
  }

  func plannedDelivery(for target: TargetContext) -> Delivery {
    canPaste(into: target) ? .pasted : .copied
  }

  func deliver(_ text: String, planned: Delivery, target: TargetContext) async -> Delivery {
    guard planned == .pasted, canPaste(into: target) else {
      pasteboard.write(text, transient: false)
      return .copied
    }
    let saved = pasteboard.saveItems()
    pasteboard.write(text, transient: true)
    let written = pasteboard.changeCount
    guard poster.postPaste() else {
      log.error("could not post the paste; copied instead")
      return .copied
    }
    await sleep(Self.restoreDelay)
    if pasteboard.changeCount == written {
      pasteboard.restore(saved)
    } else {
      log.info("pasteboard changed meanwhile; not restored")
    }
    return .pasted
  }

  private func canPaste(into target: TargetContext) -> Bool {
    guard target.acceptsText, let pid = target.processID else { return false }
    return focus.frontmostProcessID == pid
  }
}

// MARK: System implementations

@MainActor
final class SystemPasteboard: PasteboardAccess {
  private let pasteboard = NSPasteboard.general
  static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

  var changeCount: Int { pasteboard.changeCount }

  func saveItems() -> [NSPasteboardItem] {
    (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
  }

  func restore(_ items: [NSPasteboardItem]) {
    pasteboard.clearContents()
    if !items.isEmpty { pasteboard.writeObjects(items) }
  }

  func write(_ text: String, transient: Bool) {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    if transient { item.setData(Data(), forType: Self.transientType) }
    pasteboard.writeObjects([item])
  }
}

@MainActor
struct SystemPastePoster: PasteEventPoster {
  func postPaste() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let source = CGEventSource(stateID: .combinedSessionState)
    let vKey: CGKeyCode = 9  // kVK_ANSI_V
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
    else { return false }
    down.flags = .maskCommand
    up.flags = .maskCommand
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
  }
}

@MainActor
struct SystemFocus: FocusInspecting {
  static let textRoles: Set<String> = [
    kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", "AXWebArea",
  ]

  var frontmostProcessID: Int32? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  func capture() -> TargetContext {
    let app = NSWorkspace.shared.frontmostApplication
    return TargetContext(
      bundleID: app?.bundleIdentifier, processID: app?.processIdentifier, acceptsText: focusedElementAcceptsText())
  }

  /// Whether the focused element takes text: a text role, a settable value,
  /// or a selected text range.
  func focusedElementAcceptsText() -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
      let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
    else { return false }
    let element = focused as! AXUIElement
    var role: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
      let role = role as? String, Self.textRoles.contains(role)
    {
      return true
    }
    var settable = DarwinBoolean(false)
    if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
      settable.boolValue
    {
      return true
    }
    var range: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
  }
}
