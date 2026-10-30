import MurmurKit
import SwiftUI

/// Murmur Settings, as in the design's Settings board.
struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var keyDraft = ""
  @State private var keyInvalid = false
  @State private var showsShortcutHelp = false
  @State private var opensAtLogin = false

  var body: some View {
    @Bindable var settings = model.settings
    Form {
      Section {
        LabeledContent {
          Picker("Shortcut", selection: $settings.triggerKey) {
            ForEach(TriggerKey.allCases) { Text(HistoryView.triggerName($0)).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        } label: {
          HStack(spacing: 6) {
            Text("Shortcut")
            Button("About the shortcut", systemImage: "info.circle") { showsShortcutHelp.toggle() }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .foregroundStyle(.secondary)
              .popover(isPresented: $showsShortcutHelp) { shortcutHelp }
          }
        }
        .onChange(of: settings.triggerKey) { model.dictation.triggerKeyChanged() }

        Picker("Language", selection: Binding(get: { settings.language }, set: { model.setLanguage($0) })) {
          ForEach(model.languages, id: \.self) { Text(Language.displayName(for: $0)).tag($0) }
        }
      }

      Section {
        Picker("Transcribe with", selection: Binding(get: { settings.engine }, set: { model.setEngine($0) })) {
          Text("This Mac").tag(Engine.apple)
          Text("Zoom").tag(Engine.zoom).disabled(!model.hasZoomKey)
        }
        if settings.engine == .zoom && model.hasZoomKey {
          Text("Your audio is sent to Zoom for transcription.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }

        LabeledContent("Zoom API key") {
          HStack {
            if model.hasZoomKey {
              if settings.zoomKeyRejected {
                Text("Key rejected").foregroundStyle(.red)
              }
              SecureField("API key", text: .constant("••••••••••••••••••••••••"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .disabled(true)
                .frame(width: 170)
              Button("Remove") { model.removeZoomKey() }
            } else {
              SecureField("Zoom API key", text: $keyDraft, prompt: Text("Paste your API key"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .onSubmit(saveKey)
              Button("Save", action: saveKey).disabled(keyDraft.isEmpty)
            }
          }
        }
        if keyInvalid {
          Text("A key has no spaces and is at most 512 characters.")
            .font(.callout)
            .foregroundStyle(.red)
        }

        LabeledContent("Polishing") { polishingStatus }
        // The on-device speech model has nothing to stand in for with auto-detect.
        if settings.language != Language.auto {
          LabeledContent("Speech model") { speechModelStatus }
        }
      }

      Section {
        Picker("Keep history", selection: $settings.retention) {
          Text("Forever").tag(Retention.forever)
          Text("30 days").tag(Retention.days30)
          Text("7 days").tag(Retention.days7)
        }
        .onChange(of: settings.retention) { model.prune() }

        Toggle("Open at login", isOn: $opensAtLogin)
          .onChange(of: opensAtLogin) { _, value in model.opensAtLogin = value }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear {
      opensAtLogin = model.opensAtLogin
      Task { await model.refreshEngines() }
    }
  }

  private func saveKey() {
    keyInvalid = !model.saveZoomKey(keyDraft)
    if !keyInvalid { keyDraft = "" }
  }

  private var shortcutHelp: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Hold to talk; release to insert.")
      Text("Double-tap for hands-free; tap again to finish. Esc cancels.")
      if model.settings.triggerKey == .fn && !Permissions.globeKeyDoesNothing {
        Divider()
        Text("Set *Press 🌐 key to* to *Do Nothing*, or fn also opens the emoji picker.")
        Button("Open Keyboard Settings…") { Permissions.open(.keyboard) }
      }
    }
    .font(.callout)
    .padding(14)
    .frame(width: 300, alignment: .leading)
  }

  @ViewBuilder private var polishingStatus: some View {
    switch model.polisher {
    case .available:
      StatusDot(color: .green, text: "On")
    case .unavailable(let reason):
      StatusDot(color: .orange, text: "Unavailable, \(Self.polisherReason(reason))")
    }
  }

  @ViewBuilder private var speechModelStatus: some View {
    if let progress = model.speechModelProgress {
      ProgressView(value: progress).frame(width: 120)
    } else {
      switch model.speechModel {
      case .installed:
        StatusDot(color: .green, text: "Installed")
      case .downloading:
        StatusDot(color: .orange, text: "Downloading…")
      case .notInstalled:
        HStack {
          StatusDot(color: .orange, text: "Not installed")
          Button("Download") { model.downloadSpeechModel() }
        }
      case .unsupported:
        StatusDot(color: .red, text: "Not available")
      }
    }
  }

  static func polisherReason(_ reason: String) -> String {
    switch reason {
    case "apple-intelligence-off": "Apple Intelligence is off"
    case "device-not-eligible": "this Mac can't run it"
    case "model-not-ready": "the model is still downloading"
    case "language": "not for this language"
    default: "unknown reason"
    }
  }
}

struct StatusDot: View {
  let color: Color
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text).foregroundStyle(.secondary)
    }
  }
}
