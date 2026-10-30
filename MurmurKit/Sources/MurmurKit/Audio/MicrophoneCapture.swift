@preconcurrency import AVFAudio
import Foundation

/// Captures the default input with `AVAudioEngine` and converts it to
/// 16 kHz mono PCM16.
///
/// When the input device changes, the engine restarts on the new default
/// input; if it cannot, the stream ends and the dictation finishes with what
/// it has.
public final class MicrophoneCapture: AudioSource, @unchecked Sendable {
  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var continuation: AsyncStream<AudioChunk>.Continuation?
  private var configObserver: NSObjectProtocol?

  private static let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: Double(AudioChunk.sampleRate), channels: 1, interleaved: true)!

  public init() {}

  public func start() async throws(AudioError) -> AsyncStream<AudioChunk> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: AudioChunk.self, bufferingPolicy: .unbounded)
    lock.withLock { self.continuation = continuation }
    do {
      try startEngine()
    } catch {
      lock.withLock { self.continuation = nil }
      continuation.finish()
      throw error
    }
    return stream
  }

  public func stop() async {
    let (engine, continuation, observer) = lock.withLock {
      defer {
        self.engine = nil
        self.continuation = nil
        self.configObserver = nil
      }
      return (self.engine, self.continuation, self.configObserver)
    }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    continuation?.finish()
  }

  private func startEngine() throws(AudioError) {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw .noInput }
    guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
      throw .engine("converter")
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      guard let self, let chunk = Self.convert(buffer, with: converter) else { return }
      _ = self.lock.withLock { self.continuation }?.yield(chunk)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw .engine((error as NSError).code.description)
    }
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      self?.restart()
    }
    lock.withLock {
      self.engine = engine
      self.configObserver = observer
    }
    Log.audio.info("capture started, input \(inputFormat.sampleRate, privacy: .public) Hz")
  }

  /// The input changed: start again on the new default input.
  private func restart() {
    let (old, observer) = lock.withLock { (engine, configObserver) }
    guard let old else { return }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    old.inputNode.removeTap(onBus: 0)
    old.stop()
    do {
      try startEngine()
      Log.audio.info("capture restarted after an input change")
    } catch {
      Log.audio.error("capture could not restart: \(String(describing: error), privacy: .public)")
      let continuation = lock.withLock {
        defer {
          engine = nil
          self.continuation = nil
        }
        return self.continuation
      }
      continuation?.finish()
    }
  }

  private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AudioChunk? {
    let ratio = outputFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
    nonisolated(unsafe) var supplied = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, output.frameLength > 0, let data = output.int16ChannelData else { return nil }
    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    return AudioChunk(samples: samples)
  }
}
