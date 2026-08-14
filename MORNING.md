# Morning path (device)

1. Open Xcode (full app, not just CLT):
   ```bash
   open ~/Projects/nodvoice/NodVoice.xcodeproj
   ```
2. Signing & Capabilities → Team → your Apple ID team
3. Plug iPhone, trust computer, select the device as run destination
4. Run (⌘R)
5. On phone: Settings gear → paste xAI API key from https://console.x.ai
6. AirPods in → Listen → talk → Stop → shake to cycle → nod to speak

## If build fails on signing

- Bundle id: `com.gianlucaminoprio.nodvoice` (change if taken)
- Enable Developer Mode on iPhone (Settings → Privacy & Security)

## If headphone motion says unavailable

- Physical device required
- AirPods Pro (or buds with head tracking) connected and in-ear
- Spatial audio / head tracking supported firmware

## Demo without key

Tap Listen with empty API key → mock transcript + 3 options. Nod/shake still work. TTS needs a real key.

## Repo

https://github.com/GianlucaMinoprio/nodvoice
