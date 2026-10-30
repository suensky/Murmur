import AppKit
import MurmurKit
import ServiceManagement
import os

/// The app's state: settings, the library, the Zoom key, engine status.
@MainActor
@Observable
final class AppModel {
  let settings: MurmurSettings
  let store: any DictationStore
  let zoomKeys: any ZoomKeyStore
  private(set) var dictation: DictationController!

  /// Languages the Apple transcriber supports.
  private(set) var appleLanguages: [String] = [Language.fallback]
  private(set) var speechModel = SpeechModelStatus.notInstalled
  /// Download progress, 0 to 1, while a speech model installs.
  private(set) var speechModelProgress: Double?
  private(set) var polisher = PolisherAvailability.available
  private(set) var hasZoomKey: Bool
  private(set) var accessibilityGranted = Permissions.accessibility
  private(set) var recent: [Dictation] = []
  private(set) var storeError = false

  private let log = Logger(subsystem: "com.ai.murmur", category: "app")
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var pruneTimer: Timer?
  @ObservationIgnored private var accessibilityPoll: Timer?

  init() {
    settings = MurmurSettings()
    zoomKeys = KeychainZoomKeyStore()
    hasZoomKey = zoomKeys.hasKey
    let store: any DictationStore
    do {
      store = try LibraryStore()
    } catch {
      Logger(subsystem: "com.ai.murmur", category: "app").error("library unavailable; history off")
      store = UnavailableStore()
      storeError = true
    }
    self.store = store
    dictation = DictationController(model: self)
  }

  /// Runs once at launch.
  func start() async {
    observers.append(
      NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.reloadRecent() }
      })
    reloadRecent()
    prune()
    pruneTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.prune() }
    }
    accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshAccessibility() }
    }
    dictation.start()

    let supported = await AppleSpeech.supportedLanguages()
    if !supported.isEmpty { appleLanguages = supported }
    keepLanguageSupported()
    await refreshEngines()
  }

  /// The languages for the pickers: those of the engine in use.
  var languages: [String] {
    Language.supported(by: settings.effectiveEngine(zoomKeyStored: hasZoomKey), apple: appleLanguages)
  }

  func setEngine(_ engine: Engine) {
    settings.engine = engine
    keepLanguageSupported()
  }

  /// Moves the language into the engine's list when it is not there: the same
  /// language in another region, else en-US.
  private func keepLanguageSupported() {
    let languages = languages
    guard !languages.contains(settings.language) else { return }
    let current = settings.language == Language.auto ? Language.system : settings.language
    settings.language = Language.defaultLanguage(system: current, supported: languages)
    Task { await refreshEngines() }
  }

  func refreshAccessibility() {
    let granted = Permissions.accessibility
    guard granted != accessibilityGranted || (granted && !dictation.hotkeyRunning) else { return }
    accessibilityGranted = granted
    if granted { dictation.start() }
  }

  /// Re-reads the speech model's and the polisher's state for the language.
  func refreshEngines() async {
    let language = settings.language
    speechModel = await AppleSpeech.status(for: language)
    polisher = FoundationModelsGenerator().availability(for: language)
  }

  func setLanguage(_ language: String) {
    settings.language = language
    Task { await refreshEngines() }
  }

  func downloadSpeechModel(language: String? = nil) {
    let language = language ?? settings.language
    guard speechModelProgress == nil else { return }
    speechModelProgress = 0
    Task { [weak self] in
      do {
        try await AppleSpeech.install(language: language) { [weak self] value in
          Task { @MainActor in
            if self?.speechModelProgress != nil { self?.speechModelProgress = value }
          }
        }
      } catch {
        self?.log.error("speech model install failed: \((error as NSError).code, privacy: .public)")
      }
      self?.speechModelProgress = nil
      await self?.refreshEngines()
    }
  }

  // MARK: Zoom key

  /// Saves the key; false if it is not a valid key.
  func saveZoomKey(_ key: String) -> Bool {
    do {
      try zoomKeys.save(key)
    } catch {
      return false
    }
    hasZoomKey = true
    settings.zoomKeyRejected = false
    keepLanguageSupported()
    return true
  }

  /// Removing the key resets the default engine to Apple.
  func removeZoomKey() {
    try? zoomKeys.delete()
    hasZoomKey = zoomKeys.hasKey
    settings.zoomKeyRejected = false
    setEngine(.apple)
  }

  // MARK: Library

  func reloadRecent() {
    recent = (try? store.recent(limit: 3)) ?? []
  }

  func prune() {
    guard let cutoff = settings.retention.cutoff(now: Date()) else { return }
    _ = try? store.prune(before: cutoff)
  }

  /// Runs the polishing chain again on the raw text and updates the row.
  func repolish(_ dictation: Dictation) async -> Dictation {
    let polishers: [any Polisher] = [ApplePolisher(), BasicCleanup()]
    let outcome = await PolishChain(polishers).run(raw: dictation.rawText, language: dictation.language)
    try? store.updatePolish(id: dictation.id, outcome: outcome)
    var updated = dictation
    updated.polishedText = outcome.text
    updated.polisher = outcome.polisher
    updated.unpolishedReason = outcome.unpolishedReason
    return updated
  }

  func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: Login item

  var opensAtLogin: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      do {
        if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {
        log.error("login item: \((error as NSError).code, privacy: .public)")
      }
    }
  }
}

/// Stands in when `library.db` cannot be opened: dictation still works.
private struct UnavailableStore: DictationStore {
  struct Unavailable: Error {}

  func save(_ dictation: Dictation) throws { throw Unavailable() }
  func updateDelivery(id: UUID, to delivery: Delivery) throws { throw Unavailable() }
  func updatePolish(id: UUID, outcome: PolishOutcome) throws { throw Unavailable() }
  func delete(id: UUID) throws { throw Unavailable() }
  func deleteAll() throws { throw Unavailable() }
  func recent(limit: Int) throws -> [Dictation] { [] }
  func search(_ query: String, limit: Int) throws -> [Dictation] { [] }
  func prune(before cutoff: Date) throws -> Int { 0 }
}
