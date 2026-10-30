import Foundation
import GRDB

/// Where dictations are kept.
public protocol DictationStore: Sendable {
  func save(_ dictation: Dictation) throws
  func updateDelivery(id: UUID, to delivery: Delivery) throws
  func updatePolish(id: UUID, outcome: PolishOutcome) throws
  func delete(id: UUID) throws
  func deleteAll() throws
  /// Newest first.
  func recent(limit: Int) throws -> [Dictation]
  /// Full-text search over raw and polished text, newest first.
  func search(_ query: String, limit: Int) throws -> [Dictation]
  /// Deletes dictations created before `cutoff`; returns how many.
  @discardableResult func prune(before cutoff: Date) throws -> Int
}

/// `library.db`: the user's content, in SQLite through GRDB.
public final class LibraryStore: DictationStore {
  /// Posted after every change, for windows that show dictations.
  public static let didChange = Notification.Name("com.ai.murmur.library.didChange")

  private let database: DatabaseQueue

  /// `~/Library/Application Support/Murmur/library.db`.
  public static var defaultURL: URL {
    URL.applicationSupportDirectory.appending(path: "Murmur", directoryHint: .isDirectory)
      .appending(path: "library.db")
  }

  /// Opens the database at `url`, creating its folder `0700` and the file `0600`.
  public init(url: URL = LibraryStore.defaultURL) throws {
    let folder = url.deletingLastPathComponent()
    let files = FileManager.default
    try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    if !files.fileExists(atPath: url.path) {
      files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    database = try DatabaseQueue(path: url.path)
    try Self.migrator.migrate(database)
  }

  private init(database: DatabaseQueue) throws {
    self.database = database
    try Self.migrator.migrate(database)
  }

  /// An in-memory database, for tests and previews.
  public static func inMemory() throws -> LibraryStore {
    try LibraryStore(database: DatabaseQueue())
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1-dictation") { db in
      try db.execute(
        sql: """
          CREATE TABLE dictation (
            id            TEXT PRIMARY KEY,
            created_at    INTEGER NOT NULL,
            duration_ms   INTEGER NOT NULL,
            language      TEXT NOT NULL,
            raw_text      TEXT NOT NULL,
            polished_text TEXT,
            transcriber   TEXT NOT NULL CHECK (transcriber IN ('apple','zoom')),
            polisher      TEXT NOT NULL CHECK (polisher IN ('zoom','apple','basic','none')),
            unpolished_reason TEXT,
            target_app    TEXT,
            delivery      TEXT NOT NULL CHECK (delivery IN ('pasted','copied'))
          );
          CREATE INDEX dictation_created ON dictation(created_at DESC);
          """)
      try db.create(virtualTable: "dictation_fts", using: FTS5()) { table in
        table.synchronize(withTable: "dictation")
        table.tokenizer = .unicode61()
        table.column("raw_text")
        table.column("polished_text")
      }
    }
    return migrator
  }

  public func save(_ dictation: Dictation) throws {
    try write { db in try DictationRecord(dictation).insert(db) }
  }

  public func updateDelivery(id: UUID, to delivery: Delivery) throws {
    try write { db in
      try db.execute(
        sql: "UPDATE dictation SET delivery = ? WHERE id = ?", arguments: [delivery.rawValue, id.uuidString])
    }
  }

  public func updatePolish(id: UUID, outcome: PolishOutcome) throws {
    try write { db in
      try db.execute(
        sql: "UPDATE dictation SET polished_text = ?, polisher = ?, unpolished_reason = ? WHERE id = ?",
        arguments: [outcome.text, outcome.polisher.rawValue, outcome.unpolishedReason, id.uuidString])
    }
  }

  public func delete(id: UUID) throws {
    try write { db in
      try db.execute(sql: "DELETE FROM dictation WHERE id = ?", arguments: [id.uuidString])
    }
  }

  public func deleteAll() throws {
    try write { db in try db.execute(sql: "DELETE FROM dictation") }
  }

  public func recent(limit: Int) throws -> [Dictation] {
    try database.read { db in
      try DictationRecord.fetchAll(
        db, sql: "SELECT * FROM dictation ORDER BY created_at DESC LIMIT ?", arguments: [limit])
    }.map(\.dictation)
  }

  public func search(_ query: String, limit: Int) throws -> [Dictation] {
    guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return try recent(limit: limit) }
    return try database.read { db in
      try DictationRecord.fetchAll(
        db,
        sql: """
          SELECT dictation.* FROM dictation
          JOIN dictation_fts ON dictation_fts.rowid = dictation.rowid
          WHERE dictation_fts MATCH ?
          ORDER BY dictation.created_at DESC LIMIT ?
          """,
        arguments: [pattern, limit])
    }.map(\.dictation)
  }

  @discardableResult
  public func prune(before cutoff: Date) throws -> Int {
    let count = try database.write { db in
      try db.execute(sql: "DELETE FROM dictation WHERE created_at < ?", arguments: [cutoff.unixMilliseconds])
      return db.changesCount
    }
    if count > 0 {
      Log.store.info("pruned \(count, privacy: .public) dictations")
      NotificationCenter.default.post(name: Self.didChange, object: self)
    }
    return count
  }

  /// The number of rows in the full-text table, for tests.
  func ftsRowCount() throws -> Int {
    try database.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM dictation_fts") ?? 0 }
  }

  /// Runs raw SQL, for tests of the schema's constraints.
  func execute(_ sql: String, arguments: StatementArguments = []) throws {
    try database.write { db in try db.execute(sql: sql, arguments: arguments) }
  }

  private func write(_ updates: (Database) throws -> Void) throws {
    do {
      try database.write(updates)
    } catch {
      Log.store.error("write failed: \((error as? DatabaseError)?.resultCode.rawValue ?? -1, privacy: .public)")
      throw error
    }
    NotificationCenter.default.post(name: Self.didChange, object: self)
  }
}

/// A `dictation` row.
private struct DictationRecord: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "dictation"

  var id: String
  var createdAt: Int64
  var durationMs: Int
  var language: String
  var rawText: String
  var polishedText: String?
  var transcriber: String
  var polisher: String
  var unpolishedReason: String?
  var targetApp: String?
  var delivery: String

  enum CodingKeys: String, CodingKey {
    case id
    case createdAt = "created_at"
    case durationMs = "duration_ms"
    case language
    case rawText = "raw_text"
    case polishedText = "polished_text"
    case transcriber
    case polisher
    case unpolishedReason = "unpolished_reason"
    case targetApp = "target_app"
    case delivery
  }

  init(_ dictation: Dictation) {
    id = dictation.id.uuidString
    createdAt = dictation.createdAt.unixMilliseconds
    durationMs = dictation.durationMs
    language = dictation.language
    rawText = dictation.rawText
    polishedText = dictation.polishedText
    transcriber = dictation.transcriber.rawValue
    polisher = dictation.polisher.rawValue
    unpolishedReason = dictation.unpolishedReason
    targetApp = dictation.targetApp
    delivery = dictation.delivery.rawValue
  }

  var dictation: Dictation {
    Dictation(
      id: UUID(uuidString: id) ?? UUID(),
      createdAt: Date(timeIntervalSince1970: Double(createdAt) / 1000),
      durationMs: durationMs,
      language: language,
      rawText: rawText,
      polishedText: polishedText,
      transcriber: TranscriberKind(rawValue: transcriber) ?? .apple,
      polisher: PolisherKind(rawValue: polisher) ?? .none,
      unpolishedReason: unpolishedReason,
      targetApp: targetApp,
      delivery: Delivery(rawValue: delivery) ?? .copied)
  }
}

extension Date {
  var unixMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
}
