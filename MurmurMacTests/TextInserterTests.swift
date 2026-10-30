import AppKit
import MurmurKit
import Testing

@testable import Murmur

@MainActor
@Suite("TextInserter")
struct TextInserterTests {
  final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var items: [String] = ["previous clipboard"]
    var transientWrites = 0

    func saveItems() -> [NSPasteboardItem] {
      items.map { text in
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
      }
    }

    func restore(_ saved: [NSPasteboardItem]) {
      items = saved.compactMap { $0.string(forType: .string) }
      changeCount += 1
    }

    func write(_ text: String, transient: Bool) {
      items = [text]
      if transient { transientWrites += 1 }
      changeCount += 1
    }
  }

  final class FakePoster: PasteEventPoster {
    var succeeds = true
    var posts = 0
    var onPost: () -> Void = {}

    func postPaste() -> Bool {
      posts += 1
      onPost()
      return succeeds
    }
  }

  struct FakeFocus: FocusInspecting {
    var frontmostProcessID: Int32?
    func capture() -> TargetContext { TargetContext(bundleID: "app", processID: frontmostProcessID, acceptsText: true) }
  }

  let textEdit = TargetContext(bundleID: "com.apple.TextEdit", processID: 42, acceptsText: true)

  func inserter(
    pasteboard: FakePasteboard, poster: FakePoster = FakePoster(), frontmost: Int32? = 42
  ) -> TextInserter {
    TextInserter(pasteboard: pasteboard, poster: poster, focus: FakeFocus(frontmostProcessID: frontmost)) { _ in }
  }

  @Test func pastesAndRestoresTheClipboard() async {
    let pasteboard = FakePasteboard()
    let poster = FakePoster()
    var duringPaste: [String] = []
    poster.onPost = { duringPaste = pasteboard.items }
    let inserter = inserter(pasteboard: pasteboard, poster: poster)

    #expect(inserter.plannedDelivery(for: textEdit) == .pasted)
    let delivery = await inserter.deliver("Hello there.", planned: .pasted, target: textEdit)
    #expect(delivery == .pasted)
    #expect(poster.posts == 1)
    #expect(duringPaste == ["Hello there."])
    #expect(pasteboard.transientWrites == 1)
    #expect(pasteboard.items == ["previous clipboard"])
  }

  @Test func leavesANewerClipboardAlone() async {
    let pasteboard = FakePasteboard()
    let poster = FakePoster()
    let inserter = TextInserter(pasteboard: pasteboard, poster: poster, focus: FakeFocus(frontmostProcessID: 42)) { _ in
      // The user copies something while the paste lands.
      await MainActor.run { pasteboard.write("copied meanwhile", transient: false) }
    }
    #expect(await inserter.deliver("Hello.", planned: .pasted, target: textEdit) == .pasted)
    #expect(pasteboard.items == ["copied meanwhile"])
  }

  @Test func copiesWhenAnotherAppIsInFront() async {
    let pasteboard = FakePasteboard()
    let poster = FakePoster()
    let inserter = inserter(pasteboard: pasteboard, poster: poster, frontmost: 7)
    #expect(inserter.plannedDelivery(for: textEdit) == .copied)
    #expect(await inserter.deliver("Hello.", planned: .pasted, target: textEdit) == .copied)
    #expect(poster.posts == 0)
    #expect(pasteboard.items == ["Hello."])
    #expect(pasteboard.transientWrites == 0)
  }

  @Test func copiesWhenTheFieldDidNotTakeText() async {
    let pasteboard = FakePasteboard()
    let inserter = inserter(pasteboard: pasteboard)
    let noField = TargetContext(bundleID: "com.apple.finder", processID: 42, acceptsText: false)
    #expect(inserter.plannedDelivery(for: noField) == .copied)
    #expect(await inserter.deliver("Hello.", planned: .copied, target: noField) == .copied)
    #expect(pasteboard.items == ["Hello."])
  }

  @Test func copiesWhenThePasteCannotBePosted() async {
    let pasteboard = FakePasteboard()
    let poster = FakePoster()
    poster.succeeds = false
    let inserter = inserter(pasteboard: pasteboard, poster: poster)
    #expect(await inserter.deliver("Hello.", planned: .pasted, target: textEdit) == .copied)
    #expect(pasteboard.items == ["Hello."])
  }

  @Test func hotkeyMasksTellRightModifiersFromLeft() {
    #expect(HotkeyMonitor.isDown(.rightOption, flags: CGEventFlags(rawValue: 0x80040)))
    #expect(!HotkeyMonitor.isDown(.rightOption, flags: CGEventFlags(rawValue: 0x80020)))
    #expect(HotkeyMonitor.isDown(.rightCommand, flags: CGEventFlags(rawValue: 0x100010)))
    #expect(!HotkeyMonitor.isDown(.rightCommand, flags: CGEventFlags(rawValue: 0x100008)))
    #expect(HotkeyMonitor.isDown(.fn, flags: .maskSecondaryFn))
    #expect(HotkeyMonitor.keyCode(for: .fn) == 63)
  }

  @Test func historyGroupsByDay() {
    let calendar = Calendar.current
    let now = Date()
    let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
    let make = { (date: Date) in
      Dictation(
        createdAt: date, durationMs: 1, language: "en-US", rawText: "x", polishedText: nil, transcriber: .apple,
        polisher: .none, unpolishedReason: "apple:timed-out", targetApp: nil, delivery: .pasted)
    }
    let days = HistoryView.days([make(now), make(now), make(yesterday)])
    #expect(days.map(\.title) == ["Today", "Yesterday"])
    #expect(days.map(\.items.count) == [2, 1])
    #expect(
      HistoryView.notPolishedText("apple:unavailable:apple-intelligence-off")
        == "Not polished: Apple Intelligence is off")
    #expect(HistoryView.notPolishedText("apple:timed-out") == "Not polished: polishing took too long")
  }
}
