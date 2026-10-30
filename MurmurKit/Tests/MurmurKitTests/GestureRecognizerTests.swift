import Testing

@testable import MurmurKit

@Suite("GestureRecognizer")
struct GestureRecognizerTests {
  typealias Input = GestureRecognizer.Input
  typealias Action = GestureRecognizer.Action

  /// Feeds inputs and returns the actions, nil ones dropped.
  func run(_ inputs: [Input]) -> (actions: [Action], recognizer: GestureRecognizer) {
    var recognizer = GestureRecognizer()
    let actions = inputs.compactMap { recognizer.handle($0) }
    return (actions, recognizer)
  }

  @Test func holdStartsAtOnceAndFinishesOnRelease() {
    let (actions, recognizer) = run([.keyDown(at: 0), .keyUp(at: 250)])
    #expect(actions == [.start, .finish])
    #expect(!recognizer.isActive)
  }

  @Test func firstPressIsUndecidedUntilReleased() {
    var recognizer = GestureRecognizer()
    _ = recognizer.handle(.keyDown(at: 0))
    #expect(recognizer.isFirstPressDown)
    _ = recognizer.handle(.keyUp(at: 100))
    #expect(!recognizer.isFirstPressDown)
  }

  @Test func releaseJustUnderTheHoldThresholdIsATap() {
    let (actions, recognizer) = run([.keyDown(at: 0), .keyUp(at: 249)])
    #expect(actions == [.start])
    #expect(recognizer.isActive)
    #expect(recognizer.deadline == 300)
  }

  @Test func doubleTapIsHandsFreeAndTheNextTapFinishes() {
    let (actions, recognizer) = run([
      .keyDown(at: 0), .keyUp(at: 80), .keyDown(at: 300), .keyUp(at: 360),
      .keyDown(at: 5_000), .keyUp(at: 5_080),
    ])
    #expect(actions == [.start, .handsFree, .finish])
    #expect(!recognizer.isActive)
  }

  @Test func handsFreeIgnoresTicks() {
    let (actions, _) = run([.keyDown(at: 0), .keyUp(at: 80), .keyDown(at: 200), .tick(at: 400), .keyUp(at: 900)])
    #expect(actions == [.start, .handsFree])
  }

  @Test func loneShortTapIsDiscardedWhenTheWindowCloses() {
    var recognizer = GestureRecognizer()
    #expect(recognizer.handle(.keyDown(at: 0)) == .start)
    #expect(recognizer.handle(.keyUp(at: 100)) == nil)
    #expect(recognizer.handle(.tick(at: 299)) == nil)
    #expect(recognizer.handle(.tick(at: 300)) == .discard)
    #expect(!recognizer.isActive)
    #expect(recognizer.deadline == nil)
  }

  @Test func secondPressAfterTheWindowDiscards() {
    let (actions, _) = run([.keyDown(at: 0), .keyUp(at: 100), .keyDown(at: 301)])
    #expect(actions == [.start, .discard])
  }

  @Test(arguments: [
    [Input.keyDown(at: 0), .escape(at: 100)],
    [Input.keyDown(at: 0), .keyUp(at: 100), .escape(at: 150)],
    [Input.keyDown(at: 0), .keyUp(at: 50), .keyDown(at: 100), .escape(at: 2_000)],
  ])
  func escapeCancelsAtAnyStage(_ inputs: [Input]) {
    let (actions, recognizer) = run(inputs)
    #expect(actions.last == .cancel)
    #expect(!recognizer.isActive)
  }

  @Test func escapeWhenIdleIsNotOurs() {
    var recognizer = GestureRecognizer()
    #expect(!recognizer.isActive)
    #expect(recognizer.handle(.escape(at: 0)) == nil)
  }

  @Test func resetForgetsTheGesture() {
    var recognizer = GestureRecognizer()
    _ = recognizer.handle(.keyDown(at: 0))
    recognizer.reset()
    #expect(!recognizer.isActive)
    #expect(recognizer.handle(.keyUp(at: 400)) == nil)
    #expect(recognizer.handle(.keyDown(at: 500)) == .start)
  }

  @Test func aMissingKeyUpAfterFinishingStartsAgain() {
    let (actions, _) = run([
      .keyDown(at: 0), .keyUp(at: 50), .keyDown(at: 100), .keyUp(at: 150), .keyDown(at: 1_000), .keyDown(at: 2_000),
    ])
    #expect(actions == [.start, .handsFree, .finish, .start])
  }
}
