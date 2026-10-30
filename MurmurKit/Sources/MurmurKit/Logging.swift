import os

/// Loggers under the `com.ai.murmur` subsystem.
///
/// Logged: stages, the engines used, durations, error codes, request IDs.
/// Never logged: dictated or polished text, the API key.
enum Log {
  static let subsystem = "com.ai.murmur"
  static let session = Logger(subsystem: subsystem, category: "session")
  static let audio = Logger(subsystem: subsystem, category: "audio")
  static let transcription = Logger(subsystem: subsystem, category: "transcription")
  static let polish = Logger(subsystem: subsystem, category: "polish")
  static let store = Logger(subsystem: subsystem, category: "store")
}
