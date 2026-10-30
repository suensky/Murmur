import Foundation

/// A run of 16 kHz mono PCM16 samples from the microphone.
public struct AudioChunk: Sendable, Equatable {
  public static let sampleRate = 16_000

  public var samples: [Int16]
  /// The input level, 0 to 1, for the HUD.
  public var level: Float

  public init(samples: [Int16], level: Float? = nil) {
    self.samples = samples
    self.level = level ?? Self.level(of: samples)
  }

  public var duration: Duration {
    .milliseconds(samples.count * 1000 / Self.sampleRate)
  }

  /// The samples as little-endian bytes, as Scribe Live takes them.
  public var littleEndianData: Data {
    samples.withUnsafeBufferPointer { buffer in
      var data = Data(capacity: buffer.count * 2)
      for sample in buffer {
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
      }
      return data
    }
  }

  /// RMS on a rough dB scale, mapped to 0...1.
  public static func level(of samples: [Int16]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples {
      let value = Float(sample) / Float(Int16.max)
      sum += value * value
    }
    let rms = (sum / Float(samples.count)).squareRoot()
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return min(max((db + 50) / 50, 0), 1)
  }
}

public enum AudioError: Error, Equatable {
  case permissionDenied
  case noInput
  case engine(String)
}

/// A source of microphone audio.
public protocol AudioSource: AnyObject, Sendable {
  /// Starts capture. The stream ends after `stop()`, or when the input is
  /// lost and cannot be restarted.
  func start() async throws(AudioError) -> AsyncStream<AudioChunk>
  func stop() async
}

/// Plays back fixed chunks; for tests and previews.
public final class FakeAudioSource: AudioSource, @unchecked Sendable {
  private let lock = NSLock()
  private let chunks: [AudioChunk]
  private let failure: AudioError?
  private let keepOpen: Bool
  private var continuation: AsyncStream<AudioChunk>.Continuation?
  public private(set) var startCount = 0
  public private(set) var stopCount = 0

  /// - Parameter keepOpen: whether the stream stays open after the chunks
  ///   until `stop()`, as a microphone does.
  public init(chunks: [AudioChunk] = [], failure: AudioError? = nil, keepOpen: Bool = true) {
    self.chunks = chunks
    self.failure = failure
    self.keepOpen = keepOpen
  }

  public func start() async throws(AudioError) -> AsyncStream<AudioChunk> {
    if let failure { throw failure }
    let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self)
    for chunk in chunks { continuation.yield(chunk) }
    if !keepOpen { continuation.finish() }
    lock.withLock {
      startCount += 1
      self.continuation = continuation
    }
    return stream
  }

  /// Sends one more chunk, as if the user kept talking.
  public func send(_ chunk: AudioChunk) {
    _ = lock.withLock { continuation }?.yield(chunk)
  }

  /// Ends the stream as if the input were lost.
  public func loseInput() {
    lock.withLock { continuation }?.finish()
  }

  public func stop() async {
    let continuation = lock.withLock {
      stopCount += 1
      return self.continuation
    }
    continuation?.finish()
  }
}
