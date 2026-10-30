import AppKit
import Combine
import MurmurKit
import SwiftUI

/// The first-run checklist, as in the design's Onboarding board.
///
/// Speech Recognition authorization is not asked for: `SpeechAnalyzer` was
/// verified to transcribe without it.
struct OnboardingView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var microphone = Permissions.microphone
  @State private var globeDoesNothing = Permissions.globeKeyDoesNothing
  private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 24) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .frame(width: 96, height: 96)
      Text("Welcome to Murmur")
        .font(.system(size: 22, weight: .bold))

      VStack(spacing: 0) {
        StepRow(icon: "mic.fill", color: .orange, title: "Microphone") {
          if microphone == .granted {
            Done()
          } else {
            Button(microphone == .denied ? "Open Settings…" : "Allow") {
              Task {
                _ = await Permissions.requestMicrophone()
                microphone = Permissions.microphone
              }
            }
          }
        }
        Divider().padding(.leading, 50)
        StepRow(icon: "accessibility", color: .blue, title: "Accessibility") {
          if model.accessibilityGranted {
            Done()
          } else {
            Button("Open Settings…") { Permissions.requestAccessibility() }
          }
        }
        Divider().padding(.leading, 50)
        StepRow(
          icon: "arrow.down", color: .green,
          title: "\(Language.displayName(for: model.settings.language)) speech model"
        ) {
          if let progress = model.speechModelProgress {
            ProgressView(value: progress).frame(width: 90)
          } else if model.speechModel == .installed {
            Done()
          } else if model.speechModel == .unsupported {
            Text("Not available").foregroundStyle(.secondary)
          } else {
            Button("Download") { model.downloadSpeechModel() }
          }
        }
        if model.settings.triggerKey == .fn {
          Divider().padding(.leading, 50)
          StepRow(icon: "globe", color: .indigo, title: "Globe key set to Do Nothing") {
            if globeDoesNothing {
              Done()
            } else {
              Button("Use Right ⌥") {
                model.settings.triggerKey = .rightOption; model.dictation.triggerKeyChanged()
              }
              .buttonStyle(.borderless)
              Button("Open Settings…") { Permissions.open(.keyboard) }
            }
          }
        }
      }
      .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))

      HStack {
        Spacer()
        Button("Done") {
          model.settings.hasOnboarded = true
          dismissWindow(id: WindowID.onboarding)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
      }
    }
    .padding(.horizontal, 32)
    .padding(.top, 20)
    .padding(.bottom, 28)
    .frame(width: 500)
    .onReceive(poll) { _ in
      microphone = Permissions.microphone
      globeDoesNothing = Permissions.globeKeyDoesNothing
      model.refreshAccessibility()
    }
    .task { await model.refreshEngines() }
  }
}

private struct StepRow<Trailing: View>: View {
  let icon: String
  let color: Color
  let title: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(color))
      Text(title)
      Spacer()
      trailing
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 52)
  }
}

private struct Done: View {
  var body: some View {
    Image(systemName: "checkmark.circle.fill")
      .font(.system(size: 17))
      .foregroundStyle(.white, .green)
      .accessibilityLabel("Done")
  }
}
