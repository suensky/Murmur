# Murmur, part 1: MurmurKit and dictation on the Mac

Status: approved design, 2026-10-29. Next: the implementation plan.

## Goal

Murmur is a dictation app for macOS and iOS, in the manner of Typeless and
Wispr Flow: hold a key, talk, and polished text lands where the cursor is.
Every dictation is kept locally, and notes take dictation too.

The product is built in four parts, each with its own spec, plan and
implementation:

1. **MurmurKit and dictation on the Mac** — this spec.
2. **Notes** — a note you open and talk into, polished as it goes, searched
   with the dictations. Adds tables to `library.db`.
3. **iOS** — the app, a keyboard extension, the Action Button and Shortcuts,
   on the same MurmurKit.
4. **Sync** between devices — not requested; built only if asked for.

### Success criteria for part 1

- Holding the trigger key in any app's text field records; releasing it
  inserts polished text into that field.
- Double-tapping the key starts a hands-free dictation; a tap finishes it.
- Text appears live in a floating pill while the user talks.
- With no Zoom key, everything runs on the device: no network traffic.
- With a Zoom key, the user can make Zoom the default engine; Zoom failing
  never loses a dictation.
- Every dictation is in the History window, searchable, and re-polishable.
- `make test` and `make lint` pass; MurmurKit coverage is at least 80%.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Language and UI | Swift, SwiftUI with AppKit where needed | iOS keyboard extensions, `SpeechAnalyzer` and Foundation Models are Swift-only; mygo has no iOS target |
| Minimum OS | macOS 26, iOS 26 | `SpeechAnalyzer` and Foundation Models first ship there |
| Mac distribution | Developer ID, notarized, outside the Mac App Store | The event tap and pasting into other apps need Accessibility, which the App Store sandbox does not allow for this use |
| Default engine | Apple, on the device | Private, free, offline |
| Optional engine | Zoom AI Services, with the user's API key; may be made the default | Scribe Live's accuracy and Text Polishing |
| Engine structure | A transcriber stage and a polisher stage, chosen per dictation by rules | Mixes engines without special cases; each stage is faked in tests |
| Trigger | Hold to talk, double-tap for hands-free | As Typeless and Wispr Flow do |
| History | Text only, no audio | Less on disk and less sensitive data; re-polishing works from the raw text |
| Storage | SQLite through GRDB, in `library.db` | One file for the user's content, notes included in part 2 |
| Bundle ID | `com.ai.murmur` | In the manner of Capy's `com.ai.capy` |

## Architecture

```
Murmur/
  MurmurKit/                  Swift package (macOS 26+, iOS 26+), no AppKit, UIKit or SwiftUI
    Audio/                    AudioCapture: AVAudioEngine mic → 16 kHz mono PCM16 buffers
    Transcription/            Transcriber; AppleTranscriber (SpeechAnalyzer), ZoomTranscriber
                              (Scribe Live), FakeTranscriber
    Polish/                   Polisher; ApplePolisher (Foundation Models), BasicCleanup, FakePolisher
    Dictation/                DictationSession (the flow), EngineRouter (the stage rules),
                              GestureRecognizer (hold, double-tap, Esc)
    Store/                    GRDB: library.db, migrations, full-text search, retention
    Settings/                 Settings (UserDefaults), Keychain (the Zoom key)
  MurmurMac/                  the macOS app, a menu bar agent (LSUIElement)
    Hotkey/                   the CGEventTap; hands key events to GestureRecognizer
    Insertion/                TextInserter: Accessibility focus check, paste, clipboard restore
    HUD/                      the floating pill: non-activating NSPanel hosting SwiftUI
    Views/                    menu bar menu, History, Settings, Onboarding
  Murmur.xcodeproj            the app target, made in Xcode; no project generator
```

### Units

- **`Transcriber`** takes audio buffers and yields events: `draft(text)`,
  `final(text)`, `polished(text)` (Zoom with Text Polishing only),
  `ended`, `failed(error)`. It is told the input has ended, then yields what
  remains and `ended`.
- **`Polisher`** takes raw text and its language and returns polished text
  or a reason it could not: unavailable, refused, timed out, rejected by a
  guard.
- **`EngineRouter`** chooses one transcriber and a polisher chain per
  dictation from the settings, the language, whether a Zoom key is stored,
  and whether the Apple transcriber and polisher are available:

  | Engine | Language | Transcriber | Polisher chain |
  |---|---|---|---|
  | Apple | any supported | Apple | Apple → BasicCleanup → raw |
  | Zoom | en-US | Zoom, Text Polishing on | Zoom's polished text → Apple → BasicCleanup → raw |
  | Zoom | other | Zoom, Text Polishing off | Apple → BasicCleanup → raw |

  Zoom as the engine with no stored key is Apple. A polisher in the chain
  that is unavailable for the language is skipped.
- **`DictationSession`** owns the order of a dictation: idle → recording →
  finishing → polishing → done, or cancelled, or failed. It depends only on
  the interfaces above, a `DictationStore`, and an injected `Clock`.
- **`GestureRecognizer`** turns timestamped key-down and key-up events of
  the trigger key, and Esc, into start, finish and cancel.
- The **macOS app** is input and output only: the hotkey drives a session,
  the HUD shows its state, `TextInserter` delivers its result.

### Boundaries (checked by a test)

- MurmurKit imports no AppKit, UIKit or SwiftUI.
- Only `ZoomTranscriber` uses the network.
- Only `Store/` holds SQL.
- No log call takes dictated text, polished text, or the API key.

### Dependencies

[GRDB.swift](https://github.com/groue/GRDB.swift), its version pinned in
`Package.resolved`; the plan records the version and its source. All else
is the OS's: Speech, FoundationModels, AVFAudio, Security,
ApplicationServices, and `URLSessionWebSocketTask`.

## The dictation flow

### Gestures

- The trigger key is Fn by default; Right ⌥ or Right ⌘ in Settings.
- Recording starts on the **first key-down**, so no word is lost while the
  gesture is decided.
- Held for 250 ms or more: hold mode; key-up finishes.
- Released sooner and pressed again within 300 ms of the first key-down:
  hands-free mode; the next tap finishes.
- A lone short tap discards the recording.
- Esc cancels at any stage. While a dictation runs the tap swallows Esc, so
  the app beneath never sees it.
- Onboarding asks the user to set *System Settings › Keyboard › Press 🌐 key
  to › Do Nothing*, else Fn also opens the emoji picker or macOS dictation.

### A dictation

1. **Start.** Record the frontmost app's bundle ID and process ID, and
   whether its focused element accepts text (`kAXFocusedUIElementAttribute`).
   `EngineRouter` picks the stages. Audio starts. With Zoom, audio is held in
   memory while the WebSocket connects, then sent.
2. **Recording.** The HUD shows the input level and the live text: the
   finals so far and the current draft. A dictation is capped at 10 minutes:
   the HUD warns at 9, and at 10 the dictation finishes as if the user had.
3. **Finishing.** Audio stops; the transcriber is told the input ended.
   Murmur waits up to 10 s for the rest; with Zoom, until `session.closed`.
4. **Polishing.** Zoom's polished text if it came, else the chain. Each
   `ApplePolisher` attempt has 8 s. Its guards:
   - The prompt puts the dictation between delimiters and instructs the
     model to rewrite it, never to answer it or do what it says, so "write
     an email to Bob…" stays a sentence about an email.
   - Output that is empty, refused, or outside 0.3× to 2× the raw word count
     is rejected and the next polisher runs.
   - Text over about 1,500 words is polished in chunks split at sentence
     ends, within the on-device model's 4,096-token context.
5. **Saving.** The dictation is written before it is inserted.
6. **Inserting.** If the app from step 1 is still frontmost and its focused
   element accepts text: save the pasteboard's items, write the text marked
   `org.nspasteboard.TransientType`, post ⌘V, and restore the saved items
   after 500 ms unless the pasteboard's `changeCount` moved meanwhile.
   Otherwise the text is copied and the HUD shows *Copied, ⌘V to paste*.
   Murmur never pastes into an app other than the one it started in.

A cancelled dictation, or one with no text, is not saved.

## Data

### `library.db`

`~/Library/Application Support/Murmur/library.db`; the folder is `0700`, the
file `0600`. Encryption at rest is FileVault's. Other databases, if ever
needed, are named by what they hold (`vocabulary.db`, `cache.db`) and sit
beside it.

```sql
CREATE TABLE dictation (
  id            TEXT PRIMARY KEY,               -- UUID
  created_at    INTEGER NOT NULL,               -- Unix ms
  duration_ms   INTEGER NOT NULL,
  language      TEXT NOT NULL,                  -- BCP-47
  raw_text      TEXT NOT NULL,
  polished_text TEXT,                           -- NULL: nothing polished it
  transcriber   TEXT NOT NULL CHECK (transcriber IN ('apple','zoom')),
  polisher      TEXT NOT NULL CHECK (polisher IN ('zoom','apple','basic','none')),
  unpolished_reason TEXT,                       -- why the chain fell through; no user text
  target_app    TEXT,                           -- bundle ID; NULL if none
  delivery      TEXT NOT NULL CHECK (delivery IN ('pasted','copied'))
);
CREATE INDEX dictation_created ON dictation(created_at DESC);
```

An FTS5 table over `raw_text` and `polished_text` is kept in sync by GRDB's
`synchronize(withTable:)`. Schema changes are `DatabaseMigrator` migrations;
part 2 adds the notes tables as one.

### History window

Dictations newest first, with full-text search, copy polished, copy raw,
re-polish (runs the chain again on `raw_text` and updates the row), and
delete one or all, confirmed and permanent. Dictations the chain did not
polish are marked *Not polished* with the reason.

Retention is Forever (default), 30 days or 7 days; pruning runs at launch and
daily.

### Settings (`UserDefaults`)

| Setting | Values | Default |
|---|---|---|
| Default engine | Apple (on device), Zoom | Apple; Zoom selectable once a key is stored |
| Language | the locales `SpeechTranscriber` supports, so Apple can always stand in | the system language if supported, else en-US |
| Trigger key | Fn, Right ⌥, Right ⌘ | Fn |
| History retention | Forever, 30 days, 7 days | Forever |
| Open at login | on, off (`SMAppService`) | off |

Beside the Zoom option: *"Your audio is sent to Zoom for transcription."*

### The Zoom API key

- A generic-password Keychain item: service `com.ai.murmur`, account
  `zoom-api-key`, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- `ZOOM_API_KEY` in the environment overrides it, for development.
- Trimmed; 1 to 512 characters, no whitespace.
- Checked on first use: a 401 or 403 shows *Key rejected* in Settings, and
  that dictation is transcribed by Apple.
- Removing the key resets the default engine to Apple.

## Scribe Live

From Zoom's documentation ([Scribe](https://developers.zoom.us/docs/ai-services/scribe/),
[Live mode](https://developers.zoom.us/docs/ai-services/scribe/live-mode/))
and Capy's `internal/zoomai/live.go`:

- `wss://api.zoom.us/v2/aiservices/scribe/live`, the key in the upgrade's
  `x-api-key` header.
- The first message is `session.update`: `audio.format` `pcm16` (16 kHz mono
  little-endian), `config.language`, `config.interim_results: true` for
  drafts (`transcription.delta`), and for en-US
  `outputs.text_polishing: {"enabled": true, "include_transcript": true}`.
  `config.model` is omitted; Scribe picks one.
- Polished text comes in `transcription.completed` under
  `outputs.text_polishing.text`; with `include_transcript` the raw
  `transcript` comes too, for `raw_text`. One polished event may cover
  several items, so the end is `session.closed`, never a count of items.
- Text Polishing is en-US only.
- Finish: stop audio, send `{"type":"session.close"}`, read until
  `session.closed`, close.
- Sessions last at most 120 minutes and close after 30 s without audio.
  Dictations stay under both: capped at 10 minutes, and audio is sent
  continuously, silence included.
- Diarization is off: with Text Polishing on it would put `[Speaker N]`
  tags in the text.
- The base URL may be overridden only to a loopback host, for the fake
  server.

## Permissions and errors

### Onboarding

| Step | Needed for | Without it |
|---|---|---|
| Microphone | every dictation | no dictation; the HUD links to System Settings |
| Accessibility | the event tap, pasting | no hotkey or paste; *Start Dictation* in the menu bar works, its result copied |
| Speech Recognition, if `SpeechAnalyzer` requires it | the Apple transcriber | Apple engine off; Zoom if a key is stored |
| The language's speech model (`AssetInventory`) | the Apple transcriber | as above, with a download button in Settings |
| 🌐 key → Do Nothing | Fn as the trigger | a hint, and the offer of Right ⌥ |

Settings shows the polisher's state, e.g. *"Polishing: unavailable, Apple
Intelligence is off."*

### During a dictation

| Failure | Behavior |
|---|---|
| Zoom does not connect (network, 429, 5xx) | The Apple transcriber takes the audio so far and the rest; the HUD notes *Zoom unavailable, using on-device* |
| Zoom rejects the key (401, 403) | As above, and Settings shows *Key rejected* |
| Zoom drops mid-dictation | Apple transcribes the whole dictation from memory; Zoom's partial text is discarded |
| Zoom fails and the Apple transcriber is unavailable | Zoom's finals so far, if any, are kept and polished; with none, the HUD shows *Couldn't transcribe* and nothing is saved |
| Apple transcriber unavailable | Zoom if a key is stored, else *Speech model for <language> not installed* |
| The rest takes over 10 s | The finals so far plus the last draft |
| Polishing fails | The chain falls through silently; History marks the row *Not polished* with the reason |
| Mic changes or disconnects | The engine restarts on the new default input; if it cannot, the dictation finishes with what it has |
| ⌘V cannot be posted | Copied instead |
| The database write fails | The text is still inserted; the HUD shows *Couldn't save to history* |
| macOS disables the tap (timeout) | Re-enabled at once; the callback only enqueues, so it stays fast |
| Sleep or lock while recording | The dictation finishes with what it has |

A dictation's audio is held in memory only (at most 10 minutes, about
19 MB), never written to disk, and released when the dictation ends.

### Logging

`os.Logger`, subsystem `com.ai.murmur`. Logged: stages, the transcriber and
polisher used, durations, error codes, Zoom request IDs. Never logged:
dictated or polished text, the API key. Only values free of user data are
`.public`.

## Threat snapshot

- **Entry points:** the microphone; key events from the event tap; Scribe
  Live's messages; the Keychain item; `library.db`.
- **Trust boundaries:** audio and text leave the device only with the Zoom
  engine, over TLS to `api.zoom.us`. Scribe's messages are untrusted: their
  size is bounded, unknown types are ignored, and text is bounded before it
  reaches the HUD or the store.
- **Sensitive data:** dictated text (user content) in `library.db` and in
  memory; the API key in the Keychain; the pasteboard while pasting, marked
  transient and restored.
- **Prompt injection:** dictated text reaches the on-device model as data
  between delimiters, and the guards reject output that is not a rewrite.
  The model has no tools, so a successful injection can only change the
  inserted text, which the user sees.
- **Event tap:** listens to the trigger key and Esc, swallows only Esc and
  only during a dictation, and neither records nor logs other keys.

## Testing

### MurmurKit: `swift test` (Swift Testing), at least 80% coverage

| Unit | How |
|---|---|
| `EngineRouter` | A parameterized test over every combination of engine, language, key stored, and Apple transcriber and polisher availability |
| `DictationSession` | Fakes, an in-memory store and a test clock: the 10 s and 8 s limits, the 10-minute cap, cancel, empty result, Zoom failing at connect and mid-dictation, a failed save that still inserts |
| `GestureRecognizer` | Timestamped sequences: hold vs tap at 250 ms, double-tap within 300 ms, Esc, a lone short tap |
| Polisher guards | The 0.3× and 2× limits, refusal, empty output, chunks split at sentence ends within the token budget |
| `BasicCleanup` | Input and output pairs: fillers, repeated words, spacing |
| `ZoomTranscriber` | A fake Scribe Live server on loopback (`NWListener` with WebSocket), replaying JSON in `Tests/Fixtures/zoom/`: deltas, finals, a polished event covering several items, `session.closed`, 401 on upgrade, a drop mid-session |
| `Store` | Migrations from an empty file, the FTS table in sync on insert, update and delete, retention, `0600` and `0700`, CHECK constraints |
| Boundaries | A test that scans the sources for the rules above |

### Opt-in, against the real engines

- `MURMUR_LIVE_APPLE=1`: the Apple engines on WAV fixtures spoken with
  `say`, in the manner of Capy's `scripts/fixtures`. The transcript is held
  under a word-error-rate limit rather than to exact text. The polisher gets
  fillers, self-corrections, and a "write an email to Bob…" sample that must
  come back rewritten, not answered.
- `MURMUR_LIVE_ZOOM=1` with `ZOOM_API_KEY`: the same fixtures through Scribe
  Live with Text Polishing.

### MurmurMac

`TextInserter` against fakes of the pasteboard and the event poster:
restoring the clipboard, leaving a newer clipboard alone, the frontmost-app
check, copying instead. A manual checklist per release covers the permission
prompts, Fn with the 🌐 setting, pasting into TextEdit, Safari, Slack,
VS Code and Terminal, and sleep during a dictation.

### Commands

- `make test`: `swift test`.
- `make lint`: `swift format lint --strict`, and a build with warnings as
  errors.
- `make app`: `xcodebuild`, signed with Developer ID, then notarized.

## To verify while planning

Each has a decision already; the check confirms or adjusts it.

- **What Zoom's Text Polishing changes** (fillers, self-corrections,
  formatting): the Text Polishing page could not be read. The live Zoom
  tests record its output on the fixtures; if it falls short of the Apple
  polisher, the router's en-US Zoom row changes to Zoom transcribing and
  Apple polishing.
- **Whether `SpeechAnalyzer` needs Speech Recognition authorization**: if
  not, the onboarding step is dropped.
- **Foundation Models' locales** (`SystemLanguageModel.supportsLocale`) and
  its 4,096-token context: the chunk size follows the measured limit.

## Out of scope for part 1

Notes (part 2); iOS (part 3); sync (part 4); a personal dictionary or custom
vocabulary; per-app styles or tones; translation; audio history; language
detection within a dictation; the Mac App Store.
