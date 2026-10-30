import AppKit
import MurmurKit
import SwiftUI

/// A message the pill shows after a dictation, or instead of one.
enum HUDMessage: Equatable {
  /// Couldn't paste here; the text is on the clipboard.
  case copied
  case couldntTranscribe
  /// Inserted, not saved.
  case couldntSave
  case speechModelNeeded(language: String)
  case microphoneNeeded

  /// How long it stays up; messages with a button stay longer.
  var duration: Duration {
    switch self {
    case .speechModelNeeded, .microphoneNeeded: .seconds(6)
    default: .milliseconds(2_500)
    }
  }
}

@MainActor
@Observable
final class HUDModel {
  var session: DictationSession?
  var handsFree = false
  var message: HUDMessage?
  var onStop: () -> Void = {}
  var onDownload: (String) -> Void = { _ in }
  var onAllowMicrophone: () -> Void = {}
}

/// The floating pill: a non-activating panel hosting SwiftUI, at the bottom
/// center of the screen with the pointer.
@MainActor
final class HUDController {
  let model = HUDModel()
  private let panel: HUDPanel
  private var hideTask: Task<Void, Never>?

  init() {
    panel = HUDPanel(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 140),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: true)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    let host = NSHostingView(rootView: HUDView(model: model))
    host.sizingOptions = []
    panel.contentView = host
  }

  func show(_ session: DictationSession, handsFree: Bool) {
    hideTask?.cancel()
    model.message = nil
    model.session = session
    model.handsFree = handsFree
    present()
  }

  func show(_ message: HUDMessage) {
    hideTask?.cancel()
    model.session = nil
    model.message = message
    present()
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: message.duration)
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  func hide() {
    hideTask?.cancel()
    model.session = nil
    model.message = nil
    panel.orderOut(nil)
  }

  private func present() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    panel.orderFrontRegardless()
  }
}

/// Never takes focus from the app being dictated into.
final class HUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
