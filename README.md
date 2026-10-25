# Brailio for iPhone

An experimental native iPhone app for tactile reading, whole-word writing, conversations, named object positions and walking-route feedback. Inspired by [VibroBraille](https://devpost.com/software/vibrobraille-pc-to-braille-ai-relay).

## Touch interaction

Menus use six fixed action zones and four fixed navigation zones: Back, Replay, Status and Next. Hold/slide to focus and feel a label; lift and double-tap to activate it. Next changes pages without scrolling. App-owned screens contain no scrolling lists/forms. Native Files, permission dialogs and companion entry retain their system interactions. VoiceOver is supported alongside direct tactile input.

Handwriting, room scanning and the tactile map have dedicated direct-touch panels. Text/icons support residual vision and companions; understanding vibration words requires learning the serial Braille code. This prototype is not yet a validated independent-use aid.

## Whole-word writing

Write a complete print word across the canvas, lifting between strokes and letters. A pause of about 1.1 seconds updates a recognition preview and tactile read-back **without clearing the ink**. Add late dots/crossbars or continue writing after a pause. Space commits the current word and adds a separator; Done commits and completes the current workflow. Delete clears pending ink first.

Recognition runs locally using iOS 27 PencilKit where available, then Vision OCR, with a conservative segmented print-letter fallback. Joined cursive relies on the system recognizer/OCR and is not universally reliable. Unclear ink remains available for correction. The alternative six-dot writer is reached through Done > Braille; its positions are `1 4 / 2 5 / 3 6`.

## Apple Maps navigation

Apple Maps is the default and requires no Google Maps API key. **Go > Write destination > Done** waits for a usable location, resolves the destination, calculates an Apple walking route, opens the tactile map and starts guidance. Use draft, companion entry and saved destinations use the same path. Ambiguous results require choosing the intended place; an exact unique result or an explicit nearest/closest query can resolve automatically.

On the map, hold/slide to feel the nearest route-instruction point. Double-tap opens that point's controls. Replay repeats its label. Panning/zoom gestures are disabled so the surface is used for tactile exploration. Tactile labels briefly take over the actuator, then active guidance resumes automatically. Resume is also available on the next action page.

- Reliable alignment: short approach pulses that strengthen and speed up as the remaining route gets shorter. The optional silent-alignment mode is on the route controls page.
- Sustained deviation, wrong turn or reverse travel: stronger correction pulses.
- Returning toward alignment: the long correction pulses ease, then the distinct approach pulses resume.
- Unreliable/stale GPS or travel direction: a distinct two-short-pulse uncertainty pattern.

Two distinct reliable fixes are needed to establish deviation. Replaying a cached GPS fix cannot confirm it. Route matching stays near previous progress to reduce jumps to future parallel streets or loops. Strength respects the user's intensity setting. The route's training page provides bounded three-second Strong, Soft, Silent and Uncertain tests. Leaving the route screen or backgrounding stops guidance. New route explicitly recalculates.

Approach pulses continue at the final coordinate until Stop; that coordinate is a nearby checkpoint, not proof of a doorway or safe arrival. Silence cannot establish clear space, accessible sidewalks or a safe crossing. Continue using the usual mobility aid. Outdoor GPS accuracy and tactile interpretation still need supervised testing with intended users.

Optional Google routing and keyless Google Maps handoff remain on secondary pages. In-app Google routes require a separately configured, billing-enabled Google Routes server key and app token; no Google key is included. Opening an external map app stops Brailio's foreground guidance.

## Room scanning and object positions

Find's center control starts a scan when held and finishes on release, bounded to 30 seconds. **No room movie is recorded or saved.** Up to 30 reduced still snapshots and projected AR feature points are kept temporarily. Write an object name and choose Done; AI examines up to eight scan snapshots, and sufficient nearby feature points can establish an estimated room position. Positioning first uses measured scene depth on supported hardware or tracked visual points. Smooth objects can also use a ray intersection with a classified table/seat surface, including surfaces detected later in the same scan. Floors, walls and unclassified surfaces are not used as automatic substitute object positions. Sparse/ambiguous geometry remains uncertain.

Saved names return to stored AR positions without repeated object inference. ARKit still needs the camera and motion sensors for tracking/relocalization; this is not camera-free navigation. Basic iPhone 17 does not provide Pro-model rear LiDAR, and the implementation does not assume it. Positions can drift and cannot follow moved objects.

Single approach pulses grow stronger and faster near the estimated object position. Status reads left/right/ahead/behind. Two short pulses indicate missing position/tracking instead of falsely signaling approach. The haptic loop updates its strength without restarting on every camera/GPS update. Tactile labels/confirmations briefly take over the actuator and guidance resumes afterward. A tap checks proximity to the saved position, **not object identity**. Wrong object stops guidance. Mark center can manually save a named surface position without AI. A geometrically valid position can guide immediately while map saving retries; if persistence fails, it is explicitly marked current-session-only. When an object is detected but depth is unavailable, hold center and slowly rescan the object and supporting surface; the name is retained automatically. Saved maps use complete file protection; temporary snapshots are cleared after saving/backgrounding. Settings > Clear data removes maps and local documents.

## Reading, documents and conversations

Read > Documents checks imported document titles first, then Internet Archive's public PDF catalog when no local title matches. Results use fixed pages. Direct HTTPS PDF/text links are also supported. No Tavily/search key is required. Phone Files opens Apple's user-authorized picker for On My iPhone, iCloud and file providers; iOS prevents silently indexing other apps' private storage.

PDF and UTF-8 text files up to 40 MB are imported into private storage. Whole books have no 20,000-character cap: PDFs load page by page, scanned pages use local OCR, and text files use 2,400-character pages. Read book continues across pages while active. Page/cell bookmarks survive leaving the reader and relaunch. Restricted, locked or login-only documents are not bypassed.

Playback is a limited English teaching code, not a complete UEB/multilingual/math transcriber. Each cell has six dot time slots and two quiet gap slots. Common typography is normalized; unknown document symbols are announced as 'unsupported symbol'. OCR/handwriting can be wrong. Complex tables, equations and diagrams need additional work.

Talk supports written replies, explicit display/speech, and optional partner speech transcription. Speaking is optional. Apple Speech may process audio online; microphone capture stops when leaving/backgrounding. Optional Bluetooth-tag pages provide foreground RSSI feedback, not AirTag/Find My access or precise distance.

## Run the private demo

1. Open `Brailio.xcodeproj` in Xcode, select your signing team and run on an iPhone. Deployment target: iOS 17+. Regenerate with `xcodegen generate` after editing `project.yml`.
2. Settings > AI connection > Save and test stores **your own** Baseten key in this iPhone's Keychain using `WhenUnlockedThisDeviceOnly`. No usable key is bundled in the binary, stored in UserDefaults, committed to GitHub or provisioned to Vercel.
3. Alternatively run `scripts/provision-private-demo.sh DEVICE_ID`. It reads the key with terminal echo disabled and passes it only through the device launch environment. Close/reopen the app after provisioning to remove that transient environment.
4. Use Go > Write destination > Done for the Apple map workflow, or Find > hold/release scan > write name > Done for object identification.

Private demo mode calls Baseten directly over HTTPS using `zai-org/GLM-5.3-Flash`. It sends selected text or room snapshots to Baseten. Local handwriting, OCR and document reading do not require AI. Remove the key in AI connection when finished. For wider distribution, move to per-user backend authentication, scoped credentials and quotas; do not embed a shared provider key in a public client.

Optional Node backend: `backend/api/assist.js` and `backend/api/route.js`. Server-mode secrets are documented in `backend/.env.example`. The iPhone stores only the matching app access token for server mode. No server credentials are provisioned by this repository. The deployed backend rejects unauthenticated requests; its privacy/terms pages describe provider data flows. Rate limits are per instance, not global spending caps. Google route coordinates are sent only to the optional route endpoint/Google, not Baseten.

Local environment files, Vercel linkage, Xcode user data, signing credentials and build output are ignored by Git. This repository contains **no usable API credentials**.

## Verification

```sh
xcodebuild -project Brailio.xcodeproj -scheme Brailio \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
node --test backend/tests/assist.test.js backend/tests/route.test.js
```

Tests cover Braille, dot writing, whole-word ink recognition, retained ink across pauses, document/OCR/bookmarks, route-error intensity, GPS uncertainty, bends/parallel streets, provider handling and fixed UI flows. The opt-in live document test requires `BRAILIO_LIVE_DOCUMENTS=1` in the test runner. UI route fixtures verify interaction transitions; they do not substitute for live route verification.

On the connected iPhone, the private Keychain connection passed real Baseten text and synthetic-image object inference. Apple place search and walking-route calculation also passed using public synthetic endpoints, returning seven route steps without accessing the user's location. The destination-Done-to-active-map flow and hold/double-tap map access were checked separately in the UI runner. These checks do not establish physical room-map precision, recognition of personal belongings, road safety or outdoor tactile usability.

See [UX research](docs/UX_RESEARCH.md) for primary technical references and research boundaries.


### Proximity update verification

The proximity update passed 51 iOS checks, including the complete destination/interactive-map UI flow and seven new proximity/surface tests. They cover monotonically stronger/faster approach pulses, non-silent endpoint feedback until Stop, rejected invalid distances, table-ray placement without tracked object points, rejection of unrelated floor/unclassified surfaces, and separate tactile-label completion. The focused reading/map regression checks and explicit Stop regression also passed. On the connected iPhone, the opt-in nine-second synthetic ramp completed all three stages with hardware haptics supported and no reported error. It does not validate real-room distance accuracy.
