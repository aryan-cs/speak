# Building Speak

This repository builds a macOS app named `Speak.app` from the `VoiceInk`
Xcode scheme. Use this guide when the GitHub release does not yet include a
working Developer ID signed and notarized `.dmg`.

## Requirements

- macOS 14.4 or later
- Xcode with the macOS SDK installed
- Xcode Command Line Tools selected with `xcode-select`
- Git
- Network access for the first build, so Xcode can resolve Swift packages and
  the Makefile can clone/build `whisper.cpp`

Check the required command line tools:

```sh
make check
```

## Local Build Without an Apple Developer Account

This is the recommended path for anyone who wants to build and run the app from
source on their own Mac.

```sh
git clone https://github.com/aryan-cs/speak.git
cd speak
make check
make local
open ~/Downloads/Speak.app
```

`make local` does the following:

- builds the shared `VoiceInk` Xcode scheme in Debug
- uses `LocalBuild.xcconfig`
- uses ad-hoc signing, so no Apple Developer account is required
- uses `VoiceInk/VoiceInk.local.entitlements`
- defines the `LOCAL_BUILD` Swift compilation flag
- copies the result to `~/Downloads/Speak.app`
- clears quarantine attributes from that local copy

The first build can take a while. The Makefile clones `whisper.cpp` into
`~/VoiceInk-Dependencies`, builds `whisper.xcframework`, and then lets Xcode
resolve the pinned Swift packages from `Package.resolved`.

## First Launch Permissions

When the app opens, complete the onboarding permissions. Speak needs these
macOS permissions to behave like the local development build:

- Microphone Access, for recording audio
- Accessibility Access, for pasting transcribed text at the cursor
- Screen Recording Access, for optional screen-context features
- a keyboard shortcut configured inside Speak

If macOS asks you to quit and reopen after granting Accessibility or Screen
Recording, quit Speak completely and run:

```sh
open ~/Downloads/Speak.app
```

## Local Build Limitations

Local builds are for personal use and testing. They intentionally do not match a
public release installer:

- no iCloud dictionary sync
- no automatic updates
- no Apple notarization ticket
- no Developer ID signature

Do not upload `make local` output as a public GitHub release ZIP or DMG. Other
Macs may block ad-hoc signed downloads with Gatekeeper.

## Development Commands

```sh
make check          # verify git, xcodebuild, and swift are installed
make setup          # build/prepare whisper.xcframework
make build          # Debug build through xcodebuild
make local          # ad-hoc local build copied to ~/Downloads/Speak.app
make run            # open the existing local/DerivedData app
make dev            # build and run
make clean          # remove ~/VoiceInk-Dependencies
```

The project is an Xcode project, not a Swift package entrypoint. The shared
scheme is `VoiceInk`, and the product name is `Speak`.

## Manual Xcode Build

The Makefile is the supported path because it prepares `whisper.xcframework` in
the location expected by the Xcode project. If you want to use Xcode manually:

1. Run `make setup`.
2. Open `VoiceInk.xcodeproj`.
3. Select the `VoiceInk` scheme.
4. Build or run the app from Xcode.

If signing fails in Xcode, use `make local` instead. The normal Debug/Release
project settings use Apple signing and full app entitlements that require the
matching Apple Developer account and provisioning setup.

## Public ZIP/DMG Release Builds

Public downloads must be Developer ID signed, notarized, and stapled. Use this
only if you have the Apple Developer credentials for the release:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID1234" \
APPLE_APP_SPECIFIC_PASSWORD="app-specific-password" \
make release-macos
```

The release packaging script refuses to package ad-hoc or unsigned builds. On a
successful release build, it writes:

- `dist/Speak-$VERSION.zip`
- `dist/Speak-$VERSION.dmg`
- `dist/checksums-$VERSION.txt`

Only upload those verified release artifacts to GitHub releases.

## Troubleshooting

- If the build cannot find `whisper.xcframework`, run `make setup`.
- If package resolution fails, make sure the Mac has network access and Xcode is
  fully installed.
- If Xcode reports signing or provisioning errors, use `make local`.
- If permissions look granted but dictation still does not paste, quit and
  reopen `~/Downloads/Speak.app` after granting Accessibility and Screen
  Recording.
- If the app cannot be opened after moving it between Macs, rebuild locally on
  that Mac or use a properly signed and notarized release DMG.
