@preconcurrency import AVFAudio
import Foundation
import Speech

/// Transcribes on the device with `SpeechAnalyzer` and `SpeechTranscriber`.
public struct AppleTranscriber: Transcriber {
  public let kind = TranscriberKind.apple
  public let language: String

  public init(language: String) {
    self.language = language
  }

  public func transcribe(_ audio: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptEvent> {
    let language = language
    return AsyncStream { continuation in
      let task = Task {
        do {
          try await Self.run(language: language, audio: audio, continuation: continuation)
          continuation.yield(.ended)
        } catch is CancellationError {
        } catch let failure as TranscriberFailure {
          continuation.yield(.failed(failure))
        } catch {
          Log.transcription.error("apple transcriber failed: \((error as NSError).code, privacy: .public)")
          continuation.yield(.failed(.engine(String((error as NSError).code))))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func run(
    language: String,
    audio: AsyncStream<AudioChunk>,
    continuation: AsyncStream<TranscriptEvent>.Continuation
  ) async throws {
    guard SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
    else { throw TranscriberFailure.unavailable }
    let module = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    guard await AppleSpeech.isInstalled(module: module, locale: locale),
      let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    else { throw TranscriberFailure.unavailable }

    let analyzer = SpeechAnalyzer(modules: [module])
    try await analyzer.prepareToAnalyze(in: format)
    let (inputs, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

    let results = Task {
      for try await result in module.results {
        let text = String(result.text.characters)
        continuation.yield(result.isFinal ? .final(text) : .draft(text))
      }
    }
    try await analyzer.start(inputSequence: inputs)

    let converter = PCMConverter(to: format)
    for await chunk in audio {
      if Task.isCancelled { break }
      if let buffer = converter.convert(chunk) {
        inputContinuation.yield(AnalyzerInput(buffer: buffer))
      }
    }
    inputContinuation.finish()
    if Task.isCancelled {
      await analyzer.cancelAndFinishNow()
      results.cancel()
      throw CancellationError()
    }
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await results.value
  }
}

/// The Apple speech model's state for a language.
public enum SpeechModelStatus: Sendable, Equatable {
  case unsupported
  case notInstalled
  case downloading
  case installed
}

/// Apple speech models: what is supported and installed, and installing.
public enum AppleSpeech {
  /// The languages `SpeechTranscriber` supports, as BCP-47 tags.
  public static func supportedLanguages() async -> [String] {
    guard SpeechTranscriber.isAvailable else { return [] }
    return await SpeechTranscriber.supportedLocales.map(Language.tag(for:)).sorted()
  }

  public static func status(for language: String) async -> SpeechModelStatus {
    guard SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
    else { return .unsupported }
    let module = SpeechTranscriber(locale: locale, preset: .transcription)
    if await isInstalled(module: module, locale: locale) { return .installed }
    switch await AssetInventory.status(forModules: [module]) {
    case .unsupported: return .unsupported
    case .downloading: return .downloading
    case .supported: return .notInstalled
    case .installed: return .installed
    @unknown default: return .notInstalled
    }
  }

  /// Downloads and installs the language's model, reporting progress 0 to 1.
  public static func install(
    language: String, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
      throw TranscriberFailure.unavailable
    }
    let module = SpeechTranscriber(locale: locale, preset: .transcription)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
    let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
      progress(value.fractionCompleted)
    }
    defer { observation.invalidate() }
    try await request.downloadAndInstall()
  }

  static func isInstalled(module: SpeechTranscriber, locale: Locale) async -> Bool {
    let tag = Language.tag(for: locale)
    if await SpeechTranscriber.installedLocales.contains(where: { Language.tag(for: $0) == tag }) {
      return true
    }
    return await AssetInventory.status(forModules: [module]) == .installed
  }
}

/// Converts 16 kHz mono PCM16 chunks to the analyzer's format.
final class PCMConverter: @unchecked Sendable {
  private static let chunkFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: Double(AudioChunk.sampleRate), channels: 1, interleaved: true)!

  private let target: AVAudioFormat
  private let converter: AVAudioConverter?

  init(to target: AVAudioFormat) {
    self.target = target
    converter = target == Self.chunkFormat ? nil : AVAudioConverter(from: Self.chunkFormat, to: target)
  }

  func convert(_ chunk: AudioChunk) -> AVAudioPCMBuffer? {
    guard let source = Self.buffer(from: chunk) else { return nil }
    guard let converter else { return source }
    let ratio = target.sampleRate / Self.chunkFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    nonisolated(unsafe) var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return source
    }
    return error == nil ? output : nil
  }

  static func buffer(from chunk: AudioChunk) -> AVAudioPCMBuffer? {
    let count = AVAudioFrameCount(chunk.samples.count)
    guard count > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: count),
      let channel = buffer.int16ChannelData
    else { return nil }
    chunk.samples.withUnsafeBufferPointer { samples in
      channel[0].update(from: samples.baseAddress!, count: samples.count)
    }
    buffer.frameLength = count
    return buffer
  }
}
