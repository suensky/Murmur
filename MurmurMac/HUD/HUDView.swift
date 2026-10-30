import MurmurKit
import SwiftUI

/// The pill's contents for each state, as in the design's HUD board.
struct HUDView: View {
  let model: HUDModel

  var body: some View {
    VStack {
      Spacer(minLength: 0)
      if let session = model.session {
        SessionPill(session: session, handsFree: model.handsFree, onStop: model.onStop)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      } else if let message = model.message {
        MessagePill(message: message, model: model)
          .transition(.opacity)
      }
    }
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.snappy(duration: 0.2), value: model.session == nil)
    .animation(.snappy(duration: 0.2), value: model.message)
  }
}

private enum Pill {
  static let background = Color(white: 0.15)
  static let dimText = Color(white: 0.56)
  static let warning = Color(red: 1.0, green: 0.62, blue: 0.04)
  static let failure = Color(red: 1.0, green: 0.27, blue: 0.23)
}

private struct PillShape<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    HStack(spacing: 12) { content }
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .frame(minHeight: 46)
      .background(Capsule().fill(Pill.background))
      .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
      .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct SessionPill: View {
  let session: DictationSession
  let handsFree: Bool
  let onStop: () -> Void

  var body: some View {
    PillShape {
      switch session.phase {
      case .finishing, .polishing, .done:
        ProgressView().controlSize(.small).tint(.white)
        Text("Polishing…")
      case .starting, .recording:
        recording
      }
    }
    .frame(maxWidth: 560)
  }

  @ViewBuilder private var recording: some View {
    LevelBars(level: session.level, active: session.phase == .recording)
    liveText
      .lineLimit(2)
      .truncationMode(.head)
      .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
    if session.notice == .zoomUnavailable {
      Text("On device").font(.system(size: 13, weight: .medium)).foregroundStyle(Pill.warning)
    } else {
      Text(Self.format(session.recorded))
        .font(.system(size: 13, weight: session.nearingLimit ? .semibold : .regular).monospacedDigit())
        .foregroundStyle(session.nearingLimit ? Pill.warning : Pill.dimText)
    }
    if handsFree {
      Button(action: onStop) {
        ZStack {
          Circle().fill(.white).frame(width: 30, height: 30)
          RoundedRectangle(cornerRadius: 2.5).fill(Pill.failure).frame(width: 11, height: 11)
        }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop dictation")
      .padding(.trailing, -8)
    }
  }

  private var liveText: Text {
    let committed = session.committedText
    let draft = session.draft.trimmingCharacters(in: .whitespaces)
    if committed.isEmpty && draft.isEmpty {
      return Text("Listening…").foregroundStyle(Pill.dimText)
    }
    let separator = committed.isEmpty || draft.isEmpty ? "" : " "
    return Text("\(committed)\(Text(separator + draft).foregroundStyle(Pill.dimText))")
  }

  static func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

private struct MessagePill: View {
  let message: HUDMessage
  let model: HUDModel

  var body: some View {
    PillShape {
      switch message {
      case .copied:
        Text("Copied")
        HStack(spacing: 4) {
          KeyCap("⌘")
          KeyCap("V")
        }
        .padding(.trailing, -6)
      case .couldntTranscribe:
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, Pill.failure)
        Text("Couldn't transcribe")
      case .couldntSave:
        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.black, Pill.warning)
        Text("Couldn't save to history")
      case .speechModelNeeded(let language):
        Text("\(Self.languageName(language)) speech model needed")
        CapsuleButton("Download") { model.onDownload(language) }
      case .microphoneNeeded:
        Text("Murmur needs the microphone")
        CapsuleButton("Allow", action: model.onAllowMicrophone)
      }
    }
  }

  /// "Japanese" rather than "Japanese (Japan)".
  static func languageName(_ tag: String) -> String {
    let code = Locale(identifier: tag).language.languageCode?.identifier ?? tag
    return Locale.current.localizedString(forLanguageCode: code) ?? tag
  }
}

private struct KeyCap: View {
  let label: String
  init(_ label: String) { self.label = label }

  var body: some View {
    Text(label)
      .font(.system(size: 12, weight: .semibold))
      .frame(minWidth: 24, minHeight: 24)
      .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.16)))
  }
}

private struct CapsuleButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.black)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(.white))
    }
    .buttonStyle(.plain)
    .padding(.trailing, -10)
  }
}

/// Five bars that follow the input level.
struct LevelBars: View {
  let level: Float
  var active = true
  private static let shape: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.4]

  var body: some View {
    HStack(spacing: 2.5) {
      ForEach(Self.shape.indices, id: \.self) { index in
        Capsule()
          .fill(.white)
          .frame(width: 3, height: height(for: index))
      }
    }
    .frame(width: 26, height: 22)
    .animation(.easeOut(duration: 0.12), value: level)
    .accessibilityHidden(true)
  }

  private func height(for index: Int) -> CGFloat {
    let floor: CGFloat = 5
    let gain = active ? CGFloat(max(level, 0.15)) : 0.15
    return floor + (22 - floor) * Self.shape[index] * gain
  }
}
