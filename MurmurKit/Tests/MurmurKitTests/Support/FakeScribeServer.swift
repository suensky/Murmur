import Foundation
import Network
import Testing

/// A fake Scribe Live server on loopback, replaying a JSON fixture.
///
/// The fixture's keys, each a list of server messages:
/// - `on_connect`: sent once the session's `session.update` arrives;
/// - `on_audio`: sent after the first audio frame;
/// - `on_close`: sent after `session.close`.
/// `"drop_after_audio": true` closes the connection after `on_audio`.
/// `"status": 401` answers the upgrade with that status instead.
final class FakeScribeServer: @unchecked Sendable {
  struct Fixture {
    var onConnect: [Data] = []
    var onAudio: [Data] = []
    var onClose: [Data] = []
    var dropAfterAudio = false
    var status: Int?

    init(json: Data) throws {
      let object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
      func messages(_ key: String) throws -> [Data] {
        try (object[key] as? [Any] ?? []).map { try JSONSerialization.data(withJSONObject: $0) }
      }
      onConnect = try messages("on_connect")
      onAudio = try messages("on_audio")
      onClose = try messages("on_close")
      dropAfterAudio = object["drop_after_audio"] as? Bool ?? false
      status = object["status"] as? Int
    }

    static func named(_ name: String) throws -> Fixture {
      let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "zoom"))
      return try Fixture(json: Data(contentsOf: url))
    }
  }

  private let fixture: Fixture
  private let listener: NWListener
  private let queue = DispatchQueue(label: "fake-scribe")
  private let lock = NSLock()
  private var connections: [NWConnection] = []
  private var _apiKey: String?
  private var _sessionUpdate: [String: Any]?
  private var _audioBytes = 0
  private var _closeReceived = false
  private var sentAudioReply = false

  var apiKey: String? { lock.withLock { _apiKey } }
  var sessionUpdate: [String: Any]? { lock.withLock { _sessionUpdate } }
  var audioBytes: Int { lock.withLock { _audioBytes } }
  var closeReceived: Bool { lock.withLock { _closeReceived } }

  init(fixture: Fixture) throws {
    self.fixture = fixture
    let parameters: NWParameters
    if fixture.status != nil {
      parameters = .tcp
    } else {
      parameters = NWParameters(tls: nil)
      let options = NWProtocolWebSocket.Options()
      options.autoReplyPing = true
      parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    }
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
  }

  /// Starts listening and returns the URL to connect to.
  func start() async throws -> URL {
    let once = Once()
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      listener.stateUpdateHandler = { [listener] state in
        let resume: Result<UInt16, any Error>? =
          switch state {
          case .ready: .success(listener.port?.rawValue ?? 0)
          case .failed(let error): .failure(error)
          default: nil
          }
        guard let resume, once.claim() else { return }
        continuation.resume(with: resume)
      }
      listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
      listener.start(queue: queue)
    }
    return URL(string: "ws://127.0.0.1:\(port)/v2/aiservices/scribe/live")!
  }

  func stop() {
    listener.cancel()
    for connection in lock.withLock({ connections }) { connection.cancel() }
  }

  private func accept(_ connection: NWConnection) {
    lock.withLock { connections.append(connection) }
    connection.start(queue: queue)
    if let status = fixture.status {
      rejectUpgrade(connection, status: status)
    } else {
      receive(on: connection)
    }
  }

  /// Answers the HTTP upgrade with an error status, as Zoom does for a bad key.
  private func rejectUpgrade(_ connection: NWConnection, status: Int) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
      if let data, let request = String(data: data, encoding: .utf8) {
        let key = request.split(separator: "\r\n").first { $0.lowercased().hasPrefix("x-api-key:") }
        self?.lock.withLock {
          self?._apiKey = key.map { String($0.dropFirst(10)).trimmingCharacters(in: .whitespaces) }
        }
      }
      let response = "HTTP/1.1 \(status) Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
  }

  private func receive(on connection: NWConnection) {
    connection.receiveMessage { [weak self] data, context, _, error in
      guard let self, error == nil else { return }
      let metadata =
        context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
      switch metadata?.opcode {
      case .text:
        if let data { self.handleText(data, on: connection) }
      case .binary:
        self.handleAudio(data ?? Data(), on: connection)
      case .close:
        connection.cancel()
        return
      default:
        break
      }
      self.receive(on: connection)
    }
  }

  private func handleText(_ data: Data, on connection: NWConnection) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else { return }
    switch type {
    case "session.update":
      lock.withLock { _sessionUpdate = object }
      send(fixture.onConnect, on: connection)
    case "session.close":
      lock.withLock { _closeReceived = true }
      send(fixture.onClose, on: connection)
    default:
      break
    }
  }

  private func handleAudio(_ data: Data, on connection: NWConnection) {
    let first = lock.withLock {
      _audioBytes += data.count
      defer { sentAudioReply = true }
      return !sentAudioReply
    }
    guard first else { return }
    send(fixture.onAudio, on: connection)
    if fixture.dropAfterAudio {
      queue.asyncAfter(deadline: .now() + 0.05) { connection.forceCancel() }
    }
  }

  private func send(_ messages: [Data], on connection: NWConnection) {
    for message in messages {
      let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
      let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
      connection.send(content: message, contentContext: context, isComplete: true, completion: .idempotent)
    }
  }
}

/// True the first time only.
private final class Once: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      defer { claimed = true }
      return !claimed
    }
  }
}
