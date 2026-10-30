import AppKit
import MurmurKit
import SwiftUI

/// Dictations newest first, with full-text search, copy, re-polish and delete.
struct HistoryView: View {
  @Environment(AppModel.self) private var model
  @State private var dictations: [Dictation] = []
  @State private var selection: Dictation.ID?
  @State private var query = ""
  @State private var showsRaw = false
  @State private var showsInfo = false
  @State private var confirmsDelete = false
  @State private var confirmsDeleteAll = false
  @State private var repolishing = false

  private var selected: Dictation? {
    dictations.first { $0.id == selection }
  }

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
    } detail: {
      detail
    }
    .navigationTitle("History")
    .searchable(text: $query, placement: .toolbar, prompt: "Search")
    .toolbar { toolbar }
    .task(id: query) { reload() }
    .onReceive(NotificationCenter.default.publisher(for: LibraryStore.didChange)) { _ in reload() }
    .confirmationDialog("Delete this dictation?", isPresented: $confirmsDelete) {
      Button("Delete", role: .destructive) { deleteSelected() }
    } message: {
      Text("It is removed from History for good.")
    }
    .confirmationDialog("Delete all dictations?", isPresented: $confirmsDeleteAll) {
      Button("Delete All", role: .destructive) { try? model.store.deleteAll() }
    } message: {
      Text("Every dictation is removed from History for good.")
    }
    .frame(minWidth: 760, minHeight: 460)
  }

  // MARK: Sidebar

  private var sidebar: some View {
    List(selection: $selection) {
      ForEach(Self.days(dictations), id: \.title) { day in
        Section(day.title) {
          ForEach(day.items) { dictation in
            HistoryRow(dictation: dictation)
              .tag(dictation.id)
              .contextMenu {
                Button("Copy") { model.copy(dictation.text) }
                Button("Copy Raw") { model.copy(dictation.rawText) }
                Divider()
                Button("Delete…", role: .destructive) {
                  selection = dictation.id
                  confirmsDelete = true
                }
              }
          }
        }
      }
    }
    .overlay {
      if dictations.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "No Dictations" : "No Results",
          systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
          description: Text(query.isEmpty ? "Hold \(Self.triggerName(model.settings.triggerKey)) and talk." : ""))
      }
    }
    .safeAreaInset(edge: .bottom) {
      if !dictations.isEmpty && query.isEmpty {
        HStack {
          Spacer()
          Button("Delete All…") { confirmsDeleteAll = true }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(10)
      }
    }
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    if let dictation = selected {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text(Self.header(for: dictation))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
          if !dictation.isPolished && !showsRaw {
            Label(Self.notPolishedText(dictation.unpolishedReason), systemImage: "exclamationmark.circle")
              .font(.callout)
              .foregroundStyle(.orange)
          }
          Text(showsRaw ? dictation.rawText : dictation.text)
            .font(.system(size: 17))
            .lineSpacing(6)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 80)
        .padding(.vertical, 28)
      }
      .popover(isPresented: $showsInfo, arrowEdge: .bottom) { DictationInfo(dictation: dictation) }
    } else {
      ContentUnavailableView("Select a Dictation", systemImage: "text.quote")
    }
  }

  @ToolbarContentBuilder private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Picker("Text", selection: $showsRaw) {
        Text("Polished").tag(false)
        Text("Raw").tag(true)
      }
      .pickerStyle(.segmented)
      .fixedSize()
      .help("Show the polished or the raw text")

      Button("Copy", systemImage: "doc.on.doc") {
        if let selected { model.copy(showsRaw ? selected.rawText : selected.text) }
      }
      .help("Copy")
      .disabled(selected == nil)

      Button("Re-polish", systemImage: "arrow.clockwise") { repolishSelected() }
        .help("Polish the raw text again")
        .disabled(selected == nil || repolishing)

      Button("Info", systemImage: "info.circle") { showsInfo.toggle() }
        .help("Details")
        .disabled(selected == nil)

      Button("Delete", systemImage: "trash") { confirmsDelete = true }
        .help("Delete")
        .disabled(selected == nil)
    }
  }

  // MARK: Actions

  private func reload() {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    dictations =
      (try? trimmed.isEmpty ? model.store.recent(limit: 1_000) : model.store.search(trimmed, limit: 500)) ?? []
    if selection == nil || !dictations.contains(where: { $0.id == selection }) {
      selection = dictations.first?.id
    }
  }

  private func deleteSelected() {
    guard let selection else { return }
    try? model.store.delete(id: selection)
  }

  private func repolishSelected() {
    guard let selected else { return }
    repolishing = true
    Task {
      _ = await model.repolish(selected)
      repolishing = false
      reload()
    }
  }

  // MARK: Formatting

  struct Day {
    let title: String
    let items: [Dictation]
  }

  static func days(_ dictations: [Dictation], calendar: Calendar = .current) -> [Day] {
    var days: [Day] = []
    for dictation in dictations {
      let title = dayTitle(dictation.createdAt, calendar: calendar)
      if days.last?.title == title {
        days[days.count - 1] = Day(title: title, items: days[days.count - 1].items + [dictation])
      } else {
        days.append(Day(title: title, items: [dictation]))
      }
    }
    return days
  }

  static func dayTitle(_ date: Date, calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).month().day())
  }

  static func header(for dictation: Dictation) -> String {
    let day = dayTitle(dictation.createdAt)
    let time = dictation.createdAt.formatted(date: .omitted, time: .shortened)
    let when = day == "Today" || day == "Yesterday" ? "\(day) at \(time)" : "\(day), \(time)"
    guard let app = appName(dictation.targetApp) else { return when }
    return "\(when) in \(app)"
  }

  static func appName(_ bundleID: String?) -> String? {
    guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return nil
    }
    return FileManager.default.displayName(atPath: url.path).replacing(/\.app$/, with: "")
  }

  /// *Not polished* and why, from the stored reason code.
  static func notPolishedText(_ reason: String?) -> String {
    guard let reason else { return "Not polished" }
    let why: String =
      if reason.contains("apple-intelligence-off") {
        "Apple Intelligence is off"
      } else if reason.contains("device-not-eligible") {
        "this Mac can't run Apple Intelligence"
      } else if reason.contains("model-not-ready") {
        "the on-device model isn't ready"
      } else if reason.contains("unavailable:language") {
        "the language isn't supported"
      } else if reason.contains("timed-out") { "polishing took too long" } else if reason.contains("refused") {
        "the model declined"
      } else if reason.contains("rejected") { "the result didn't match what was said" } else { "polishing failed" }
    return "Not polished: \(why)"
  }

  static func triggerName(_ key: TriggerKey) -> String {
    switch key {
    case .fn: "fn"
    case .rightOption: "Right ⌥"
    case .rightCommand: "Right ⌘"
    }
  }
}

private struct HistoryRow: View {
  let dictation: Dictation

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(dictation.text)
        .lineLimit(2)
      HStack(spacing: 4) {
        Text(dictation.createdAt, format: .dateTime.hour().minute())
        if let app = HistoryView.appName(dictation.targetApp) { Text(app) }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

private struct DictationInfo: View {
  let dictation: Dictation

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
      row("Duration", Duration.milliseconds(dictation.durationMs).formatted(.units(allowed: [.minutes, .seconds])))
      row("Language", Language.displayName(for: dictation.language))
      row("Transcribed by", dictation.transcriber == .apple ? "This Mac" : "Zoom")
      row("Polished by", Self.polisherName(dictation.polisher))
      row("Delivered", dictation.delivery == .pasted ? "Pasted" : "Copied")
      if !dictation.isPolished {
        row("Note", HistoryView.notPolishedText(dictation.unpolishedReason))
      }
    }
    .font(.callout)
    .padding(16)
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value)
    }
  }

  static func polisherName(_ kind: PolisherKind) -> String {
    switch kind {
    case .zoom: "Zoom"
    case .apple: "Apple Intelligence"
    case .basic: "Basic cleanup"
    case .none: "Nothing"
    }
  }
}
