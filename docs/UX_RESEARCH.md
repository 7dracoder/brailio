# Brailio: interaction and accessibility research

Reviewed 24 October 2026. These are implementation decisions informed by primary sources, not claims of accessibility certification or validated tactile comprehension.

## Evidence and decisions

| Primary source | Relevant finding | Decision in Brailio |
| --- | --- | --- |
| [Apple: UI Design Dos and Don'ts](https://developer.apple.com/design/tips/) | Legibility, adequate contrast, clear organization and touch targets of at least 44 × 44 points are fundamental. | Main actions have generous hit regions. Secondary action buttons have a 48-point minimum height. Icon-only controls have explicit labels. |
| [Apple HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Support larger text, assistive technology and multiple ways to perceive information. | Semantic system text styles, one-column Home at accessibility text sizes, explicit selected-dot values, text plus icons, and labeled alternatives to gestures. |
| [Apple HIG: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics) | Haptics should have a clear purpose and remain consistent with feedback from other modalities. | Reading, navigation and finding retain their taught cue vocabularies. Decorative button vibrations are avoided so they do not interfere with Braille signals. Playback has visual state, explicit pause and repeat. |
| [Apple: Braille Screen Input with VoiceOver](https://support.apple.com/guide/iphone/iph10366cc30/ios) | iOS already provides a Braille input workflow through VoiceOver. | Preserve native text editors so system input methods remain available. Offer a standard keyboard alongside the custom dot selector. Avoid overriding VoiceOver activation gestures. |
| [W3C: Help users understand what things are and how to use them](https://www.w3.org/WAI/WCAG2/supplemental/objectives/o1-understandable/) | Familiar controls, clear labels, consistent positions and a clear relationship between actions and content reduce confusion. | Stable Home action order; distinct Your message/Their reply modes; consistent card, field and action styles; visible, contextual primary actions. This web guidance is used as a design principle, not as native-app conformance evidence. |
| [Jayant et al., V-Braille, ASSETS 2010](https://mobileaccessibility.cs.washington.edu/publications/assets1059_jayant.pdf) | A preliminary study with nine experienced Braille users, including six deafblind participants, explored phone-based tactile reading. It also emphasizes including users early. | Keep Learn and adjustable timing prominent. Plan testing with blind/deafblind users. V-Braille uses screen regions and touch-triggered vibration; it does not validate Brailio's different six-slot temporal code. |

## Main UX problems found

- The reader's primary playback control was below a long stack of content.
- Writing mixed character selection, typing, AI suggestions and sharing without a clear hierarchy.
- Vertical swipes over the Braille keyboard could accidentally replay a draft while scrolling.
- Conversation text from both participants and many phrases competed for attention.
- Home action cards repeated a long vertical layout, making later actions harder to discover.
- Some secondary text buttons were too cramped for large text or comfortable touch.
- AI setup failures were only explained after an action; the Find screen lacked a clear setup state.

## Final direction after the user's accessibility correction

The initial visual redesign was superseded. A polished scrolling dashboard does not serve the requested tactile workflow. The user explicitly required removing the introduction, exploration toggle and scrolling.

### Implemented fixed surface

- Six stable action zones in a two-column, three-row layout on every primary screen.
- Four bottom navigation zones in the same locations: Back, Replay, Status, Next.
- Contact focuses and plays a taught Braille label; only double-tap activates.
- A delayed-touch UIKit double-tap recognizer preserves existing focus when double-tapping elsewhere.
- Explicit action pages replace scrollable lists, forms and long instructions.
- Home immediately exposes Read, Write, Talk, Find, Go and Learn. Settings/Notes are on its next page.
- Writing's six dot positions remain fixed; Enter/editing, draft use, AI suggestions and clear confirmation are separate pages.
- Selected states have textual accessibility values as well as visual styling.
- UI-label haptics are separated from content playback to avoid losing the reading position.
- Automatic camera/GPS/tag cues yield while the user explores controls.
- Clear operations require explicit confirmation and are disarmed on leaving their context.
- VoiceOver retains native focus/activation. Optional companion text entry and system permission/picker interfaces remain separate from the primary tactile workflow.

Text and icons remain as secondary support, not prerequisites for operating the core app. There are no app-owned ScrollView, List or Form views in the current source. The system keyboard and OS pickers remain system-controlled surfaces. The largest-text check verifies that fixed zones remain reachable; this does not certify all label typography at every setting.

### Research boundaries

V-Braille's touch-region method differs from this app's serial six-slot code. Its study does not validate Brailio's comprehension, cue timings or independence claims. The interaction design is a prototype that needs participatory testing, especially for tactile onboarding and discoverability of page changes. A person who has not learned the code cannot immediately understand arbitrary vibration words.

Apple's [recording-session API](https://developer.apple.com/documentation/avfaudio/avaudiosession/setallowhapticsandsystemsoundsduringrecording(_:)) documents that haptics during recording must be enabled. Brailio configures this so microphone reply capture does not intentionally suppress control feedback. Physical verification remains required.

## Verification and remaining research

Automated UI checks exercise single-touch nonactivation, double-tap away from the focused action, writing/delete/undo/save without scrolling, every primary feature's fixed navigation, explicit pages, dark appearance and largest-text reachability. Unit tests check translation/writing/cue mappings. Signed physical-device builds and launch are checked separately.

Next user studies should measure:

1. Finding actions and recognizing labels without vision or hearing.
2. Learning time, comprehension, fatigue and accidental activation rate.
3. Writing/correcting a message, recovering from deletion and accepting/rejecting AI suggestions.
4. Discovering pages and returning to a known location.
5. Interpreting uncertainty in object finding and route cues.
6. Working with VoiceOver, Braille Screen Input, Switch Control and differing motor abilities.

Visual polish and simulator results cannot establish success for these tasks on their own.

Final checks: all 16 iOS tests passed. A subsequent targeted largest-text regression also passed after fixing navigation-label clipping. Navigation labels scale up to 20 points and their decorative icons remain bounded to preserve the four stable navigation zones without scrolling; other text uses semantic styles. This is an explicit fixed-layout compromise, not a claim of unrestricted Dynamic Type support.

## Finger-writing and room capture revision

The user requested drawing letters rather than selecting Braille dots, and a hold-to-record room workflow. The app now reserves a direct-touch canvas for that explicit mode; it does not confuse drawing with ordinary menu exploration. Letter recognition is delayed approximately 700 ms after lifting to allow nearby multi-stroke components. Automatic tactile read-back, Delete, Space and Done support correction without scrolling. Braille remains an alternative for people who do not use print handwriting.

Primary technical references:

- [Apple: Read between the strokes with PencilKit](https://developer.apple.com/videos/play/wwdc2026/203/) documents on-device iOS 27 handwriting recognition. Tests showed isolated-letter cases returning no text, so the implementation adds local OCR and a conservative print-letter shape fallback. The fallback is not validated for all handwriting styles.
- [Apple: VNTrackObjectRequest](https://developer.apple.com/documentation/vision/vntrackobjectrequest) tracks a previously detected bounding box; tracking alone does not establish object identity. The app therefore requires fresh semantic rechecks and stops cues on stale/lost evidence.
- [Apple: capture-session output support](https://developer.apple.com/documentation/avfoundation/avcapturesession/canaddoutput(_:)) documents concurrent movie-file/data output support on supported iOS versions. Brailio's deployment target is iOS 17+; hardware support is checked at runtime.

Hold-to-record is a deliberate exception to double-tap activation and is confined to a dedicated center control. Capture never starts from an ordinary tap. A short tap in the live finding panel requests verification. Verification has three outcomes; uncertainty is not collapsed into yes or no. No feedback claims physical arrival or a safe route. The camera samples submitted for cloud inference are a subset of a silent, bounded local movie, not a continuously uploaded recording.


## Document library and spatial-position revision

The user replaced video-based finding with named room positions and requested document search/reading. The earlier video/live-object workflow above is historical and has been superseded. The current app saves no movie. Scan snapshots are temporary, and returning to saved positions uses AR tracking rather than repeated object inference. A position tap has a different meaning from visual identity confirmation: yes means near the stored coordinate only.

Primary sources:

- [Apple: Understanding world tracking](https://developer.apple.com/documentation/arkit/understanding-world-tracking) explains camera/motion visual-inertial odometry. A saved indoor point cannot remain accurately relative to the phone using motion sensors alone.
- [Apple: Relocalizing](https://developer.apple.com/documentation/arkit/arcamera/trackingstate-swift.enum/reason/relocalizing) explains limited tracking while reconciling a prior world map. Guidance must wait for localization and normal tracking.
- [Apple: iPhone 17 specifications](https://www.apple.com/iphone-17/specs/) lists the base device sensors; this implementation does not assume Pro-model LiDAR.
- [Apple: Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories) explains user-granted Files access, rather than silent device-wide indexing.
- [Apple: PDFPage](https://developer.apple.com/documentation/pdfkit/pdfpage) provides text extraction and rendered thumbnails for local OCR fallback.
- [Internet Archive: Item search APIs](https://doc-tools.readthedocs.io/en/ia-test-gsod/item-search-apis.html) and [Metadata read API](https://doc-tools.readthedocs.io/en/ia-test-gsod/md-read.html) document the catalog search and public download resolution used on-phone. This is not unrestricted web search.

Reading bookmarks store page and cell. Continuous playback crosses page boundaries only during active reading and yields to control exploration. Unsupported symbols are announced explicitly. The system Files picker is outside the app's tactile surface; library navigation after import uses the fixed controls. Spatial precision, feature-point-to-object mapping, relocalization, user understanding of 'near saved position', reading endurance and scanned-page OCR remain device/user validation work.


## Silent alignment / proportional navigation revision

The user requested silence when walking along the intended route and stronger vibration after a wrong turn, tapering while returning. This supersedes automatic left/right checkpoint announcements. The route now emits correction pulses based on cross-route error and measured travel course; reliable alignment is silent. Explicit route-step reading remains available. Uncertain GPS/course uses a separate two-tap pattern, because treating unavailable feedback as 'correct' would be misleading. Exploration suspends route feedback until explicit Resume. Strong/Soft/Uncertain training patterns are limited to three seconds.

Technical references:

- [Apple: Heading and course](https://developer.apple.com/documentation/corelocation/getting-heading-and-course-information): phone heading and travel course differ. Walking guidance uses reliable travel course, not phone orientation; stationary/poor-course data is uncertain.
- [Google: Routes usage and billing](https://developers.google.com/maps/documentation/routes/usage-and-billing): in-app Google routes need a billing-enabled project and API credentials. No such key was available in this session.
- [Google: Compute route directions](https://developers.google.com/maps/documentation/routes/compute_route_directions): route geometry and step instruction field masks used by the optional server provider.
- [Google: Maps URLs](https://developers.google.com/maps/documentation/urls/get-started): explicit keyless walking-directions handoff. Brailio stops when it leaves foreground; it does not inherit Google Maps' navigation state.
- [Google: Routes attribution](https://developers.google.com/maps/documentation/routes/policies): provider attribution is kept with route content, and prototype privacy/terms pages describe coordinate sharing. No Google geometry is displayed on an Apple map or persisted as a route cache.

Automated synthetic routes exercise reverse travel, wrong turns, decreasing cross-track error, ambiguous/poor/stale GPS, heading wrap, bends, duplicate fixes and parallel route segments. They cannot establish street-level accuracy, acceptable false-alarm rates, discomfort/fatigue limits, safe crossings, or independent mobility outcomes. Next testing must include supervised outdoor walks and participatory evaluation with intended users.


## Whole-word input and direct Apple-map revision

A 700 ms letter auto-commit was unsuitable for slow multi-stroke word writing. The revised canvas retains all strokes across pauses and treats recognition as a preview until Space or Done. This supports whole words and late dots/crossbars without premature clearing. System recognition/OCR is supplemented only by a conservative segmented print fallback; no claim covers all cursive handwriting.

The user's private-demo preference superseded server-key provisioning for this demo. A device-only Keychain credential now permits direct Baseten inference; the source and binary contain no usable key. A physical-device check passed synthetic text and image inference. This must not be generalized to public-client credential distribution.

Apple Maps is the default and integrated using [MapKit for SwiftUI/UIKit](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui) and [MKDirections](https://developer.apple.com/documentation/mapkit/mkdirections). Destination completion starts resolution/routing automatically, with a choice for ambiguous results. The read-only map surface converts touch into route-point exploration and double-tap into instruction access. Native Apple Maps integration does not prove universal route quality or accessible sidewalks.

A UI test caught an app-lifecycle issue: long-lived handwriting/haptic callbacks retained a stale scene-phase environment value. The implementation now keeps current app phase in shared view state, so completion can activate a route and navigation haptics after becoming active. Permission dialogs pause feedback while backgrounding cancels active work.


## Proximity feedback and smooth-object positioning

The user's laptop screenshot showed successful object recognition followed by insufficient AR geometry. A two-dimensional detection does not supply a three-dimensional distance. The revised position estimator first uses confident scene-depth samples on supported devices or feature-point clusters, then ray intersections with classified table/seat surfaces. It can combine the evidence image's camera pose with supporting surfaces detected later in the same scan. It never substitutes a floor, wall or unknown plane for an absent object depth. A remaining failure keeps a distinct uncertainty pattern and supports rescan with the object name retained.

The previous direction-only object cues and silent aligned walking default are superseded by proximity pulses: nearer estimated targets produce stronger, faster short pulses. Long pulses indicate route error; a two-pulse pattern indicates uncertainty. A route endpoint continues pulsing until explicit Stop. Labels/confirmations temporarily use the actuator, then active guidance resumes. Strength updates no longer cancel/restart the loop at camera frame frequency.

References: [Apple camera intrinsics](https://developer.apple.com/documentation/arkit/arcamera/intrinsics) describes the pinhole projection used for portrait-image rays; [Apple plane classification](https://developer.apple.com/documentation/arkit/arplaneanchor/classification-2r4x8) explains classified surfaces and classification delay. Hardware depth is enabled only after checking supported frame semantics. Base iPhone camera tracking cannot guarantee a depth for every smooth object; uncertainty is kept explicit rather than inventing distance.

The automated table/feature/depth-input geometry checks and synthetic proximity curves do not establish recognition, perceived intensity, range accuracy or safe movement in the user's room. The user must still validate real scanning and navigation with their usual mobility aid.
