import AppKit
import MurmurKit

/// The Mac's input and output around a `DictationSession`: the hotkey drives
/// it, the HUD shows it, `TextInserter` delivers its result.
@MainActor
@Observable
final class DictationController {
  private(set) var session: DictationSession?

  @ObservationIgnored private unowned let model: AppModel
  @ObservationIgnored private let hud = HUDController()
  @ObservationIgnored private let inserter = TextInserter()
  @ObservationIgnored private let focus = SystemFocus()
  @ObservationIgnored private var gesture = GestureRecognizer()
  @ObservationIgnored private var monitor: HotkeyMonitor!
  @ObservationIgnored private var tickTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  init(model: AppModel) {
    self.model = model
    monitor = HotkeyMonitor { [weak self] event in self?.handle(event) }
    hud.model.onStop = { [weak self] in self?.finish() }
    hud.model.onDownload = { [weak self] language in
      self?.model.downloadSpeechModel(language: language)
      self?.hud.hide()
    }
    hud.model.onAllowMicrophone = { [weak self] in
      self?.hud.hide()
      Task { _ = await Permissions.requestMicrophone() }
    }
    observeSleep()
  }

  var hotkeyRunning: Bool { monitor.isRunning }

  /// Starts the hotkey, once Accessibility allows it.
  func start() {
    monitor.setTrigger(model.settings.triggerKey)
    monitor.start()
  }

  func triggerKeyChanged() {
    gesture.reset()
    monitor.setTrigger(model.settings.triggerKey)
  }

  // MARK: Menu

  /// *Start Dictation* in the menu: hands-free until a tap, ⎋ or the stop button.
  func toggleFromMenu() {
    if session != nil {
      finish()
    } else {
      begin(handsFree: true)
    }
  }

  func finish() {
    gesture.reset()
    monitor.setSwallowsEscape(false)
    session?.finish()
  }

  // MARK: Hotkey

  private func handle(_ event: HotkeyMonitor.Event) {
    let action: GestureRecognizer.Action?
    switch event {
    case .trigger(let down, let time):
      action = gesture.handle(down ? .keyDown(at: time) : .keyUp(at: time))
    case .escape(let time):
      // Esc also cancels a menu-started dictation, which the gesture does not know.
      if !gesture.isActive, session != nil, session?.phase != .done {
        session?.cancel()
        action = nil
      } else {
        action = gesture.handle(.escape(at: time))
      }
    case .otherKey:
      // A shortcut with the trigger key held, not a dictation.
      if gesture.isFirstPressDown {
        gesture.reset()
        session?.cancel()
      }
      action = nil
    }
    if let action { perform(action) }
    monitor.setSwallowsEscape(gesture.isActive || session != nil)
    scheduleTick()
  }

  private func perform(_ action: GestureRecognizer.Action) {
    switch action {
    case .start:
      if session != nil {
        // The last dictation is still finishing; ignore this press.
        gesture.reset()
      } else {
        begin(handsFree: false)
      }
    case .handsFree:
      hud.model.handsFree = true
    case .finish:
      session?.finish()
    case .cancel, .discard:
      session?.cancel()
    }
  }

  /// Sends the recognizer a tick at its deadline, to discard a lone tap.
  private func scheduleTick() {
    tickTask?.cancel()
    guard let deadline = gesture.deadline else { return }
    let delay = max(deadline - HotkeyMonitor.now(), 0)
    tickTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(delay))
      guard !Task.isCancelled, let self else { return }
      if let action = self.gesture.handle(.tick(at: HotkeyMonitor.now())) { self.perform(action) }
      self.monitor.setSwallowsEscape(self.gesture.isActive || self.session != nil)
    }
  }

  // MARK: Session

  private func begin(handsFree: Bool) {
    let target = focus.capture()
    let environment = DictationEnvironment.live(store: model.store, delivery: inserter, zoomKeys: model.zoomKeys)
    let session = DictationSession(environment: environment)
    self.session = session
    hud.show(session, handsFree: handsFree)
    monitor.setSwallowsEscape(true)
    let config = DictationConfig(
      engine: model.settings.engine, language: model.settings.language, zoomKeyStored: model.zoomKeys.hasKey)
    Task {
      let outcome = await session.run(config: config, target: target)
      ended(session, outcome: outcome)
    }
  }

  private func ended(_ ended: DictationSession, outcome: DictationOutcome) {
    guard session === ended else { return }
    session = nil
    gesture.reset()
    monitor.setSwallowsEscape(false)
    if ended.zoomKeyRejected { model.settings.zoomKeyRejected = true }
    switch outcome {
    case .delivered(let dictation, let saved):
      if !saved {
        hud.show(.couldntSave)
      } else if dictation.delivery == .copied {
        hud.show(.copied)
      } else {
        hud.hide()
      }
    case .cancelled:
      hud.hide()
    case .failed(.microphoneUnavailable):
      hud.show(.microphoneNeeded)
    case .failed(.speechModelMissing(let language)):
      hud.show(.speechModelNeeded(language: language))
    case .failed(.nothingHeard), .failed(.couldntTranscribe):
      hud.show(.couldntTranscribe)
    }
  }

  /// Sleep or lock while recording: the dictation finishes with what it has.
  private func observeSleep() {
    let finish: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.session?.finish() }
    }
    let workspace = NSWorkspace.shared.notificationCenter
    observers.append(
      workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: finish))
    observers.append(
      workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: finish))
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main, using: finish))
  }
}
