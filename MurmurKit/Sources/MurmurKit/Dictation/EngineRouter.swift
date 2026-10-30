import Foundation

/// What the router decides from.
public struct RouterInputs: Sendable, Equatable {
  public var engine: Engine
  public var language: String
  public var zoomKeyStored: Bool
  public var appleTranscriberAvailable: Bool
  public var applePolisherAvailable: Bool

  public init(
    engine: Engine,
    language: String,
    zoomKeyStored: Bool,
    appleTranscriberAvailable: Bool,
    applePolisherAvailable: Bool
  ) {
    self.engine = engine
    self.language = language
    self.zoomKeyStored = zoomKeyStored
    self.appleTranscriberAvailable = appleTranscriberAvailable
    self.applePolisherAvailable = applePolisherAvailable
  }
}

/// The stages chosen for one dictation.
public struct EnginePlan: Sendable, Equatable {
  /// `nil` when no transcriber can run: the speech model is missing and no
  /// Zoom key is stored.
  public var transcriber: TranscriberKind?
  /// Zoom's Text Polishing, on for en-US.
  public var textPolishing: Bool
  /// Takes over if the transcriber fails: Apple behind Zoom, when available.
  public var fallback: TranscriberKind?
  /// The polishers to try in order, after Zoom's polished text if any.
  public var polishers: [PolisherKind]

  public init(transcriber: TranscriberKind?, textPolishing: Bool, fallback: TranscriberKind?, polishers: [PolisherKind])
  {
    self.transcriber = transcriber
    self.textPolishing = textPolishing
    self.fallback = fallback
    self.polishers = polishers
  }
}

/// Chooses one transcriber and a polisher chain per dictation.
///
/// | Engine | Language | Transcriber | Polisher chain |
/// |---|---|---|---|
/// | Apple | any | Apple | Apple → BasicCleanup → raw |
/// | Zoom | en-US | Zoom, Text Polishing on | Zoom → Apple → BasicCleanup → raw |
/// | Zoom | other | Zoom, Text Polishing off | Apple → BasicCleanup → raw |
///
/// Zoom with no stored key is Apple. With the Apple transcriber unavailable,
/// Zoom stands in when a key is stored.
public enum EngineRouter {
  public static func plan(_ inputs: RouterInputs) -> EnginePlan {
    let polishers: [PolisherKind] = (inputs.applePolisherAvailable ? [.apple] : []) + [.basic]
    let useZoom =
      inputs.zoomKeyStored && (inputs.engine == .zoom || !inputs.appleTranscriberAvailable)
    if useZoom {
      return EnginePlan(
        transcriber: .zoom,
        textPolishing: Language.isUSEnglish(inputs.language),
        fallback: inputs.appleTranscriberAvailable ? .apple : nil,
        polishers: polishers)
    }
    return EnginePlan(
      transcriber: inputs.appleTranscriberAvailable ? .apple : nil,
      textPolishing: false,
      fallback: nil,
      polishers: polishers)
  }
}
