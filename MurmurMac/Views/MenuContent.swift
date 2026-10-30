import AppKit
import MurmurKit
import SwiftUI

enum WindowID {
  static let history = "history"
  static let onboarding = "onboarding"
}

/// The menu bar menu, as in the design's Menu bar board.
struct MenuContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    @Bindable var settings = model.settings
    if !model.accessibilityGranted {
      Button("Allow Accessibility…", systemImage: "exclamationmark.circle.fill") {
        Permissions.requestAccessibility()
      }
      Divider()
    }

    Button(model.dictation.session == nil ? "Start Dictation" : "Finish Dictation") {
      model.dictation.toggleFromMenu()
    }
    Divider()

    Picker("Engine", selection: Binding(get: { settings.engine }, set: { model.setEngine($0) })) {
      Text("On Device").tag(Engine.apple)
      Text("Zoom").tag(Engine.zoom).disabled(!model.hasZoomKey)
    }
    Picker("Language", selection: Binding(get: { settings.language }, set: { model.setLanguage($0) })) {
      ForEach(model.languages, id: \.self) { Text(Language.displayName(for: $0)).tag($0) }
    }
    Divider()

    if !model.recent.isEmpty {
      Section("Recent") {
        ForEach(model.recent) { dictation in
          Button(Self.preview(dictation.text)) { model.copy(dictation.text) }
        }
      }
    }
    Button("Show All…") { show(WindowID.history) }
    Divider()

    SettingsLink { Text("Settings…") }
      .keyboardShortcut(",")
    Button("Quit Murmur") { NSApp.terminate(nil) }
      .keyboardShortcut("q")
  }

  private func show(_ id: String) {
    NSApp.activate()
    openWindow(id: id)
  }

  static func preview(_ text: String) -> String {
    let line = text.replacingOccurrences(of: "\n", with: " ")
    return line.count > 40 ? String(line.prefix(40)) + "…" : line
  }
}

/// The menu bar glyph: a speech bubble with a wave, drawn as a template image;
/// an orange dot marks missing Accessibility.
enum MenuBarIcon {
  static func image(attention: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: true) { _ in
      NSColor.black.setStroke()
      let bubble = NSBezierPath(ovalIn: NSRect(x: 2, y: 2.5, width: 14, height: 11.5))
      bubble.lineWidth = 1.5
      bubble.stroke()
      let tail = NSBezierPath()
      tail.move(to: NSPoint(x: 4.6, y: 12.2))
      tail.line(to: NSPoint(x: 3.6, y: 16))
      tail.line(to: NSPoint(x: 7.6, y: 13.6))
      tail.lineWidth = 1.5
      tail.lineJoinStyle = .round
      tail.stroke()
      let wave = NSBezierPath()
      wave.move(to: NSPoint(x: 5.2, y: 8.6))
      wave.curve(
        to: NSPoint(x: 8.2, y: 8.4), controlPoint1: NSPoint(x: 6.2, y: 5.4), controlPoint2: NSPoint(x: 7.4, y: 5.6))
      wave.curve(
        to: NSPoint(x: 11.4, y: 7.6), controlPoint1: NSPoint(x: 9, y: 11.2), controlPoint2: NSPoint(x: 10.6, y: 11))
      wave.lineWidth = 1.5
      wave.lineCapStyle = .round
      wave.stroke()
      NSBezierPath(ovalIn: NSRect(x: 11.9, y: 6.7, width: 1.9, height: 1.9)).fill()
      if attention {
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: NSRect(x: 12.5, y: 0, width: 5.5, height: 5.5)).fill()
      }
      return true
    }
    image.isTemplate = !attention
    return image
  }
}
