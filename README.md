# Murmur

Dictation for macOS: hold a key, talk, and polished text lands where the cursor is.
Every dictation is kept locally in History. Design: [docs/](docs/2026-10-29-murmur-mac-dictation-design.md).

- **Hold** the trigger key (fn by default) to talk; release to insert.
- **Double-tap** for hands-free; tap again to finish. **Esc** cancels.
- On-device by default (Apple `SpeechAnalyzer` + Foundation Models); Zoom Scribe Live is optional with your API key.

## Layout

| Path | What |
|---|---|
| `MurmurKit/` | Swift package (macOS 26+, iOS 26+), no UI frameworks: audio, transcribers, polishers, the dictation flow, `library.db` |
| `MurmurMac/` | The menu bar app: event tap, text insertion, HUD, History, Settings, Onboarding |
| `MurmurMacTests/` | `TextInserter` against fakes |
| `Murmur.xcodeproj` | The app target (folder-synchronized; add files on disk) |

## Commands

```sh
make test       # swift test in MurmurKit, then the app's tests
make lint       # swift format lint --strict, builds with warnings as errors
make coverage   # MurmurKit line coverage (bar: 80%)
make run        # Debug build, then launch
make app        # Release build in .build/export, signed, not notarized
```

Live tests against the real engines, on fixtures spoken with `say`:

```sh
make fixtures
cd MurmurKit && MURMUR_LIVE_APPLE=1 swift test --filter LiveEngineTests
cd MurmurKit && MURMUR_LIVE_ZOOM=1 ZOOM_API_KEY=… swift test --filter LiveEngineTests
```

Both configurations sign with the Apple Development certificate of team Q9A5RCTM73
(suensky2@outlook.com). The app is not notarized, so it runs on this Mac but other Macs'
Gatekeeper will block it. The signature stays the same across rebuilds, so the
Accessibility grant carries over.

## Dependencies

[GRDB.swift](https://github.com/groue/GRDB.swift) 7.11.1, pinned in `MurmurKit/Package.resolved`. Everything else is the OS's.
