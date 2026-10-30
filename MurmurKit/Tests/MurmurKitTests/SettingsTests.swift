import Foundation
import Testing

@testable import MurmurKit

@MainActor
@Suite("Settings")
struct SettingsTests {
  func freshDefaults() -> UserDefaults {
    let name = "murmur-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func defaultsMatchTheSpec() {
    let settings = MurmurSettings(defaults: freshDefaults(), systemLanguage: "fr-FR")
    #expect(settings.engine == .apple)
    #expect(settings.language == "fr-FR")
    #expect(settings.triggerKey == .fn)
    #expect(settings.retention == .forever)
    #expect(!settings.hasOnboarded)
    #expect(!settings.zoomKeyRejected)
  }

  @Test func changesPersist() {
    let defaults = freshDefaults()
    let settings = MurmurSettings(defaults: defaults)
    settings.engine = .zoom
    settings.language = "ja-JP"
    settings.triggerKey = .rightOption
    settings.retention = .days7
    settings.hasOnboarded = true
    settings.zoomKeyRejected = true
    let reloaded = MurmurSettings(defaults: defaults)
    #expect(reloaded.engine == .zoom)
    #expect(reloaded.language == "ja-JP")
    #expect(reloaded.triggerKey == .rightOption)
    #expect(reloaded.retention == .days7)
    #expect(reloaded.hasOnboarded)
    #expect(reloaded.zoomKeyRejected)
  }

  @Test func zoomNeedsAKey() {
    let settings = MurmurSettings(defaults: freshDefaults())
    settings.engine = .zoom
    #expect(settings.effectiveEngine(zoomKeyStored: false) == .apple)
    #expect(settings.effectiveEngine(zoomKeyStored: true) == .zoom)
  }

  @Test func retentionCutoffs() {
    let now = Date(timeIntervalSince1970: 10_000_000)
    #expect(Retention.forever.cutoff(now: now) == nil)
    #expect(Retention.days7.cutoff(now: now) == now.addingTimeInterval(-604_800))
    #expect(Retention.days30.cutoff(now: now) == now.addingTimeInterval(-2_592_000))
  }

  @Test func defaultLanguage() {
    let supported = ["en-GB", "en-US", "fr-CA", "fr-FR", "ja-JP"]
    #expect(Language.defaultLanguage(system: "ja-JP", supported: supported) == "ja-JP")
    #expect(Language.defaultLanguage(system: "fr-BE", supported: supported) == "fr-CA")
    #expect(Language.defaultLanguage(system: "xx-YY", supported: supported) == "en-US")
    #expect(Language.normalize("en_US") == "en-US")
    #expect(Language.isUSEnglish("en_US"))
    #expect(!Language.isUSEnglish("en-GB"))
  }

  @Test func languagesFollowTheEngine() {
    let apple = ["en-GB", "en-US"]
    #expect(Language.supported(by: .apple, apple: apple) == apple)
    let zoom = Language.supported(by: .zoom, apple: apple)
    #expect(zoom.count == 39)
    #expect(zoom.first == Language.auto)
    #expect(Language.displayName(for: Language.auto) == "Auto-detect")
    #expect(!Language.isUSEnglish(Language.auto))
    #expect(zoom.contains("en-US") && zoom.contains("vi-VN") && !zoom.contains("en-GB"))
    #expect(Language.defaultLanguage(system: "en-GB", supported: zoom) == "en-US")
  }

  @Test func mostCommonLanguage() {
    #expect(Language.mostCommon([]) == nil)
    #expect(Language.mostCommon(["fr", "en", "en"]) == "en")
    #expect(Language.mostCommon(["fr", "en"]) == "fr")
  }

  @Test func displayNames() {
    let english = Locale(identifier: "en-US")
    #expect(Language.displayName(for: "en-US", in: english) == "English (US)")
    #expect(Language.displayName(for: "ja-JP", in: english) == "Japanese (Japan)")
    #expect(Language.displayName(for: "fr", in: english) == "French")
  }
}

@Suite("Zoom key")
struct ZoomKeyTests {
  @Test(arguments: [
    ("  abc123  ", "abc123"),
    ("", nil),
    ("   ", nil),
    ("has space", nil),
    ("tab\there", nil),
    (String(repeating: "k", count: 512), String(repeating: "k", count: 512)),
    (String(repeating: "k", count: 513), nil),
  ])
  func normalizes(input: String, expected: String?) {
    #expect(ZoomKey.normalize(input) == expected)
  }

  @Test func inMemoryStore() throws {
    let store = InMemoryZoomKeyStore()
    #expect(!store.hasKey)
    #expect(throws: ZoomKeyError.invalid) { try store.save("bad key") }
    try store.save(" good ")
    #expect(store.read() == "good")
    try store.delete()
    #expect(store.read() == nil)
  }

  @Test func environmentOverridesTheKeychain() {
    let store = KeychainZoomKeyStore(environment: ["ZOOM_API_KEY": " dev-key "])
    #expect(store.read() == "dev-key")
  }
}

@Suite("Keychain", .serialized)
struct KeychainTests {
  /// A service of its own, so the user's real key is never touched.
  let store = KeychainZoomKeyStore(environment: [:], service: "com.ai.murmur.tests.\(UUID().uuidString)")

  @Test func savesReplacesAndDeletes() throws {
    defer { try? store.delete() }
    #expect(store.read() == nil)
    try store.save("  first-key ")
    #expect(store.read() == "first-key")
    try store.save("second-key")
    #expect(store.read() == "second-key")
    #expect(throws: ZoomKeyError.invalid) { try store.save("not valid") }
    try store.delete()
    #expect(store.read() == nil)
    // Deleting a missing item is fine.
    try store.delete()
  }
}
