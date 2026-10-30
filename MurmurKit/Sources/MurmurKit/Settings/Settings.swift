import Foundation
import Observation

/// The engine a dictation uses by default.
public enum Engine: String, Sendable, CaseIterable, Identifiable {
  case apple
  case zoom

  public var id: String { rawValue }
}

/// The key that drives dictation.
public enum TriggerKey: String, Sendable, CaseIterable, Identifiable {
  case fn
  case rightOption
  case rightCommand

  public var id: String { rawValue }
}

/// How long dictations are kept.
public enum Retention: String, Sendable, CaseIterable, Identifiable {
  case forever
  case days30
  case days7

  public var id: String { rawValue }

  /// The cutoff before which dictations are pruned, or `nil` to keep all.
  public func cutoff(now: Date) -> Date? {
    switch self {
    case .forever: nil
    case .days30: now.addingTimeInterval(-30 * 86_400)
    case .days7: now.addingTimeInterval(-7 * 86_400)
    }
  }
}

/// The user's settings, kept in `UserDefaults`.
@MainActor
@Observable
public final class MurmurSettings {
  enum Key {
    static let engine = "engine"
    static let language = "language"
    static let triggerKey = "triggerKey"
    static let retention = "retention"
    static let onboarded = "onboarded"
    static let zoomKeyRejected = "zoomKeyRejected"
  }

  @ObservationIgnored private let defaults: UserDefaults

  public var engine: Engine {
    didSet { defaults.set(engine.rawValue, forKey: Key.engine) }
  }
  /// BCP-47; one of the locales the engine supports.
  public var language: String {
    didSet { defaults.set(language, forKey: Key.language) }
  }
  public var triggerKey: TriggerKey {
    didSet { defaults.set(triggerKey.rawValue, forKey: Key.triggerKey) }
  }
  public var retention: Retention {
    didSet { defaults.set(retention.rawValue, forKey: Key.retention) }
  }
  public var hasOnboarded: Bool {
    didSet { defaults.set(hasOnboarded, forKey: Key.onboarded) }
  }
  /// Set when Zoom answered 401 or 403; cleared when a key is saved.
  public var zoomKeyRejected: Bool {
    didSet { defaults.set(zoomKeyRejected, forKey: Key.zoomKeyRejected) }
  }

  public init(defaults: UserDefaults = .standard, systemLanguage: String = Language.system) {
    self.defaults = defaults
    engine = defaults.string(forKey: Key.engine).flatMap(Engine.init) ?? .apple
    language = defaults.string(forKey: Key.language) ?? systemLanguage
    triggerKey = defaults.string(forKey: Key.triggerKey).flatMap(TriggerKey.init) ?? .fn
    retention = defaults.string(forKey: Key.retention).flatMap(Retention.init) ?? .forever
    hasOnboarded = defaults.bool(forKey: Key.onboarded)
    zoomKeyRejected = defaults.bool(forKey: Key.zoomKeyRejected)
  }

  /// The engine to use, given whether a Zoom key is stored.
  public func effectiveEngine(zoomKeyStored: Bool) -> Engine {
    zoomKeyStored ? engine : .apple
  }
}

/// BCP-47 language tags.
public enum Language {
  /// The fallback when the system language is not supported.
  public static let fallback = "en-US"
  /// Not a tag: Zoom detects the language as it listens.
  public static let auto = "auto"

  /// The system's language as a BCP-47 tag.
  public static var system: String {
    tag(for: Locale.current)
  }

  /// `en_US` and `en-us` both become `en-US`.
  public static func tag(for locale: Locale) -> String {
    locale.identifier(.bcp47)
  }

  public static func normalize(_ tag: String) -> String {
    Locale(identifier: tag).identifier(.bcp47)
  }

  /// The system language if it is among `supported`, else the same language
  /// in another region, else `en-US`.
  public static func defaultLanguage(system: String, supported: [String]) -> String {
    let system = normalize(system)
    if supported.contains(system) { return system }
    let code = Locale(identifier: system).language.languageCode?.identifier
    if let code,
      let sameLanguage = supported.sorted().first(where: {
        Locale(identifier: $0).language.languageCode?.identifier == code
      })
    {
      return sameLanguage
    }
    return fallback
  }

  /// The languages to offer for an engine: auto-detect and Scribe's for Zoom,
  /// `apple` (the Apple transcriber's) otherwise.
  public static func supported(by engine: Engine, apple: [String]) -> [String] {
    engine == .zoom ? [auto] + ZoomTranscriber.supportedLanguages : apple
  }

  /// The tag seen most often, the earliest on a tie; `nil` if none.
  public static func mostCommon(_ tags: [String]) -> String? {
    let counts = Dictionary(tags.map { ($0, 1) }, uniquingKeysWith: +)
    return tags.first { counts[$0] == counts.values.max() }
  }

  /// A name for menus, e.g. "English (US)".
  public static func displayName(for tag: String, in locale: Locale = .current) -> String {
    if tag == auto { return "Auto-detect" }
    let target = Locale(identifier: tag)
    let languageName =
      target.language.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) } ?? tag
    guard let region = target.region?.identifier else { return languageName }
    let regionName =
      region == "US" || region == "GB" ? region : (locale.localizedString(forRegionCode: region) ?? region)
    return "\(languageName) (\(regionName))"
  }

  /// Whether `tag` is US English, the only language Zoom's Text Polishing takes.
  public static func isUSEnglish(_ tag: String) -> Bool {
    normalize(tag) == "en-US"
  }
}
