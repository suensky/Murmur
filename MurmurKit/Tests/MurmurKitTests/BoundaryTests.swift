import Foundation
import Testing

/// Scans MurmurKit's sources for the design's boundaries.
@Suite("Boundaries")
struct BoundaryTests {
  static let sourcesURL = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources/MurmurKit")

  /// Each source file's path relative to `Sources/MurmurKit`, and its lines.
  static func sources() throws -> [(path: String, lines: [String])] {
    let files = FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil)!
    return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { url in
      let path = String(url.path.dropFirst(sourcesURL.path.count + 1))
      return (path, try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines))
    }
  }

  @Test func scansTheSources() throws {
    #expect(try Self.sources().count > 10)
  }

  @Test func noUIFrameworks() throws {
    for (path, lines) in try Self.sources() {
      for line in lines where line.contains(/^\s*(@preconcurrency\s+)?import\s+(AppKit|UIKit|SwiftUI|Cocoa)\b/) {
        Issue.record("\(path) imports a UI framework: \(line)")
      }
    }
  }

  @Test func onlyZoomTranscriberUsesTheNetwork() throws {
    for (path, lines) in try Self.sources() where path != "Transcription/ZoomTranscriber.swift" {
      for line in lines
      where line.contains(/URLSession|URLRequest|NWConnection|NWListener|^\s*import\s+Network\b|CFNetwork/) {
        Issue.record("\(path) uses the network: \(line)")
      }
    }
  }

  @Test func onlyStoreHoldsSQL() throws {
    for (path, lines) in try Self.sources() where !path.hasPrefix("Store/") {
      for line in lines
      where line.contains(/\b(SELECT\s|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|CREATE\s+(TABLE|INDEX))/) {
        Issue.record("\(path) holds SQL: \(line)")
      }
      for line in lines where line.contains(/^\s*import\s+GRDB\b/) {
        Issue.record("\(path) imports GRDB")
      }
    }
  }

  @Test func logsTakeNoUserTextOrKey() throws {
    let forbidden =
      /\\\(\s*(self\.)?(text|raw|rawText|polished|polishedText|transcript|draft|finals|chunk|prompt|output|apiKey|key|dictation\.text|dictation\.rawText)\b/
    for (path, lines) in try Self.sources() {
      for line in lines where line.contains(/\bLog\.\w+\.(debug|info|notice|error|fault|warning)\(/) {
        if line.contains(forbidden) {
          Issue.record("\(path) logs user text or the key: \(line)")
        }
      }
    }
  }
}
