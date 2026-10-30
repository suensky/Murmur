# Murmur: `make test`, `make lint`, `make app`.

PROJECT := Murmur.xcodeproj
SCHEME := Murmur
DERIVED := .build/xcode
SWIFT_SOURCES := MurmurKit/Sources MurmurKit/Tests MurmurKit/Package.swift MurmurMac MurmurMacTests scripts
EXPORT := .build/export

.PHONY: test test-kit test-mac coverage lint format app run fixtures icon clean

## Tests: MurmurKit with `swift test`, then the app's tests.
test: test-kit test-mac

test-kit:
	cd MurmurKit && swift test

test-mac:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -quiet test

## MurmurKit line coverage; the bar is 80%.
coverage:
	cd MurmurKit && swift test --enable-code-coverage
	xcrun llvm-cov report \
	  MurmurKit/.build/out/Products/Debug/MurmurKitTests.xctest/Contents/MacOS/MurmurKitTests \
	  -instr-profile MurmurKit/.build/out/Products/Debug/codecov/default.profdata \
	  -ignore-filename-regex='(\.build|Tests)/'

## Lint: swift-format, strict, and builds with warnings as errors. The app's
## targets set SWIFT_TREAT_WARNINGS_AS_ERRORS; packages build with warnings suppressed.
lint:
	swift format lint --strict -r $(SWIFT_SOURCES)
	cd MurmurKit && swift build --build-tests -Xswiftc -warnings-as-errors
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -quiet build

format:
	swift format format -i -r $(SWIFT_SOURCES)

## The release app, signed with the Apple Development certificate of team
## Q9A5RCTM73 (suensky2@outlook.com). Not notarized: it runs on this Mac and on
## Macs registered to the team, not elsewhere through Gatekeeper.
app:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -quiet build
	rm -rf $(EXPORT) && mkdir -p $(EXPORT)
	ditto $(DERIVED)/Build/Products/Release/Murmur.app $(EXPORT)/Murmur.app
	codesign --verify --deep --strict --verbose=2 $(EXPORT)/Murmur.app
	codesign -dv $(EXPORT)/Murmur.app 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier"
	ditto -c -k --keepParent $(EXPORT)/Murmur.app .build/Murmur.zip
	@echo "signed: $(EXPORT)/Murmur.app (zipped: .build/Murmur.zip)"

## A Debug build, signed with the team's Apple Development certificate, launched.
run:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) -quiet build
	open $(DERIVED)/Build/Products/Debug/Murmur.app

## The WAV fixtures for the live tests (MURMUR_LIVE_APPLE=1, MURMUR_LIVE_ZOOM=1).
fixtures:
	scripts/fixtures.sh

icon:
	swift scripts/make-icon.swift

clean:
	rm -rf .build MurmurKit/.build
