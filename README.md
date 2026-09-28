## speak

just a sleeker version of [VoiceInk](https://tryvoiceink.com). made by [aryan](https://github.com/aryan-cs), now supports glass ui.

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/5544fcf6-20e5-4743-bd55-8da8ed95ac44" />

### my setup

This is the setup I use every day, and how to get the same one.

**Transcription: local, no key needed**

- AI Models → Transcription: **Parakeet TDT 0.6B v3**. It runs on your Mac; download it from the Local tab the first time.
- Settings → Shortcuts → Primary Shortcut: **Right ⌘** in Hybrid mode. Tap it to start and stop, or hold it while you talk.
- Settings → Interface → Recorder Style: **Mini**, a small glass pill with a live waveform. The live transcript text is off.

**AI enhancement: Groq**

1. Create a key at [console.groq.com/keys](https://console.groq.com/keys).
2. Open AI Models → Enhancement → Cloud → Groq, and paste the key. Speak keeps it in the macOS Keychain, never in this repo or in its settings.
3. Model: `openai/gpt-oss-120b`.

Enhancement is set per mode on the Modes page:

| Mode | Used | Enhancement |
| --- | --- | --- |
| Dictation (default) | everywhere else | off; Parakeet's text is pasted as is |
| Enhancement | when you pick it | Groq with the Default prompt, using on-screen and selected text as context |
| Email | Apple Mail, Gmail, Outlook, iCloud Mail, Proton Mail, Superhuman, Shortwave, HEY, Fastmail, Missive | Groq with the Email prompt, also using the clipboard |

**Auto Learn dictionary: Ollama, local**

1. Install [Ollama](https://ollama.com/download) and keep it running.
2. Pull the model (2.5 GB):

   ```sh
   ollama pull qwen3:4b-instruct-2507-q4_K_M
   ```

3. Dictionary → Auto Learn: set Provider to **Ollama** and Model to **qwen3:4b-instruct-2507-q4_K_M**. Speak connects to Ollama at `http://localhost:11434`.

How it works:

- After Speak pastes, it watches that text box. When you fix a misheard word by hand, Speak picks up the fix as soon as you send the message, switch apps, or dictate again, or after a minute.
- The local model reviews each fix and keeps only misheard names and terms, such as "Alama" → "Ollama". Rewrites, punctuation, and changes of meaning are ignored.
- A glass pop-up shows what was added for about 1.5 seconds, with Undo when a single word was learned.
- A misspelling that isn't a real word, such as "Alama", becomes a replacement right away. When the misheard word is a real word, such as "print" or "grok", Speak adds only the vocabulary term at first. It waits until you make the same fix a second time before it replaces that word everywhere.
- Everything stays on your Mac.

**Audio**

- Audio → Lower Audio While Recording is on: Spotify & Music at 25%, Other Audio at 20%, Teams & Calls at 30%. Audio that is already quieter is left alone.
- Input: the MacBook Pro microphone. With the lid closed, Speak switches to another connected microphone and shows which one it is using.

**General**

- Settings → General → Hide Dock Icon: on. Speak lives in the menu bar.
- Speak pastes with ⌘V and adds a trailing space after each dictation.

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

Local builds do not require a paid Apple Developer account. If you have one Apple Development certificate (the free one Xcode creates when you sign in), `make local` signs with it, so macOS keeps your Microphone, Accessibility, and Screen Recording permissions across rebuilds. Otherwise the build is ad-hoc signed, and macOS may ask for those permissions again after each rebuild. Set `LOCAL_CODESIGN_IDENTITY` to choose between several certificates. Local builds are for personal use only: iCloud dictionary sync and automatic updates are disabled, and they should not be uploaded as public release ZIPs or DMGs.

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

Use `make local` only for private builds. Do not upload local builds as release ZIPs or DMGs.
