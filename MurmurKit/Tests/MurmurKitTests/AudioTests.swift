@preconcurrency import AVFAudio
import Foundation
import Testing

@testable import MurmurKit

@Suite("Audio")
struct AudioTests {
  @Test func levelTracksLoudness() {
    #expect(AudioChunk.level(of: []) == 0)
    #expect(AudioChunk.level(of: [0, 0, 0]) == 0)
    let quiet = AudioChunk.level(of: Array(repeating: 30, count: 100))
    let loud = AudioChunk.level(of: Array(repeating: 20_000, count: 100))
    #expect(quiet < loud)
    #expect((0...1).contains(loud))
  }

  @Test func bytesAreLittleEndian() {
    let chunk = AudioChunk(samples: [1, -2])
    #expect([UInt8](chunk.littleEndianData) == [0x01, 0x00, 0xFE, 0xFF])
    #expect(chunk.duration == .zero)
    #expect(AudioChunk(samples: Array(repeating: 0, count: 16_000)).duration == .seconds(1))
  }

  @Test func fakeSourceFailsAndStops() async throws {
    let failing = FakeAudioSource(failure: .noInput)
    await #expect(throws: AudioError.noInput) { try await failing.start() }

    let source = FakeAudioSource(chunks: [chunk()], keepOpen: false)
    var count = 0
    for await _ in try await source.start() { count += 1 }
    #expect(count == 1)
    await source.stop()
    #expect(source.startCount == 1)
    #expect(source.stopCount == 1)
  }
}

@Suite("Apple speech")
struct AppleSpeechTests {
  @Test func convertsChunksToTheAnalyzerFormat() throws {
    let samples: [Int16] = (0..<1_600).map { Int16($0 % 100) }
    let same = try #require(PCMConverter.buffer(from: AudioChunk(samples: samples)))
    #expect(same.frameLength == 1_600)
    #expect(PCMConverter.buffer(from: AudioChunk(samples: [])) == nil)

    let float48k = try #require(
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
    let converted = try #require(PCMConverter(to: float48k).convert(AudioChunk(samples: samples)))
    #expect(converted.format.sampleRate == 48_000)
    #expect(converted.frameLength > 0)
  }

  @Test func unsupportedLanguages() async {
    #expect(await AppleSpeech.status(for: "zz-ZZ") == .unsupported)
    let failure = await AppleSpeechTests.firstEvent(AppleTranscriber(language: "zz-ZZ"))
    #expect(failure == .failed(.unavailable))
    await #expect(throws: TranscriberFailure.unavailable) {
      try await AppleSpeech.install(language: "zz-ZZ") { _ in }
    }
  }

  @Test func supportedLanguagesIncludeUSEnglish() async {
    let languages = await AppleSpeech.supportedLanguages()
    #expect(languages.contains("en-US"))
    #expect(await AppleSpeech.status(for: "en-US") != .unsupported)
  }

  /// Runs when the en-US model is installed: silence transcribes to nothing.
  @Test func silenceEndsWithNoText() async throws {
    guard await AppleSpeech.status(for: "en-US") == .installed else { return }
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    for _ in 0..<10 { input.yield(AudioChunk(samples: Array(repeating: 0, count: 1_600))) }
    input.finish()
    var events: [TranscriptEvent] = []
    for await event in AppleTranscriber(language: "en-US").transcribe(audio) { events.append(event) }
    #expect(events.last == .ended)
    #expect(!events.contains { if case .final(let text) = $0 { !text.isEmpty } else { false } })
    #expect(await SystemEngineAvailability().appleTranscriberAvailable(language: "en-US"))
  }

  static func firstEvent(_ transcriber: any Transcriber) async -> TranscriptEvent? {
    let (audio, input) = AsyncStream.makeStream(of: AudioChunk.self)
    input.finish()
    for await event in transcriber.transcribe(audio) { return event }
    return nil
  }
}
