## speak

just a sleeker version of [VoiceInk](https://tryvoiceink.com). made by [aryan](https://github.com/aryan-cs), now supports glass ui.

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/5544fcf6-20e5-4743-bd55-8da8ed95ac44" />

### build from source

If the GitHub release does not have a working notarized `.dmg` yet, build the app locally from this repository:

```sh
git clone https://github.com/aryan-cs/speak.git
cd speak
make check
make local
open ~/Downloads/Speak.app
```

The first build can take a while because Xcode resolves Swift packages and the Makefile builds `whisper.xcframework` in `~/VoiceInk-Dependencies`.

On first launch, finish the onboarding permissions in macOS System Settings:

- Microphone Access
- Accessibility Access
- Screen Recording Access
- Keyboard shortcut setup inside Speak

If macOS asks you to quit and reopen after granting Accessibility or Screen Recording, quit Speak completely and open `~/Downloads/Speak.app` again.

Local builds use ad-hoc signing and do not require an Apple Developer account. They are intended for personal use only: iCloud dictionary sync and automatic updates are disabled, and local builds should not be uploaded as public release ZIPs or DMGs.

See [BUILDING.md](BUILDING.md) for detailed build and troubleshooting notes.

### macOS release builds

Public GitHub release assets must be Developer ID signed, notarized, and stapled:

```sh
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." \
APPLE_ID="you@example.com" \
APPLE_TEAM_ID="TEAMID1234" \
APPLE_APP_SPECIFIC_PASSWORD="app-specific-password" \
make release-macos
```

By default this uses `VoiceInk/VoiceInk.release.entitlements`, which omits CloudKit and push entitlements so a Developer ID release does not require an iCloud provisioning profile. Set `RELEASE_ENTITLEMENTS=VoiceInk/VoiceInk.entitlements` only if the matching Developer ID provisioning profile is configured.

Use `make local` only for private ad-hoc builds. Do not upload local builds as release ZIPs or DMGs.
