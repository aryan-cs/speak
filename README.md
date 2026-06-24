## speak

just a sleeker version of [VoiceInk](https://tryvoiceink.com). made by [aryan](https://github.com/aryan-cs), now supports glass ui.

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/5544fcf6-20e5-4743-bd55-8da8ed95ac44" />

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
