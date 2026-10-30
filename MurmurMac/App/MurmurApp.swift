import AppKit
import MurmurKit
import SwiftUI

/// Murmur: a menu bar agent (LSUIElement). Hold the trigger key, talk, and
/// polished text lands where the cursor is.
@main
struct MurmurApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuContent()
        .environment(delegate.model)
    } label: {
      Image(nsImage: MenuBarIcon.image(attention: !delegate.model.accessibilityGranted))
        .accessibilityLabel("Murmur")
    }
    .menuBarExtraStyle(.menu)

    Window("History", id: WindowID.history) {
      HistoryView()
        .environment(delegate.model)
    }
    .defaultSize(width: 1_080, height: 680)

    Window("Welcome to Murmur", id: WindowID.onboarding) {
      OnboardingView()
        .environment(delegate.model)
        .onAppear { NSApp.activate() }
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .defaultLaunchBehavior(AppDelegate.needsOnboarding(delegate.model) ? .presented : .suppressed)

    Settings {
      SettingsView()
        .environment(delegate.model)
    }
    .windowResizability(.contentSize)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let model = AppModel()

  /// Under XCTest the app is only a test host: no hotkey, no windows.
  static var isTestHost: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !Self.isTestHost else { return }
    Task { await model.start() }
  }

  /// Onboarding opens at launch until it is done and both permissions are granted.
  static func needsOnboarding(_ model: AppModel) -> Bool {
    !isTestHost
      && (!model.settings.hasOnboarded || !Permissions.accessibility || Permissions.microphone != .granted)
  }
}
