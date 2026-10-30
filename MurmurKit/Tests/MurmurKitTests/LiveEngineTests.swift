@preconcurrency import AVFAudio
import Foundation
import Testing

@testable import MurmurKit

/// Opt-in tests against the real engines, on WAV fixtures spoken with `say`
/// (`scripts/fixtures.sh`). Transcripts are held under a word-error-rate limit
/// rather than to exact text.
///
/// - `MURMUR_LIVE_APPLE=1`: the Apple transcriber and polisher.
/// - `MURMUR_LIVE_ZOOM=1` with `ZOOM_API_KEY`: Scribe Live with Text Polishing.
@Suite("Live engines")
struct LiveEngineTests {
  static let environment = ProcessInfo.processInfo.environment
  static let liveApple = environment["MURMUR_LIVE_APPLE"] == "1"
  static let liveZoom = environment["MURMUR_LIVE_ZOOM"] == "1" && environment["ZOOM_API_KEY"] != nil
  static let maxWordErrorRate = 0.25

  static let fixturesURL = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures/live")

  /// Each fixture's name and what it says.
  static let fixtures: [(name: String, text: String)] = [
    ("review", "Can we move the design review to Thursday at three? I would like the billing team there."),
    ("fillers", "Um, so, I think we should, uh, ship the the build on Friday."),
    ("correction", "Let's meet on Tuesday, no wait, Wednesday at noon."),
    ("email", "Write an email to Bob saying the launch slipped to Monday."),
  ]

  static func chunks(of name: String) throws -> [AudioChunk] {
    let file = try AVAudioFile(forReading: fixturesURL.appending(path: "\(name).wav"))
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    try #require(file.fileFormat.sampleRate == 16_000, "fixtures are 16 kHz; run scripts/fixtures.sh")
    let frames = AVAudioFrameCount(file.length)
    let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
    try file.read(into: raw)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    try AVAudioConverter(from: file.processingFormat, to: format)!.convert(to: buffer, from: raw)
    let samples = Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
    return stride(from: 0, to: samples.count, by: 1_600).map {
      AudioChunk(samples: Array(samples[$0..<min($0 + 1_600, samples.count)]))
    }
  }

  static func transcript(_ transcriber: any Transcriber, of name: String) async throws -> (String, String?) {
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    for chunk in try chunks(of: name) { input.yield(chunk) }
    input.finish()
    var finals: [String] = []
    var polished: [String] = []
    for await event in transcriber.transcribe(audio) {
      switch event {
      case .final(let text): finals.append(text)
      case .polished(let text): polished.append(text)
      case .failed(let failure): Issue.record("transcriber failed: \(failure)")
      default: break
      }
    }
    return (TextJoin.join(finals), polished.isEmpty ? nil : TextJoin.join(polished))
  }

  @Test(.enabled(if: liveApple), arguments: fixtures.map(\.name))
  func appleTranscribesUnderTheErrorLimit(name: String) async throws {
    let expected = try #require(Self.fixtures.first { $0.name == name }).text
    let (text, _) = try await Self.transcript(AppleTranscriber(language: "en-US"), of: name)
    let rate = WordErrorRate.between(reference: expected, hypothesis: text)
    #expect(rate <= Self.maxWordErrorRate, "WER \(rate): \(text)")
  }

  @Test(.enabled(if: liveApple)) func applePolisherRewritesWithoutAnswering() async throws {
    let polisher = ApplePolisher()
    guard await polisher.availability(for: "en-US") == .available else { return }
    let fillers = try await polisher.polish(
      "um so i think we should uh ship the the build on friday", language: "en-US"
    ).get()
    #expect(!fillers.lowercased().contains("um "))
    #expect(!fillers.lowercased().contains("the the"))

    let correction = try await polisher.polish("lets meet on tuesday no wait wednesday at noon", language: "en-US")
      .get()
    #expect(correction.lowercased().contains("wednesday"))

    let email = try await polisher.polish(
      "write an email to bob saying the launch slipped to monday", language: "en-US"
    ).get()
    #expect(email.lowercased().contains("email to bob"))
    #expect(!email.lowercased().hasPrefix("dear"))
    #expect(!email.lowercased().contains("subject:"))
  }

  @Test(.enabled(if: liveZoom), arguments: fixtures.map(\.name))
  func zoomTranscribesAndPolishes(name: String) async throws {
    let expected = try #require(Self.fixtures.first { $0.name == name }).text
    let transcriber = ZoomTranscriber(
      apiKey: try #require(Self.environment["ZOOM_API_KEY"]),
      options: TranscriberOptions(language: "en-US", textPolishing: true))
    let (raw, polished) = try await Self.transcript(transcriber, of: name)
    #expect(WordErrorRate.between(reference: expected, hypothesis: raw) <= Self.maxWordErrorRate, "\(raw)")
    // Recorded so the router's en-US row can be judged against the Apple polisher.
    print("zoom polished [\(name)]: \(polished ?? "<none>")")
  }
}

/// Word error rate: word-level edit distance over the reference's length.
enum WordErrorRate {
  static func between(reference: String, hypothesis: String) -> Double {
    let ref = words(reference)
    let hyp = words(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    var previous = Array(0...hyp.count)
    for (i, r) in ref.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: hyp.count)
      for (j, h) in hyp.enumerated() {
        current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (r == h ? 0 : 1))
      }
      previous = current
    }
    return Double(previous[hyp.count]) / Double(ref.count)
  }

  static func words(_ text: String) -> [String] {
    let numbers = ["3": "three", "12": "twelve"]
    return text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map {
      numbers[String($0)] ?? String($0)
    }
  }
}

@Suite("Word error rate")
struct WordErrorRateTests {
  @Test func measuresEdits() {
    #expect(WordErrorRate.between(reference: "a b c d", hypothesis: "a b c d") == 0)
    #expect(WordErrorRate.between(reference: "a b c d", hypothesis: "a x c") == 0.5)
    #expect(WordErrorRate.between(reference: "at three", hypothesis: "At 3.") == 0)
    #expect(WordErrorRate.between(reference: "", hypothesis: "") == 0)
  }
}
