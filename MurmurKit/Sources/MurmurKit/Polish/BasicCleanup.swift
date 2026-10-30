import Foundation

/// A rule-based cleanup that needs no model: fillers, repeated words, spacing
/// and capitals. The last polisher before raw text.
public struct BasicCleanup: Polisher {
  public let kind = PolisherKind.basic

  /// Fillers removed in English.
  static let englishFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm"]

  public init() {}

  public func availability(for language: String) async -> PolisherAvailability {
    .available
  }

  public func polish(_ raw: String, language: String) async -> Result<String, PolishFailure> {
    .success(Self.clean(raw, language: language))
  }

  public static func clean(_ raw: String, language: String) -> String {
    let isEnglish = Locale(identifier: language).language.languageCode?.identifier == "en"
    var tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    if isEnglish {
      tokens = removingFillers(tokens).map { $0.replacing(/^i(?=$|['’,.!?;:])/, with: "I") }
    }
    tokens = removingRepeats(tokens)
    return capitalizingSentences(fixingSpacing(tokens.joined(separator: " ")))
  }

  /// Drops filler tokens, moving their punctuation onto the previous word
  /// when it ends a sentence.
  static func removingFillers(_ tokens: [String]) -> [String] {
    var result: [String] = []
    for token in tokens {
      let core = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
      guard englishFillers.contains(core) else {
        result.append(token)
        continue
      }
      if let last = token.last, ".?!".contains(last), let previous = result.popLast() {
        let trimmed = previous.trimmingCharacters(in: CharacterSet(charactersIn: ","))
        result.append(trimmed + String(last))
      }
    }
    return result
  }

  /// "The the," → "The,": keeps the first word's case and the last one's
  /// punctuation. Repeats across a sentence end are left alone.
  static func removingRepeats(_ tokens: [String]) -> [String] {
    var result: [String] = []
    for token in tokens {
      if let previous = result.last,
        !normalized(token).isEmpty,
        normalized(previous) == normalized(token),
        !previous.hasSuffix("."), !previous.hasSuffix("?"), !previous.hasSuffix("!")
      {
        let word = previous.trimmingCharacters(in: pausePunctuation)
        let trailing = token.reversed().prefix {
          pausePunctuation.contains($0.unicodeScalars.first!) || ".?!".contains($0)
        }
        result[result.count - 1] = word + String(trailing.reversed())
        continue
      }
      result.append(token)
    }
    return result
  }

  private static let pausePunctuation = CharacterSet(charactersIn: ",;:")

  private static func normalized(_ token: String) -> String {
    token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",;:.?!"))
  }

  static func fixingSpacing(_ text: String) -> String {
    var text = text.replacing(/\s+([,.!?;:])/, with: { $0.output.1 })
    text = text.replacing(/([,;:])(?=[^\s\d])/, with: { "\($0.output.1) " })
    text = text.replacing(/\s{2,}/, with: " ")
    text = text.replacing(/^[,;:]\s*/, with: "")
    return text.trimmingCharacters(in: .whitespaces)
  }

  static func capitalizingSentences(_ text: String) -> String {
    // A sentence starts at the beginning, or after .?! and a space; "v1.2"
    // and "first.second" are left alone.
    var result = ""
    var capitalizeNext = true
    var afterSentenceEnd = false
    for character in text {
      if afterSentenceEnd {
        capitalizeNext = character.isWhitespace
        afterSentenceEnd = false
      }
      if capitalizeNext, character.isLetter {
        result.append(contentsOf: character.uppercased())
        capitalizeNext = false
        continue
      }
      result.append(character)
      if ".?!".contains(character) {
        afterSentenceEnd = true
      } else if !character.isWhitespace {
        capitalizeNext = false
      }
    }
    return result
  }
}
