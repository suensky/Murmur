import Foundation
import Testing

@testable import MurmurKit

@Suite("ZoomTranscriber", .timeLimit(.minutes(1)))
struct ZoomTranscriberTests {
  /// Runs a transcriber against the fixture's server with `chunks` of audio.
  func transcribe(
    fixture name: String, language: String = "en-US", polishing: Bool = true, chunks: Int = 5
  ) async throws -> (events: [TranscriptEvent], server: FakeScribeServer) {
    let server = try FakeScribeServer(fixture: .named(name))
    let url = try await server.start()
    defer { server.stop() }
    let transcriber = ZoomTranscriber(
      apiKey: "test-key", options: TranscriberOptions(language: language, textPolishing: polishing), baseURL: url,
      connectTimeout: 5)
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    for _ in 0..<chunks { input.yield(chunk()) }
    input.finish()
    var events: [TranscriptEvent] = []
    for await event in transcriber.transcribe(audio) { events.append(event) }
    return (events, server)
  }

  @Test func deltasAndFinals() async throws {
    let (events, server) = try await transcribe(fixture: "deltas", polishing: false)
    #expect(
      events == [
        .draft("Can we"), .draft("Can we move the"), .final("Can we move the review?"),
        .final("To Thursday."), .ended,
      ])
    #expect(server.closeReceived)
    #expect(server.audioBytes == 5 * 3_200)
    let config = try #require(server.sessionUpdate?["config"] as? [String: Any])
    #expect(config["language"] as? String == "en-US")
    #expect(config["interim_results"] as? Bool == true)
    #expect(config["diarization"] as? Bool == false)
    #expect(config["model"] == nil)
    #expect((server.sessionUpdate?["audio"] as? [String: Any])?["format"] as? String == "pcm16")
    #expect(server.sessionUpdate?["outputs"] == nil)
  }

  @Test func autoDetectsContinuously() async throws {
    let (_, server) = try await transcribe(fixture: "deltas", language: Language.auto, polishing: false)
    let config = try #require(server.sessionUpdate?["config"] as? [String: Any])
    #expect(config["language"] == nil)
    let detection = try #require(config["language_detection"] as? [String: Any])
    #expect(detection["mode"] as? String == "continuous")
    #expect(detection["candidate_languages"] == nil)
  }

  @Test func onePolishedEventCoversSeveralItems() async throws {
    let (events, server) = try await transcribe(fixture: "polished")
    #expect(
      events == [
        .final("um so can we move the review"), .final("to thursday no friday"),
        .polished("Can we move the review to Friday?"), .ended,
      ])
    let outputs = try #require(server.sessionUpdate?["outputs"] as? [String: Any])
    let polishing = try #require(outputs["text_polishing"] as? [String: Any])
    #expect(polishing["enabled"] as? Bool == true)
    #expect(polishing["include_transcript"] as? Bool == true)
  }

  @Test func ignoresUnknownAndNonFatalMessages() async throws {
    let (events, _) = try await transcribe(fixture: "noise", polishing: false)
    #expect(events == [.final("Still here."), .ended])
  }

  @Test func fatalErrorFails() async throws {
    let (events, _) = try await transcribe(fixture: "fatal", polishing: false)
    #expect(events == [.failed(.engine("internal_error"))])
  }

  @Test func rejectedKeyOnUpgrade() async throws {
    let (events, server) = try await transcribe(fixture: "unauthorized")
    #expect(events == [.failed(.keyRejected)])
    #expect(server.apiKey == "test-key")
  }

  @Test func dropMidSession() async throws {
    let (events, _) = try await transcribe(fixture: "drop", polishing: false, chunks: 40)
    #expect(events.first == .draft("Half a"))
    #expect(events.last == .failed(.dropped))
  }

  @Test func connectFailureWithoutAServer() async throws {
    let transcriber = ZoomTranscriber(
      apiKey: "k", options: TranscriberOptions(language: "en-US", textPolishing: false),
      baseURL: URL(string: "ws://127.0.0.1:1/none"), connectTimeout: 2)
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    input.finish()
    var events: [TranscriptEvent] = []
    for await event in transcriber.transcribe(audio) { events.append(event) }
    #expect(events == [.failed(.connectFailed(status: nil))])
  }

  @Test func onlyLoopbackMayOverrideTheURL() {
    let options = TranscriberOptions(language: "en-US", textPolishing: false)
    #expect(
      ZoomTranscriber(apiKey: "k", options: options, baseURL: URL(string: "ws://localhost:9/x")).url.host()
        == "localhost")
    #expect(
      ZoomTranscriber(apiKey: "k", options: options, baseURL: URL(string: "wss://evil.example/x")).url
        == ZoomTranscriber.liveURL)
    #expect(ZoomTranscriber(apiKey: "k", options: options).url == ZoomTranscriber.liveURL)
  }

  @Test(arguments: [
    (401, TranscriberFailure.keyRejected), (403, .keyRejected), (429, .connectFailed(status: 429)),
    (503, .connectFailed(status: 503)),
  ])
  func mapsUpgradeStatuses(status: Int, failure: TranscriberFailure) {
    let response = HTTPURLResponse(
      url: ZoomTranscriber.liveURL, statusCode: status, httpVersion: nil, headerFields: nil)
    #expect(ZoomTranscriber.connectFailure(response: response, error: URLError(.badServerResponse)) == failure)
  }
}

@Suite("Scribe messages")
struct ScribeMessageTests {
  func parse(_ json: String) -> Scribe.Event? { Scribe.parse(Data(json.utf8)) }

  @Test func parsesKnownEvents() {
    #expect(parse(#"{"type":"session.created","session_id":"s1"}"#) == .created(sessionID: "s1"))
    #expect(parse(#"{"type":"transcription.delta","item_id":"i","delta":"Hi"}"#) == .delta("Hi"))
    #expect(parse(#"{"type":"session.closed","reason":"client"}"#) == .closed(reason: "client"))
    #expect(parse(#"{"type":"error","error":{"code":"x","fatal":false}}"#) == .error(code: "x", fatal: false))
    #expect(parse(#"{"type":"error"}"#) == .error(code: "unknown", fatal: true))
  }

  @Test func ignoresUnknownMalformedAndOversized() {
    #expect(parse(#"{"type":"input_audio_buffer.speech_started"}"#) == nil)
    #expect(parse("not json") == nil)
    #expect(parse(#"{"type":"transcription.completed"}"#) == nil)
    let huge = String(repeating: "a", count: Scribe.maxMessageBytes)
    #expect(parse(#"{"type":"transcription.delta","delta":"\#(huge)"}"#) == nil)
  }

  @Test func parsesTheDetectedLanguage() {
    #expect(
      parse(#"{"type":"transcription.completed","transcript":"Bonjour","language":"fr"}"#)
        == .completed(transcript: "Bonjour", polished: nil, language: "fr"))
    #expect(
      parse(#"{"type":"transcription.completed","transcript":"Hi","language":"<b>"}"#)
        == .completed(transcript: "Hi", polished: nil, language: nil))
    #expect(Scribe.languageTag("pt-br") == "pt-BR")
    #expect(Scribe.languageTag("not a language") == nil)
    #expect(Scribe.languageTag(String(repeating: "a", count: 40)) == nil)
    #expect(Scribe.languageTag(42) == nil)
  }

  @Test func boundsText() {
    let long = String(repeating: "a", count: Scribe.maxTextLength + 10)
    #expect(
      parse(#"{"type":"transcription.delta","delta":"\#(long)"}"#) == .delta(String(long.prefix(Scribe.maxTextLength))))
  }
}
