import Foundation

/// Scribe Live's messages. Server messages are untrusted: their size is
/// bounded, unknown types are ignored, and text is bounded.
enum Scribe {
  /// The largest message read; larger ones end the session.
  static let maxMessageBytes = 1 << 20
  /// The longest text taken from one event.
  static let maxTextLength = 20_000

  enum Event: Equatable {
    case created(sessionID: String?)
    case delta(String)
    case completed(transcript: String?, polished: String?, language: String? = nil)
    case closed(reason: String?)
    case error(code: String, fatal: Bool)
  }

  static func sessionUpdate(language: String, textPolishing: Bool) -> Data {
    var config: [String: Any] = ["interim_results": true, "diarization": false]
    if language == Language.auto {
      // Live detects only continuously; with no `language`, no language is preferred.
      config["language_detection"] = ["mode": "continuous"]
    } else {
      config["language"] = language
    }
    var message: [String: Any] = ["type": "session.update", "config": config, "audio": ["format": "pcm16"]]
    if textPolishing {
      message["outputs"] = ["text_polishing": ["enabled": true, "include_transcript": true]]
    }
    return try! JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
  }

  static let sessionClose = Data(#"{"type":"session.close"}"#.utf8)

  /// Parses a server message; `nil` for unknown or malformed ones.
  static func parse(_ data: Data) -> Event? {
    guard data.count <= maxMessageBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else { return nil }
    switch type {
    case "session.created":
      return .created(sessionID: bounded(object["session_id"]))
    case "transcription.delta":
      return bounded(object["delta"]).map(Event.delta)
    case "transcription.completed":
      let outputs = object["outputs"] as? [String: Any]
      let polishing = outputs?["text_polishing"] as? [String: Any]
      let transcript = bounded(object["transcript"])
      let polished = bounded(polishing?["text"])
      guard transcript != nil || polished != nil else { return nil }
      return .completed(transcript: transcript, polished: polished, language: languageTag(object["language"]))
    case "session.closed":
      return .closed(reason: bounded(object["reason"]))
    case "error":
      let error = object["error"] as? [String: Any]
      let code = bounded(error?["code"]) ?? "unknown"
      return .error(code: String(code.prefix(64)), fatal: error?["fatal"] as? Bool ?? true)
    default:
      return nil
    }
  }

  /// A detected language such as `fr` or `pt-BR`; anything else is dropped.
  static func languageTag(_ value: Any?) -> String? {
    guard let string = value as? String, string.count <= 16,
      string.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) != nil
    else { return nil }
    return Language.normalize(string)
  }

  private static func bounded(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    return string.count > maxTextLength ? String(string.prefix(maxTextLength)) : string
  }
}
