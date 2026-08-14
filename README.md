# NodVoice

**ThinkVoice, but honest.**

AirPods Pro IMU + Grok STT + Grok multi-reply + nod to select + Grok TTS.

No brain-sensing. Just `CMHeadphoneMotionManager`, vibecoded.

> Where tf is the brain sensing technology?
> This is literally just an IMU detecting if he nod
> I can literally vibecode that and use my AirPods instead
> — [@gminoprio](https://x.com/gminoprio/status/2088126653507739720)

## What it does

1. **Listen** — phone mic captures the conversation (M4A)
2. **STT** — Grok Speech-to-Text (`POST /v1/stt`)
3. **Think** — Grok 4.5 returns 3 short reply options as JSON (fast)
4. **Nod** — AirPods head tracking:
   - **Nod yes** (pitch down-up) → select highlighted option
   - **Shake no** (yaw left-right) → cycle to next option
5. **Speak** — Grok TTS (`POST /v1/tts`, voice `eve` by default) plays the answer

## Requirements

- Mac with **Xcode 16+**
- iPhone on **iOS 17+** (physical device recommended)
- **AirPods Pro** (2/3) or any buds with spatial audio / head tracking
- [xAI](https://console.x.ai/) **SuperGrok / X Premium+** (Sign in in Settings) **or** an API key with chat + voice (STT/TTS)

Simulator cannot stream real headphone motion. Use a device.

## Quick start

```bash
git clone https://github.com/GianlucaMinoprio/nodvoice.git
cd nodvoice
open NodVoice.xcodeproj
```

1. Select your **Team** under Signing & Capabilities
2. Build to your iPhone
3. Open the app → **Settings** → **Sign in with SuperGrok** (or paste an API key)
4. Put AirPods in, grant mic permission
5. Tap **Listen**, talk, stop → wait for options → nod

### Optional: env-style local override

Copy the example and keep secrets out of git:

```bash
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
# edit Secrets.xcconfig — already gitignored
```

The app still prefers the key you enter in Settings (Keychain).

## Architecture

```
NodVoice/
  App/                 SwiftUI entry + app state
  Models/              Transcript, ReplyOption, session phase
  Services/
    AudioCaptureService.swift     AVAudioRecorder (m4a)
    HeadGestureService.swift      CMHeadphoneMotionManager nod/shake
    SuperGrokAuth.swift           Device-code SuperGrok OAuth + Keychain
    XAIClient.swift               STT + Chat + TTS
    SpeechPlayer.swift            AVAudioPlayer for TTS mp3
  Views/               Listen / Options / Settings UI
```

### xAI endpoints used

| Step | Endpoint | Notes |
|------|----------|--------|
| STT | `POST https://api.x.ai/v1/stt` | multipart `file` + `language=en` |
| Chat | `POST https://api.x.ai/v1/chat/completions` | model `grok-4.6` (override in Settings) |
| TTS | `POST https://api.x.ai/v1/tts` | JSON `{ text, voice_id, language }` → raw mp3 |

Default chat model is **`grok-4.6`**. Swap to `grok-4.5` or `grok-4-1-fast-non-reasoning` in Settings if you want cheaper/faster options.

Without SuperGrok sign-in or an API key the app runs a **demo loop** so nod/shake UI still works offline.

### SuperGrok OAuth (mobile)

Settings → **Sign in with SuperGrok** starts xAI **device-code** OAuth (same family as Hermes `xai-oauth`). Safari opens, you approve, NodVoice polls and stores access + refresh tokens in Keychain.

- Uses your grok.com / X Premium+ quota. No pasted API key.
- Access tokens refresh automatically.
- Some SuperGrok tiers still get HTTP 403 on the OAuth API surface. If that happens, paste a console API key as fallback.

Official xAI mobile guidance for shipping apps is still [ephemeral tokens](https://docs.x.ai/developers/model-capabilities/audio/ephemeral-tokens) in front of a backend key. SuperGrok OAuth is the personal-demo path.

### Nod detector

Uses headphone device motion attitude (pitch / yaw). A simple peak detector with cooldown:

- Pitch velocity spike + recovery → **nod**
- Yaw oscillation → **shake**

Thresholds live in `HeadGestureService` and are tunable.

## Security

This is a **demo client**. Putting a long-lived xAI key on-device is fine for personal vibecoding, not for a store build.

For anything real:

- mint **ephemeral tokens** on a tiny backend ([xAI ephemeral tokens](https://docs.x.ai/developers/model-capabilities/audio/voice))
- or proxy `/stt`, `/chat/completions`, `/tts` yourself

## License

MIT — go prove the IMU point.
