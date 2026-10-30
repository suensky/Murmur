import Foundation
import Security

/// The Zoom API key's rules.
public enum ZoomKey {
  public static let maxLength = 512

  /// The key trimmed, or `nil` if it is empty, too long, or holds whitespace.
  public static func normalize(_ key: String) -> String? {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...maxLength).contains(trimmed.count),
      !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    else { return nil }
    return trimmed
  }
}

public enum ZoomKeyError: Error, Equatable {
  case invalid
  case keychain(OSStatus)
}

/// Where the Zoom API key is kept.
public protocol ZoomKeyStore: Sendable {
  func read() -> String?
  func save(_ key: String) throws(ZoomKeyError)
  func delete() throws(ZoomKeyError)
}

extension ZoomKeyStore {
  public var hasKey: Bool { read() != nil }
}

/// A generic-password Keychain item: service `com.ai.murmur`, account
/// `zoom-api-key`, readable only while unlocked, on this device.
///
/// `ZOOM_API_KEY` in the environment overrides it, for development.
public struct KeychainZoomKeyStore: ZoomKeyStore {
  public static let service = "com.ai.murmur"
  public static let account = "zoom-api-key"

  private let environment: [String: String]
  private let service: String

  /// - Parameter service: the item's service; tests use their own.
  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment, service: String = Self.service
  ) {
    self.environment = environment
    self.service = service
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: Self.account,
    ]
  }

  public func read() -> String? {
    if let override = environment["ZOOM_API_KEY"].flatMap(ZoomKey.normalize) {
      return override
    }
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let key = String(data: data, encoding: .utf8)
    else { return nil }
    return ZoomKey.normalize(key)
  }

  public func save(_ key: String) throws(ZoomKeyError) {
    guard let key = ZoomKey.normalize(key) else { throw .invalid }
    let data = Data(key.utf8)
    let update: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      var add = baseQuery
      add.merge(update) { $1 }
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw .keychain(status) }
  }

  public func delete() throws(ZoomKeyError) {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw .keychain(status) }
  }
}

/// A key kept in memory, for tests and previews.
public final class InMemoryZoomKeyStore: ZoomKeyStore, @unchecked Sendable {
  private let lock = NSLock()
  private var key: String?

  public init(key: String? = nil) {
    self.key = key
  }

  public func read() -> String? {
    lock.withLock { key }
  }

  public func save(_ key: String) throws(ZoomKeyError) {
    guard let key = ZoomKey.normalize(key) else { throw .invalid }
    lock.withLock { self.key = key }
  }

  public func delete() throws(ZoomKeyError) {
    lock.withLock { key = nil }
  }
}
