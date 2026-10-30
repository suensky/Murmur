import Foundation

/// Transcribes with Zoom's Scribe Live over a WebSocket, optionally with Text
/// Polishing. The only unit in MurmurKit that uses the network.
public struct ZoomTranscriber: Transcriber {
  public static let liveURL = URL(string: "wss://api.zoom.us/v2/aiservices/scribe/live")!
  /// The locales Scribe recognizes: those of `zoom-scribe-multilingual`, then
  /// those only `whisper` adds. Scribe picks the model from the language.
  /// From developers.zoom.us/docs/ai-services/scribe/speech-configuration.
  public static let supportedLanguages = [
    "en-US", "ar-SA", "ar-AE", "zh-CN", "fr-FR", "de-DE", "it-IT", "ja-JP", "ko-KR", "pt-BR", "pt-PT", "es-ES",
    "bn-IN", "zh-HK", "ca-ES", "cs-CZ", "da-DK", "nl-NL", "et-EE", "fi-FI", "el-GR", "he-IL", "hi-IN",
    "hu-HU", "id-ID", "ms-MY", "fa-IR", "pl-PL", "ro-RO", "ru-RU", "sv-SE", "tl-PH", "ta-IN", "te-IN",
    "th-TH", "tr-TR", "uk-UA", "vi-VN",
  ].sorted()
  /// Bytes in 100 ms of 16 kHz PCM16, the frame size Scribe expects.
  static let frameBytes = AudioChunk.sampleRate / 10 * 2

  public let kind = TranscriberKind.zoom
  let apiKey: String
  let options: TranscriberOptions
  let url: URL
  let connectTimeout: TimeInterval

  /// - Parameter baseURL: overrides the live URL, only to a loopback host,
  ///   for the fake server in tests; other hosts are ignored.
  public init(apiKey: String, options: TranscriberOptions, baseURL: URL? = nil, connectTimeout: TimeInterval = 10) {
    self.apiKey = apiKey
    self.options = options
    self.url = baseURL.flatMap { Self.isLoopback($0) ? $0 : nil } ?? Self.liveURL
    self.connectTimeout = connectTimeout
  }

  static func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host()?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
    let this = self
    return AsyncStream { continuation in
      let task = Task {
        let outcome = await this.run(audio: audio, continuation: continuation)
        continuation.yield(outcome)
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Runs one Scribe session and returns its last event: `ended` or `failed`.
  private func run(
    audio: AsyncStream<AudioChunk>, continuation: AsyncStream<TranscriptEvent>.Continuation
  ) async -> TranscriptEvent {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = connectTimeout
    let session = URLSession(configuration: configuration)
    var request = URLRequest(url: url, timeoutInterval: connectTimeout)
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("live-asr", forHTTPHeaderField: "Sec-WebSocket-Protocol")
    let socket = session.webSocketTask(with: request)
    socket.maximumMessageSize = Scribe.maxMessageBytes
    socket.resume()
    defer {
      socket.cancel(with: .normalClosure, reason: nil)
      session.invalidateAndCancel()
    }

    // Audio waits in the input stream's buffer while the socket connects.
    let update = Scribe.sessionUpdate(language: options.language, textPolishing: options.textPolishing)
    do {
      try await socket.send(.string(String(decoding: update, as: UTF8.self)))
    } catch {
      let failure = Self.connectFailure(response: socket.response, error: error)
      Log.transcription.error("zoom connect failed: \(failure.code, privacy: .public)")
      return .failed(failure)
    }
    Log.transcription.info("zoom connected, polishing \(options.textPolishing, privacy: .public)")

    return await withTaskCancellationHandler {
      await withTaskGroup(of: TranscriptEvent?.self) { group in
        group.addTask { await Self.receive(from: socket, continuation: continuation) }
        group.addTask { await Self.send(audio, to: socket) }
        var outcome: TranscriptEvent = .failed(.dropped)
        while let result = await group.next() {
          // The sender returns nil when it sent everything; the receiver
          // always returns the session's last event.
          guard let result else { continue }
          outcome = result
          group.cancelAll()
          socket.cancel(with: .normalClosure, reason: nil)
        }
        return outcome
      }
    } onCancel: {
      socket.cancel(with: .goingAway, reason: nil)
    }
  }

  private static func send(_ audio: AsyncStream<AudioChunk>, to socket: URLSessionWebSocketTask) async
    -> TranscriptEvent?
  {
    var pending = Data()
    do {
      for await chunk in audio {
        pending.append(chunk.littleEndianData)
        while pending.count >= frameBytes {
          try await socket.send(.data(pending.prefix(frameBytes)))
          pending.removeFirst(frameBytes)
        }
      }
      if Task.isCancelled { return nil }
      if !pending.isEmpty { try await socket.send(.data(pending)) }
      try await socket.send(.string(String(decoding: Scribe.sessionClose, as: UTF8.self)))
      return nil
    } catch {
      return Task.isCancelled ? nil : .failed(.dropped)
    }
  }

  private static func receive(
    from socket: URLSessionWebSocketTask, continuation: AsyncStream<TranscriptEvent>.Continuation
  ) async -> TranscriptEvent {
    while true {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await socket.receive()
      } catch {
        Log.transcription.error("zoom dropped: \((error as NSError).code, privacy: .public)")
        return .failed(.dropped)
      }
      let data: Data
      switch message {
      case .string(let text): data = Data(text.utf8)
      case .data(let bytes): data = bytes
      @unknown default: continue
      }
      switch Scribe.parse(data) {
      case .created(let sessionID):
        Log.transcription.info("zoom session \(sessionID ?? "-", privacy: .public)")
      case .delta(let text):
        continuation.yield(.draft(text))
      case .completed(let transcript, let polished, let language):
        if let language { continuation.yield(.language(language)) }
        if let transcript, !transcript.isEmpty { continuation.yield(.final(transcript)) }
        if let polished, !polished.isEmpty { continuation.yield(.polished(polished)) }
      case .closed(let reason):
        Log.transcription.info("zoom session closed: \(reason ?? "-", privacy: .public)")
        return .ended
      case .error(let code, let fatal):
        Log.transcription.error("zoom error \(code, privacy: .public), fatal \(fatal, privacy: .public)")
        if fatal { return .failed(.engine(code)) }
      case nil:
        continue
      }
    }
  }

  static func connectFailure(response: URLResponse?, error: Error) -> TranscriberFailure {
    guard let status = (response as? HTTPURLResponse)?.statusCode else { return .connectFailed(status: nil) }
    return status == 401 || status == 403 ? .keyRejected : .connectFailed(status: status)
  }
}
