import Testing

@testable import MurmurKit

@Suite("EngineRouter")
struct EngineRouterTests {
  static let combinations: [RouterInputs] = {
    var all: [RouterInputs] = []
    for engine in Engine.allCases {
      for language in ["en-US", "fr-FR", "en-GB"] {
        for key in [false, true] {
          for transcriber in [false, true] {
            for polisher in [false, true] {
              all.append(
                RouterInputs(
                  engine: engine, language: language, zoomKeyStored: key,
                  appleTranscriberAvailable: transcriber, applePolisherAvailable: polisher))
            }
          }
        }
      }
    }
    return all
  }()

  @Test(arguments: combinations)
  func plansEveryCombination(_ inputs: RouterInputs) {
    let plan = EngineRouter.plan(inputs)

    // The polisher chain: Apple when available, then the basic cleanup.
    #expect(plan.polishers == (inputs.applePolisherAvailable ? [.apple, .basic] : [.basic]))

    let zoom = inputs.zoomKeyStored && (inputs.engine == .zoom || !inputs.appleTranscriberAvailable)
    if zoom {
      #expect(plan.transcriber == .zoom)
      #expect(plan.textPolishing == (inputs.language == "en-US"))
      #expect(plan.fallback == (inputs.appleTranscriberAvailable ? .apple : nil))
    } else {
      // Zoom with no key is Apple; no transcriber at all without the model.
      #expect(plan.transcriber == (inputs.appleTranscriberAvailable ? .apple : nil))
      #expect(!plan.textPolishing)
      #expect(plan.fallback == nil)
    }
  }

  @Test func zoomWithoutAKeyIsApple() {
    let plan = EngineRouter.plan(
      RouterInputs(
        engine: .zoom, language: "en-US", zoomKeyStored: false,
        appleTranscriberAvailable: true, applePolisherAvailable: true))
    #expect(plan == EnginePlan(transcriber: .apple, textPolishing: false, fallback: nil, polishers: [.apple, .basic]))
  }

  @Test func zoomInUSEnglishPolishesWithAppleBehind() {
    let plan = EngineRouter.plan(
      RouterInputs(
        engine: .zoom, language: "en-US", zoomKeyStored: true,
        appleTranscriberAvailable: true, applePolisherAvailable: true))
    #expect(plan == EnginePlan(transcriber: .zoom, textPolishing: true, fallback: .apple, polishers: [.apple, .basic]))
  }
}

extension RouterInputs: CustomTestStringConvertible {
  public var testDescription: String {
    "\(engine) \(language) key:\(zoomKeyStored) asr:\(appleTranscriberAvailable) fm:\(applePolisherAvailable)"
  }
}
