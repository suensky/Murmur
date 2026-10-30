import Foundation
import Testing

@testable import MurmurKit

@Suite("Store")
struct StoreTests {
  func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "murmur-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      .appending(path: "Murmur", directoryHint: .isDirectory)
      .appending(path: "library.db")
  }

  @Test func migratesAnEmptyFileWithPrivatePermissions() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
    let store = try LibraryStore(url: url)
    try store.save(sampleDictation())
    let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    let file = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((folder[.posixPermissions] as? Int) == 0o700)
    #expect((file[.posixPermissions] as? Int) == 0o600)

    // Opening again runs no migration twice and keeps the rows.
    let reopened = try LibraryStore(url: url)
    #expect(try reopened.recent(limit: 10).count == 1)
  }

  @Test func savesAndReadsBackNewestFirst() throws {
    let store = try LibraryStore.inMemory()
    let older = sampleDictation(text: "Older.", createdAt: Date(timeIntervalSince1970: 1_000))
    let newer = sampleDictation(text: "Newer.", createdAt: Date(timeIntervalSince1970: 2_000))
    try store.save(older)
    try store.save(newer)
    #expect(try store.recent(limit: 10) == [newer, older])
    #expect(try store.recent(limit: 1) == [newer])
  }

  @Test func searchStaysInSyncThroughInsertUpdateAndDelete() throws {
    let store = try LibraryStore.inMemory()
    let first = sampleDictation(text: "Move the design review to Thursday.", raw: "move the design review to thursday")
    let second = sampleDictation(text: "Pick up the dry cleaning.", raw: "pick up the dry cleaning")
    try store.save(first)
    try store.save(second)
    #expect(try store.ftsRowCount() == 2)
    #expect(try store.search("thurs", limit: 10).map(\.id) == [first.id])
    #expect(try store.search("design review", limit: 10).map(\.id) == [first.id])

    try store.updatePolish(
      id: second.id, outcome: PolishOutcome(text: "Pick up the laundry.", polisher: .apple, unpolishedReason: nil))
    #expect(try store.search("laundry", limit: 10).map(\.id) == [second.id])

    try store.delete(id: first.id)
    #expect(try store.search("thursday", limit: 10).isEmpty)
    #expect(try store.ftsRowCount() == 1)

    // An empty query lists everything.
    #expect(try store.search("  ", limit: 10).map(\.id) == [second.id])
    try store.deleteAll()
    #expect(try store.recent(limit: 10).isEmpty)
    #expect(try store.ftsRowCount() == 0)
  }

  @Test func updatesDeliveryAndPolish() throws {
    let store = try LibraryStore.inMemory()
    let dictation = sampleDictation()
    try store.save(dictation)
    try store.updateDelivery(id: dictation.id, to: .copied)
    try store.updatePolish(
      id: dictation.id, outcome: PolishOutcome(text: nil, polisher: .none, unpolishedReason: "apple:timed-out"))
    let row = try #require(try store.recent(limit: 1).first)
    #expect(row.delivery == .copied)
    #expect(row.polishedText == nil)
    #expect(row.polisher == .none)
    #expect(row.unpolishedReason == "apple:timed-out")
    #expect(row.text == dictation.rawText)
  }

  @Test func retentionPrunesOlderRows() throws {
    let store = try LibraryStore.inMemory()
    let old = sampleDictation(createdAt: Date(timeIntervalSince1970: 1_000))
    let recent = sampleDictation(createdAt: Date(timeIntervalSince1970: 9_000_000))
    try store.save(old)
    try store.save(recent)
    let cutoff = try #require(Retention.days7.cutoff(now: Date(timeIntervalSince1970: 9_100_000)))
    #expect(try store.prune(before: cutoff) == 1)
    #expect(try store.recent(limit: 10) == [recent])
    #expect(try store.prune(before: cutoff) == 0)
  }

  @Test(arguments: [
    "INSERT INTO dictation VALUES ('a', 0, 0, 'en-US', 'x', NULL, 'whisper', 'apple', NULL, NULL, 'pasted')",
    "INSERT INTO dictation VALUES ('b', 0, 0, 'en-US', 'x', NULL, 'apple', 'gpt', NULL, NULL, 'pasted')",
    "INSERT INTO dictation VALUES ('c', 0, 0, 'en-US', 'x', NULL, 'apple', 'apple', NULL, NULL, 'typed')",
    "INSERT INTO dictation VALUES ('d', 0, 0, 'en-US', NULL, NULL, 'apple', 'apple', NULL, NULL, 'pasted')",
  ])
  func checkConstraintsRejectBadRows(sql: String) throws {
    let store = try LibraryStore.inMemory()
    #expect(throws: (any Error).self) { try store.execute(sql) }
  }

  @Test func postsChanges() async throws {
    let store = try LibraryStore.inMemory()
    let changes = NotificationCenter.default.notifications(named: LibraryStore.didChange, object: store)
    try store.save(sampleDictation())
    let iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() != nil)
  }
}
