import AVFoundation
import AppKit
import ApplicationServices

/// The permissions and system settings Murmur depends on.
@MainActor
enum Permissions {
  enum Status: Equatable {
    case granted
    case notDetermined
    case denied
  }

  static var microphone: Status {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: .granted
    case .notDetermined: .notDetermined
    default: .denied
    }
  }

  /// Asks for the microphone, or opens System Settings once denied.
  static func requestMicrophone() async -> Bool {
    switch microphone {
    case .granted: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied:
      open(.microphone)
      return false
    }
  }

  static var accessibility: Bool { AXIsProcessTrusted() }

  /// Shows the system's Accessibility prompt, which links to System Settings.
  static func requestAccessibility() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) { open(.accessibility) }
  }

  /// Whether *Press 🌐 key to* is set to *Do Nothing*.
  static var globeKeyDoesNothing: Bool {
    UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") == 0
  }

  enum Pane: String {
    case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    case keyboard = "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
  }

  static func open(_ pane: Pane) {
    if let url = URL(string: pane.rawValue) { NSWorkspace.shared.open(url) }
  }
}
