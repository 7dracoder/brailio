import SwiftUI
import PhotosUI
import Vision
import PDFKit
import UniformTypeIdentifiers
import MapKit
import AVFoundation

/// All primary workflows use the same fixed six zones and four navigation zones.
struct HomeView: View {
    enum Screen: String { case questions = "Ask documents", questionDocuments = "Choose documents", questionSources = "Answer sources", home = "Home", write = "Write", read = "Read", talk = "Talk", find = "Find", go = "Go", learn = "Learn", settings = "Settings", notes = "Notes", places = "Places", route = "Route", saved = "Saved places", trackers = "Bluetooth tags", documents = "Documents", library = "My library", online = "Online PDFs", storage = "Saved", objects = "Saved objects" }
    @EnvironmentObject private var reader: HapticReader
    @StateObject private var labels = HapticReader()
    @Environment(\.scenePhase) private var phase
    @State private var appPhase: ScenePhase = .active
    @StateObject private var conversation = Conversation()
    @StateObject private var speaker = Speaker()
    @StateObject private var room = RoomCamera()
    @StateObject private var ink = Handwriting()
    @StateObject private var documents = DocumentLibrary()
    @StateObject private var questions = DocumentQuestions()
    @State private var questionSelection: Set<UUID> = []
    @State private var questionWriting = ""
    @State private var writingQuestion = false
    @StateObject private var guide = RouteGuide()
    @StateObject private var navigationHaptics = NavigationHaptics()
    @Environment(\.openURL) private var openURL
    @StateObject private var scanner = TrackerScanner()
    @AppStorage("messageDraft") private var draft = ""
    @AppStorage("readerText") private var reading = "hello"
    @AppStorage("findQuery") private var object = "keys"
    @AppStorage("destinationQuery") private var destination = ""
    @AppStorage("notes") private var notesData = Data()
    @AppStorage("tactileMode") private var tactileMode = TactileMode.morse.rawValue
    @AppStorage("slotDuration") private var pace = 0.30
    @AppStorage("intensity") private var intensity = 0.8
    @AppStorage("practicedLetters") private var practiced = ""
    @AppStorage("trackerNames") private var trackerNames = Data()
    @State private var screen: Screen = .home
    @State private var history: [Screen] = []
    @State private var page = 0
    @State private var focused: String?
    @State private var lastControl: String?
    @State private var pending: Task<Void, Never>?
    @State private var notice = "Ready."
    @State private var dots: Set<Int> = []
    @State private var numbers = false
    @State private var capitals = false
    @State private var deleted: Character?
    @State private var suggestion: String?
    @State private var clearDraftRequested = false
    @State private var clearAllRequested = false
    @State private var suggestionSource = ""
    @State private var busy = false
    @State private var selectedLetter = 0
    @State private var scanID = UUID()
    @State private var result: AIResult?
    @State private var captured: Date?
    @State private var confirmed = false
    @State private var entry: Entry?
    @State private var photo: PhotosPickerItem?
    @State private var selectingPhoto = false
    @State private var importing = false
    @State private var showingMessage = false
    @State private var selectedTracker: UUID?
    @State private var writingObject = false
    @State private var objectWriting = ""
    @State private var finishAfterRecognition = false
    @State private var spaceAfterRecognition = false
    @State private var lastInkCommit = ""
    @State private var captureRequested = false
    @State private var showingConnection = false
    @State private var writingDestination = false
    @State private var destinationWriting = ""
    @State private var routeTask: Task<Void, Never>?
    @State private var navigationID = UUID()
    @State private var readingLabel = false
    @State private var mapFocusLabel = ""
    @State private var startingRoute = false
    @State private var writingSearch = false
    @State private var searchWriting = ""
    @State private var documentQuery = ""
    @State private var continuousBook = false
    @State private var loadingPage = false
    @State private var pageRequest = UUID()
    @AppStorage("spokenFindResults") private var spokenFindResults = false
    struct Entry: Identifiable { let id: String; let title: String; let current: String }
    private var notes: [SavedNote] { (try? JSONDecoder().decode([SavedNote].self, from: notesData)) ?? [] }
    private var character: String? { BrailleInput.character(for: dots, numbers: numbers, capitals: capitals) }
    private var allActions: [TouchAction] { pages[min(page, pages.count - 1)] }
    private var footer: [TouchAction] {
        if screen == .write && page == 0 {
            return [action("navBack", "Back", "arrow.backward") { back() },
                    action("inkSpace", "Space", "space") { if !ink.strokes.isEmpty { spaceAfterRecognition = true; ink.finishNow() } else { handwritingText += " "; feedback("space") } },
                    action("inkDelete", "Delete", "delete.left", enabled: !handwritingText.isEmpty || !ink.strokes.isEmpty) {
                        if !ink.strokes.isEmpty { ink.clear(); feedback("cleared") }
                        else if !handwritingText.isEmpty { handwritingText.removeLast(); feedback("deleted") }
                    },
                    action("inkDone", "Done", "checkmark") { finishWriting() }]
        }
        return [action("navBack", "Back", "arrow.backward") { back() },
         action("navReplay", "Replay", "arrow.counterclockwise") { replay() },
         action("navStatus", "Status", "waveform") { reader.stop(); playLabel(statusText) },
         action("navNext", "Next", "arrow.right") { nextPage() }]
    }
    private var statusText: String {
        if screen == .write { return handwritingText.isEmpty ? "empty" : handwritingText }
        if screen == .find { return room.message }
        if [.questions, .questionSources, .questionDocuments].contains(screen) { return questions.status + " " + String(questionSelection.count) + " documents selected" }
        if screen == .documents || screen == .library || screen == .online { return documents.status }
        if screen == .read, let book = documents.current { return "\(book.title). page \(documents.page + 1) of \(book.pages). \(notice)" }
        if screen == .go || screen == .route { return guide.guiding && guide.suspended ? "Guidance paused for exploration. Resume to continue." : guide.location == nil && !guide.guiding ? "Location required." : guide.status }
        if screen == .talk { return page == 0 ? draft : conversation.transcript }
        if screen == .settings { return "Tactile code " + TactileMode.current.title }
        return notice
    }
    var body: some View {
        TactileSurface(title: screen.rawValue, page: "\(page + 1) / \(pages.count)", actions: allActions, navigation: footer, focused: focused, onFocus: focus, onActivate: activate, panel: directPanel) {
            preview
        }
        .background(RoomTrackingHost(room: room).frame(width: 2, height: 2).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true))
        .onAppear {
            appPhase=phase
            #if DEBUG
            DemoVerification.runIfRequested(); AppleMapsVerification.runIfRequested(); ProximityVerification.runIfRequested(using:navigationHaptics)
            #endif
            guide.onCue = { cue in if screen == .route && focused == nil { cuePattern(cue.rawValue, cue.dots) } }
            guide.onFeedback = { feedback in
                if screen == .route && appPhase == .active { navigationHaptics.update(feedback) }
                else { navigationHaptics.stop() }
            }
            scanner.onSignal = { count in if screen == .trackers && focused == nil { cuePattern("Signal", Set(1...count)) } }
            ink.onBegin = { pending?.cancel(); reader.stop(); labels.stop(); focused=nil }
            ink.onPreview = { text in if screen == .write && focused == nil { playLabel(text) } }
            ink.onFailure = { finishAfterRecognition = false; spaceAfterRecognition = false; if screen == .write { playLabel("unclear") } }
            ink.onRecognized = { text in
                guard screen == .write else { return }
                let committed = capitals ? text.uppercased() : text
                handwritingText += committed; lastInkCommit = committed; notice = committed
                if spaceAfterRecognition { handwritingText += " "; spaceAfterRecognition = false }
                playLabel(committed)
                if finishAfterRecognition { finishAfterRecognition = false; completeWriting() }
            }
            room.onCue = { dots in if screen == .find { cuePattern("Saved position", dots) } }
            room.onFeedback = { value in
                if screen == .find && appPhase == .active && !readingLabel { navigationHaptics.update(value) }
                else if screen == .find { navigationHaptics.stop() }
            }
            labels.onFinished = { readingLabel=false; resumeLiveFeedback() }
            labels.onSingleFinished = { readingLabel=false; resumeLiveFeedback() }
            room.onVerdict = { verdict in
                guard screen == .find else { return }
                if ["saved","uncertain","unavailable"].contains(verdict) {
                    notice=room.message
                    if !readingLabel && (room.guiding || room.needsRescan) { room.resumeFeedback() }
                } else {
                    feedback(verdict)
                }
                if spokenFindResults && ["yes", "no", "uncertain"].contains(verdict) { speaker.speak(verdict) }
            }
            room.onStopFeedback = { labels.stop(); if screen == .find { navigationHaptics.stop() } }
            reader.onSingleFinished = { readingLabel=false; resumeLiveFeedback() }
            reader.onFinished = {
                guard continuousBook, screen == .read, let book = documents.current else { readingLabel=false; resumeLiveFeedback(); return }
                guard documents.page + 1 < book.pages else { continuousBook = false; documents.bookmark(0); feedback("book finished"); return }
                documents.setPage(documents.page + 1); loadDocumentPage(play: true)
            }
        }
        .onChange(of: reader.index) { _, index in if screen == .read, documents.active != nil, !loadingPage { documents.bookmark(index) } }
        .onChange(of: room.scanVersion) { _, _ in
            guard captureRequested, screen == .find, phase == .active else { return }
            captureRequested = false
            guard !room.roomFrames.isEmpty else { fail("No room detail captured. Hold longer and try again."); return }
            if room.needsRescan { startFinding(); return }
            openObjectWriting()
        }
        .onChange(of: navigationHaptics.error) { _, error in
            if let error {
                if screen == .find { room.stop(); fail(error) }
                else { guide.pauseForHapticFailure(error); if screen == .route { fail(error) } }
                navigationHaptics.error = nil
            }
        }
        .onChange(of: room.error) { _, error in if let error, screen == .find { captureRequested = false; fail(error) } }
        .onChange(of: numbers) { _, value in ink.prefersDigits = value }
        .onChange(of: reader.error) { _, error in if let error { notice = error; reader.error = nil; readingLabel=false; resumeLiveFeedback() } }
        .onChange(of: labels.error) { _, error in if let error { notice = error; labels.error = nil; readingLabel=false; resumeLiveFeedback() } }
        .onChange(of: pages.count) { _, count in if page >= count { page = max(0, count - 1); focused = nil } }
        .onChange(of: phase) { _, phase in
            appPhase=phase
            if phase == .background { questions.cancel(); stopAll(); room.discardRoom() }
            else if phase == .inactive { reader.stop(); labels.stop(); guide.suspendFeedback(); navigationHaptics.stop() }
            else { readingLabel=false; resumeLiveFeedback() }
        }
        .onChange(of: room.running) { _, running in if !running { scanID = UUID() } }
        .photosPicker(isPresented: $selectingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }; busy = true
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw ImportFailure.unreadable }
                    documents.close(); reading = ReadablePage.prepare(try await TextImport.recognize(data)).text; reader.load(TactileEncoding.translate(reading).cells); feedback("text ready")
                } catch { fail(error.localizedDescription) }
                busy = false; photo = nil
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .pdf], allowsMultipleSelection: true) { result in
            Task {
                do {
                    let urls = try result.get(); busy = true
                    var imported: Set<UUID> = [], failures = 0
                    for url in urls {
                        do { try await documents.importFile(url); if let id = documents.active { imported.insert(id) } }
                        catch { failures += 1 }
                    }
                    if !imported.isEmpty { questionSelection = imported; questions.clear(); open(.documents) }
                    feedback("Imported \(imported.count) documents. \(failures) failed. Ask documents uses matching passages with AI.")
                } catch { fail(error.localizedDescription) }
                busy = false
            }
        }

        .sheet(isPresented: $showingConnection) { AIConnectionView() }
        .sheet(item: $entry) { item in
            CompanionEntry(title: item.title, value: item.current) { value in
                switch item.id {
                case "draft": draft = value
                case "read": documents.close(); reading = value; reader.load(TactileEncoding.translate(value).cells)
                case "question": questionWriting = value
                case "documentQuery": documentQuery = value
                case "documentURL": downloadLink(value)
                case "reply": conversation.transcript = value
                case "object": object = value; result = nil
                case "destination": destination = value; startNavigation(value)
                case "tag": if let selectedTracker { var names = (try? JSONDecoder().decode([String: String].self, from: trackerNames)) ?? [:]; names[selectedTracker.uuidString] = value; trackerNames = (try? JSONEncoder().encode(names)) ?? Data() }
                default: break
                }
                feedback("saved")
            }
        }
        .fullScreenCover(isPresented: $showingMessage) {
            TactileSurface(title: "Message", page: "", actions: [action("closeMessage", "Back", "arrow.backward") { showingMessage = false }, action("speakFull", "Speak", "speaker.wave.2") { speaker.speak(draft) }], navigation: [], focused: focused, onFocus: { id in
                focused = id; playLabel(id == "closeMessage" ? "back" : "speak")
            }, onActivate: {
                labels.stop()
                if focused == "speakFull" { speaker.speak(draft) }
                else if focused == "closeMessage" { showingMessage = false }
            }) {
                Text(draft).font(.system(.title, design: .rounded, weight: .bold)).minimumScaleFactor(0.5)
            }
        }
    }
    @ViewBuilder private var preview: some View {
        if screen == .find {
            VStack { Text(room.recording ? "Mapping room" : room.message).font(.subheadline).lineLimit(2); if !object.isEmpty { Text(object).font(.caption) } }
        } else if screen == .route, let route = guide.route {
            VStack(spacing: 5) {
                Text(guide.guiding ? (guide.suspended ? "Paused for exploration" : guide.status) : guide.current?.instructions ?? guide.status).font(.headline).lineLimit(2)
                Text(route.provider.title).font(.system(size: 14, weight: .regular)).foregroundStyle(.primary).lineLimit(1).accessibilityIdentifier("routeAttribution")
            }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("routeSummary")
        } else if screen == .read, let cell = reader.current {
            HStack { Text(cell.label).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(2); Spacer(); if reader.mode == .braille { BrailleDots(dots: cell.dots, active: reader.activeDot) } else { Text(cell.label == "Space" ? "/" : Morse.code(cell.label)).font(.title2.monospaced()).accessibilityLabel("Morse " + Morse.code(cell.label)) }; Text((documents.current == nil ? "" : "p\(documents.page + 1) ") + "\(reader.index + 1)/\(reader.cells.count)").font(.caption) }.accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText).accessibilityLabel((documents.current == nil ? "" : "p\(documents.page + 1) ") + "\(reader.index + 1)/\(reader.cells.count). " + cell.label + ". " + (reader.mode == .morse ? "Morse " + Morse.code(cell.label) : "Dots " + cell.dots.sorted().map(String.init).joined(separator: " "))).accessibilityIdentifier("readerPosition").padding(16).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
        } else {
            VStack(spacing: 6) {
                Text(previewText).font(.system(.headline, design: .rounded)).lineLimit(2).minimumScaleFactor(0.7).accessibilityIdentifier("surfaceStatus")
                if screen == .write { Text(page == 0 ? ink.message : "Selected: \(character ?? "none")").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("selectedCharacter") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }
    private var previewText: String {
        switch screen {
        case .home: return focused.flatMap { id in (allActions + footer).first(where: { $0.id == id })?.title } ?? "Brailio"
        case .questions: return questions.busy ? questions.status : questions.answer.isEmpty ? (questionWriting.isEmpty ? questions.status : questionWriting) : questions.answer
        case .questionDocuments: return "Selected \(questionSelection.count) of \(documents.documents.count). Up to ten documents and six hundred pages."
        case .questionSources: return "\(questions.sources.count) source passages. Double tap a source to feel its title, page and text."
        case .documents, .library, .online: return documentQuery.isEmpty ? documents.status : documentQuery + ". " + documents.status
        case .write: return !ink.preview.isEmpty ? ink.preview : handwritingText.isEmpty ? "Write a word" : String(handwritingText.suffix(70))
        case .talk: return page == 0 ? (draft.isEmpty ? "Empty message" : String(draft.suffix(70))) : String(conversation.transcript.suffix(70))
        case .find: return result?.text ?? "Find: \(object)"
        case .storage: return "Saved on this iPhone: \(notes.count) notes, \(savedPlaces.count) places, \(room.pins.count) objects, \(documents.documents.count) books"
        case .notes: return notes.first.map { "Latest: " + $0.text } ?? "No notes yet. Write, then Save."
        case .objects: return room.pins.isEmpty ? "No saved objects yet. Find an object to save it." : "Double tap an object to find it again"
        case .go: return (destination.isEmpty ? "Choose destination" : destination) + ". " + guide.provider.title
        case .route: return guide.guiding ? (guide.suspended ? "Explore paused. Resume to continue." : guide.status) : guide.current?.instructions ?? guide.status
        case .learn: return TactileMode.current.title + " " + Braille.alphabet[selectedLetter].0.uppercased() + (TactileMode.current == .morse ? " " + Morse.code(Braille.alphabet[selectedLetter].0) : "")
        case .settings: return "Tactile code: " + TactileMode.current.title
        default: return notice
        }
    }
    private var handwritingText: String {
        get { writingQuestion ? questionWriting : writingDestination ? destinationWriting : writingSearch ? searchWriting : writingObject ? objectWriting : draft }
        nonmutating set { if writingQuestion { questionWriting = newValue } else if writingDestination { destinationWriting = newValue } else if writingSearch { searchWriting = newValue } else if writingObject { objectWriting = newValue } else { draft = newValue } }
    }
    private var directPanel: AnyView? {
        if screen == .write && page == 0 {
            return AnyView(FingerInkCanvas(ink: ink).background(Theme.surface, in: RoundedRectangle(cornerRadius: 24)).clipShape(RoundedRectangle(cornerRadius: 24)))
        }
        if screen == .route && page == 0, let route=guide.route, route.provider == .apple {
            return AnyView(TactileRouteMap(route:route,location:guide.location,onExplore:{ text in
                mapFocusLabel=text; guide.suspendFeedback(); navigationHaptics.stop(); pending?.cancel(); reader.stop(); labels.stop(); playLabel(text)
            },onSelect:{ index, label in
                if let index { guide.selectStep(index) }; page=1; focused=nil; playLabel(label)
            }))
        }
        if screen == .find && page == 0 {
            return AnyView(RoomHoldPanel(image: room.previewImage, recording: room.recording, guiding: room.guiding, canRetry: room.needsRescan && !object.isEmpty, onHold: beginRoomCapture, onRelease: endRoomCapture, onCheck: { reader.stop(); labels.stop(); focused = nil; readingLabel=false; room.check() }))
        }
        return nil
    }
    private func finishWriting() {
        if !ink.strokes.isEmpty { finishAfterRecognition = true; ink.finishNow() }
        else { completeWriting() }
    }
    private func completeWriting() {
        ink.clear()
        if writingQuestion {
            let query = questionWriting.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { feedback("empty"); return }
            writingQuestion = false; back(); askDocuments()
        } else if writingDestination {
            let query=destinationWriting.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !query.isEmpty else { feedback("empty"); return }
            destination=query; writingDestination=false; back(); startNavigation(query)
        } else if writingSearch {
            let query = searchWriting.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { feedback("empty"); return }
            documentQuery = query; writingSearch = false; back(); searchLibraryFirst()
        } else if writingObject {
            let query = objectWriting.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { feedback("empty"); return }
            object = query; writingObject = false; back(keepRoom: true); startFinding()
        } else { page = 3; focused = nil; feedback("draft ready") }
    }
    private func startNavigation(_ query: String) {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { feedback("empty"); return }
        routeTask?.cancel(); let id=UUID(); navigationID=id; startingRoute=true
        pending?.cancel(); reader.stop(); labels.stop(); guide.chooseProvider(.apple)
        routeTask=Task {
            await guide.prepareDestination(query)
            while appPhase == .inactive && !Task.isCancelled { try? await Task.sleep(for:.milliseconds(100)) }
            guard !Task.isCancelled, navigationID == id, appPhase == .active else { return }
            startingRoute=false; routeTask=nil
            if guide.route != nil {
                open(.route); pending?.cancel(); labels.stop(); readingLabel=false; focused=nil; guide.start()
            } else if guide.places.count > 1 { open(.places); feedback("choose destination") }
            else { fail(guide.error ?? guide.status) }
        }
    }
    private func beginRoomCapture() {
        pending?.cancel(); labels.stop(); reader.stop(); room.stop(); readingLabel=false
        captureRequested = true; focused = nil; room.recordRoom(); notice = "Mapping positions with temporary snapshots. No video is saved."
    }
    private func endRoomCapture() { room.finishRoom() }
    private func startFinding() {
        pending?.cancel(); reader.stop(); labels.stop(); readingLabel=false; focused = nil; page = 0
        room.find(object)
    }
    private func action(_ id: String, _ title: String, _ symbol: String = "circle", value: String = "", enabled: Bool = true, selected: Bool = false, _ perform: @escaping () -> Void) -> TouchAction {
        TouchAction(id: id, title: title, symbol: symbol, value: value, enabled: enabled, selected: selected, perform: perform)
    }
    private func focus(_ id: String) {
        continuousBook = false; readingLabel=true
        guard focused != id else { return }
        pending?.cancel(); reader.stop(); labels.stop(); room.suspendFeedback(); guide.suspendFeedback(); navigationHaptics.stop(); focused = id
        if !id.hasPrefix("nav") { lastControl = id }
        guard let item = (allActions + footer).first(where: { $0.id == id }) else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(180)); guard !Task.isCancelled else { return }
            playLabel((item.title + (item.value.isEmpty ? "" : " " + item.value)).lowercased() + (item.enabled ? "" : " unavailable"))
        }
    }
    private func activate() {
        guard let focused, let item = (allActions + footer).first(where: { $0.id == focused }) else { return }
        pending?.cancel(); labels.stop(); readingLabel=false
        if item.enabled { item.perform() } else { feedback("unavailable") }
    }
    private func replay() {
        reader.stop()
        if screen == .route && page == 0 && !mapFocusLabel.isEmpty { playLabel(mapFocusLabel) }
        else if let lastControl, let item = allActions.first(where: { $0.id == lastControl }) { playLabel((item.title + " " + item.value).lowercased()) }
        else { playLabel(screen.rawValue.lowercased()) }
    }
    private func playLabel(_ text: String) { readingLabel=true; navigationHaptics.stop(); labels.playText(ReadablePage.prepare(text).text) }
    private func resumeLiveFeedback() {
        guard appPhase == .active, !readingLabel else { return }
        if screen == .route && guide.guiding && guide.suspended { guide.start() }
        if screen == .find && room.feedbackRequested && (room.guiding || room.needsRescan || room.searching) { room.resumeFeedback() }
    }
    private func feedback(_ text: String) { continuousBook = false; pending?.cancel(); reader.stop(); notice = text; playLabel(text) }
    private func fail(_ text: String) { continuousBook = false; reader.stop(); notice = text; if screen == .find { room.message = text }; if [.documents, .library, .online].contains(screen) { documents.status = text }; playLabel("error") }
    private func stopAll(keepRoom: Bool = false) { readingLabel=false; navigationID=UUID(); routeTask?.cancel(); routeTask=nil; startingRoute=false; continuousBook = false; pageRequest = UUID(); loadingPage = false; if documents.active != nil && screen == .read { documents.bookmark(reader.index) }; captureRequested = false; finishAfterRecognition = false; spaceAfterRecognition = false; ink.clear(); if keepRoom { room.suspendFeedback() } else { room.stop() }; pending?.cancel(); reader.stop(); labels.stop(); conversation.stop(); guide.stop(); navigationHaptics.stop(); scanner.stop(); speaker.stop(); scanID = UUID() }
    private func open(_ next: Screen) { if next == .route { mapFocusLabel="" }; if next == .write { writingQuestion = false; writingObject = false; writingSearch = false; writingDestination = false }; stopAll(); history.append(screen); clearDraftRequested = false; clearAllRequested = false; screen = next; page = 0; focused = nil; lastControl = nil; notice = next.rawValue.lowercased(); if next == .read { if documents.active != nil { loadDocumentPage(play: false) } else { reader.load(TactileEncoding.translate(reading).cells) } }
        if next == .find { room.start() }; playLabel(next == .write ? "draw" : next == .find ? "hold center" : next.rawValue.lowercased()) }
    /// Faith keeps camera tracking alive while the request is entered, so the scan and AR world survive.
    private func openObjectWriting() {
        stopAll(keepRoom: true); history.append(screen); clearDraftRequested = false; clearAllRequested = false
        screen = .write; page = 0; focused = nil; lastControl = nil; notice = "write"
        writingSearch = false; writingDestination = false; objectWriting = ""; writingObject = true; playLabel("draw")
    }
    private func back(keepRoom: Bool = false) { if screen == .questions { questions.cancel() }; let keep = keepRoom || (screen == .write && writingObject); if screen == .write { writingQuestion = false; writingObject = false; writingSearch = false; writingDestination = false }; stopAll(keepRoom: keep); clearDraftRequested = false; clearAllRequested = false; screen = history.popLast() ?? .home; page = 0; focused = nil; lastControl = nil; notice = screen.rawValue.lowercased(); if screen == .read { if documents.active != nil { loadDocumentPage(play: false) } else { reader.load(TactileEncoding.translate(reading).cells) } }; if screen == .find { room.start() }; playLabel(screen.rawValue.lowercased()) }
    private func nextPage() { clearDraftRequested = false; clearAllRequested = false; pending?.cancel(); reader.stop(); page = (page + 1) % pages.count; focused = nil; lastControl = nil; feedback("page \(page + 1)") }
    private func cuePattern(_ label: String, _ dots: Set<Int>) { readingLabel=true; navigationHaptics.stop(); reader.stop(); labels.load([BrailleCell(label: label, dots: dots)], mode: .braille); labels.play(single: true) }
    private func entry(_ id: String, _ title: String, _ text: String) { pending?.cancel(); reader.stop(); entry = Entry(id: id, title: title, current: text) }
    private func chunks(_ values: [TouchAction]) -> [[TouchAction]] {
        guard !values.isEmpty else { return [[action("empty", "Empty", "tray", enabled: false) {}]] }
        return stride(from: 0, to: values.count, by: 6).map { Array(values[$0..<min($0 + 6, values.count)]) }
    }
    private var pages: [[TouchAction]] {
        switch screen {
        case .home:
            return [[
                action("homeRead", "Read", "waveform.path") { open(.read) },
                action("homeWrite", "Write", "circle.grid.2x2") { writingObject = false; open(.write) },
                action("homeTalk", "Talk", "bubble.left.and.bubble.right") { open(.talk) },
                action("homeFind", "Find", "viewfinder") { open(.find) },
                action("homeGo", "Go", "location") { open(.go) },
                action("homeLearn", "Learn", "hand.tap") { open(.learn) }
            ], [action("homeSettings", "Settings", "slider.horizontal.3") { open(.settings) }, action("homeSaved", "Saved", "tray.full", value: "\(notes.count + savedPlaces.count + room.pins.count + documents.documents.count)") { open(.storage) }]]
        case .write:
            return [
                [],
                [1,4,2,5,3,6].map { dot in action("dot\(dot)", "\(dot)", dots.contains(dot) ? "checkmark.circle.fill" : "circle", value: dots.contains(dot) ? "On" : "Off", selected: dots.contains(dot)) {
                    if dots.contains(dot) { dots.remove(dot) } else { dots.insert(dot) }
                    cuePattern("Dot \(dot)", [dot])
                } },
                [action("enterCharacter", "Enter", "plus", enabled: character != nil) { commitCharacter() },
                 action("writeSpace", "Space", "space") { draft += " "; dots = []; feedback("space") },
                 action("writeDelete", "Delete", "delete.left", enabled: !draft.isEmpty) { deleted = draft.removeLast(); feedback("deleted") },
                 action("writeUndo", "Undo", "arrow.uturn.backward", enabled: deleted != nil) { if let deleted { draft.append(deleted); self.deleted = nil; feedback("restored") } },
                 action("writeCapitals", "Capital", "textformat", value: capitals ? "On" : "Off", selected: capitals) { capitals.toggle(); feedback(capitals ? "capital on" : "capital off") },
                 action("writeNumbers", "Number", "number", value: numbers ? "On" : "Off", selected: numbers) { numbers.toggle(); feedback(numbers ? "number on" : "number off") }],
                [action("writeSave", "Save", "note.text", enabled: !draft.isEmpty) { saveNote() },
                 action("writeFeel", "Read", "waveform", enabled: !draft.isEmpty) { reading = draft; open(.read) },
                 action("writeTalk", "Talk", "bubble.left") { open(.talk) },
                 action("writeFind", "Find", "viewfinder", enabled: !draft.isEmpty) { object = draft; result = nil; open(.find) },
                 action("writeGo", "Go", "location", enabled: !draft.isEmpty) { destination = draft; open(.go); startNavigation(draft) },
                 action("writeBraille", "Braille", "circle.grid.2x2") { page = 1; focused = nil; feedback("braille") }],
                [action("writeCorrect", "Correct", "checkmark.abc", enabled: !busy && !draft.isEmpty && (DemoAccess.configured || !BackendAccess.token.isEmpty)) { assist("correct") },
                 action("writeComplete", "Continue", "text.append", enabled: !busy && !draft.isEmpty && (DemoAccess.configured || !BackendAccess.token.isEmpty)) { assist("complete") },
                 action("writeReview", "Review", "waveform", enabled: suggestion != nil) { if let suggestion { reader.playText(suggestion) } },
                 action("writeAccept", "Accept", "checkmark", enabled: suggestion != nil && draft == suggestionSource) { if let suggestion { draft = suggestion; self.suggestion = nil; feedback("accepted") } },
                 action("writeDismiss", "Dismiss", "xmark", enabled: suggestion != nil) { suggestion = nil; feedback("dismissed") },
                 action("writeClear", "Clear draft", "trash") { clearDraftRequested = true; page = 5; focused = nil; feedback("confirm clear") }],
                [action("writeConfirmClear", "Confirm clear", "trash", enabled: clearDraftRequested) { draft = ""; dots = []; deleted = nil; suggestion = nil; clearDraftRequested = false; page = 0; focused = nil; feedback("cleared") },
                 action("writeCancelClear", "Cancel", "xmark") { clearDraftRequested = false; page = 0; focused = nil; feedback("cancelled") },
                 action("writeReset", "Reset dots", "arrow.counterclockwise") { dots = []; feedback("reset") },
                 action("writeKeys", "Keys", "circle.grid.2x2") { page = 1; focused = nil; feedback("keys") }]
            ]
        case .read:
            let valid = TactileEncoding.translate(reading).unsupported.isEmpty && !reading.isEmpty
            return [[
                action("readPlay", reader.isPlaying ? "Pause" : "Play", reader.isPlaying ? "pause.fill" : "play.fill", enabled: valid && !loadingPage) { playReading() },
                action("readRepeat", "Repeat", "arrow.counterclockwise", enabled: valid) { reader.play(single: true) },
                action("readPrevious", "Previous", "backward.end.fill", enabled: reader.index > 0) { reader.move(-1); reader.play(single: true) },
                action("readNext", "Forward", "forward.end.fill", enabled: reader.index < reader.cells.count - 1) { reader.move(1); reader.play(single: true) },
                action("readDraft", "Use draft", "doc.on.doc", enabled: !draft.isEmpty) { documents.close(); reading = draft; reader.load(TactileEncoding.translate(draft).cells); feedback("loaded") },
                action("readDocuments", "Documents", "books.vertical") { open(.documents) }
            ], [action("readPhoto", "Photo", "photo") { selectingPhoto = true },
                action("readFile", "File", "doc") { importing = true },
                action("readType", "Type", "keyboard") { entry("read", "Companion text input", reading) },
                action("readSample", "Example", "text.quote") { documents.close(); reading = "hello"; reader.load(TactileEncoding.translate(reading).cells); feedback("hello") },
                action("readSlower", "Slower", "tortoise") { pace = min(0.6, pace + 0.04); feedback("slower") },
                action("readFaster", "Faster", "hare") { pace = max(0.18, pace - 0.04); feedback("faster") }], [
                action("bookPrevious", "Previous page", "arrow.left", enabled: documents.active != nil && documents.page > 0 && !loadingPage) { changeDocumentPage(-1) },
                action("bookNext", "Next page", "arrow.right", enabled: documents.current.map { documents.page + 1 < $0.pages } == true && !loadingPage) { changeDocumentPage(1) },
                action("bookReadAll", "Read book", "play.fill", enabled: documents.active != nil && !loadingPage && !reader.cells.isEmpty) { continuousBook = true; labels.stop(); reader.play() },
                action("bookPosition", "Position", "bookmark") { feedback(statusText) },
                action("bookLibrary", "Library", "books.vertical") { open(.library) },
                action("bookClose", "Close book", "xmark", enabled: documents.active != nil) { continuousBook = false; documents.close(); reading = "hello"; reader.load(TactileEncoding.translate(reading).cells); feedback("closed") }
            ], [action("readSave", "Save text", "square.and.arrow.down", enabled: !reading.isEmpty) { saveNote(reading) },
                action("readSaved", "Saved", "tray.full") { open(.storage) },
                action("bookAsk", "Ask this book", "questionmark.bubble", enabled: documents.active != nil) { if let id = documents.active, questionSelection != [id] { questionSelection = [id]; questions.clear() }; openQuestions() }]]
        case .questions:
            return [[action("questionWrite", "Write question", "hand.draw", enabled: !questions.busy && !questionSelection.isEmpty) { open(.write); writingQuestion = true; questionWriting = "" },
                     action("questionChoose", "Choose documents", "doc.on.doc", value: "\(questionSelection.count)", enabled: !questions.busy) { open(.questionDocuments) },
                     action("questionAsk", "Ask AI", "sparkles", enabled: !questionWriting.isEmpty && !questions.busy && !questionSelection.isEmpty) { askDocuments() },
                     action("questionRead", "Read answer", "waveform", enabled: !questions.answer.isEmpty) { labels.stop(); reader.playText(ReadablePage.prepare(questions.answer).text) },
                     action("questionSources", "Sources", "text.book.closed", enabled: !questions.sources.isEmpty) { open(.questionSources) },
                     action("questionStop", "Stop", "stop.fill") { questions.cancel(); reader.stop(); feedback("stopped") }],
                    [action("questionType", "Type question", "keyboard", enabled: !questions.busy) { entry("question", "Companion document question", questionWriting) },
                     action("questionReview", "Review question", "waveform", enabled: !questionWriting.isEmpty) { reader.playText(ReadablePage.prepare(questionWriting).text) },
                     action("questionSave", "Save answer", "square.and.arrow.down", enabled: !questions.answer.isEmpty) { saveNote(questions.answer + " " + questions.sources.map(\.label).joined(separator: " ")) },
                     action("questionPrivacy", "How it works", "info.circle") { feedback("Asking sends up to twelve matching passages from selected files to AI. Answers may be wrong. Review Sources. Up to ten documents and six hundred pages.") }]]
        case .questionDocuments:
            return [[action("questionAll", "Select all", "checkmark.circle", enabled: documents.documents.count <= 10) { questionSelection = Set(documents.documents.map(\.id)); questions.clear(); feedback("all selected") },
                     action("questionNone", "Clear selection", "xmark") { questionSelection = []; questions.clear(); feedback("selection cleared") },
                     action("questionDone", "Use selection", "checkmark", enabled: !questionSelection.isEmpty) { back() }]] + chunks(documents.documents.enumerated().map { index, item in
                         action("questionDoc\(index)", "Document \(index + 1)", "doc.text", value: item.title, selected: questionSelection.contains(item.id)) {
                             if questionSelection.contains(item.id) { questionSelection.remove(item.id) }
                             else if questionSelection.count < 10 { questionSelection.insert(item.id) }
                             else { feedback("choose up to ten documents"); return }
                             questions.clear(); feedback(questionSelection.contains(item.id) ? "selected" : "removed")
                         }
                     })
        case .questionSources:
            return chunks(questions.sources.enumerated().map { index, source in action("questionSource\(index)", "Source \(index + 1)", "doc.text", value: source.label) { labels.stop(); reader.playText(ReadablePage.prepare(source.label + " " + source.text).text) } })
        case .documents:
            return [[
                action("docWrite", "Write search", "hand.draw") { searchWriting = ""; open(.write); writingSearch = true },
                action("docAsk", "Ask documents", "questionmark.bubble", enabled: !documents.documents.isEmpty) { openQuestions() },
                action("docLibrary", "My library", "books.vertical") { documentQuery = ""; open(.library) },
                action("docFiles", "Phone Files", "folder") { importing = true },
                action("docOnline", "Online PDFs", "globe", enabled: !documentQuery.isEmpty && !documents.busy) { searchDocumentsOnline() },
                action("docLink", "PDF link", "link") { entry("documentURL", "Direct HTTPS PDF or text link", "") }
            ], [action("docDraft", "Search draft", "doc", enabled: !draft.isEmpty) { documentQuery = draft; searchLibraryFirst() }, action("docType", "Type search", "keyboard") { entry("documentQuery", "Companion document search", documentQuery) },
                action("docPaste", "Paste link", "doc.on.clipboard") { if let link = UIPasteboard.general.string { downloadLink(link) } else { feedback("empty") } },
                action("docLimits", "Search scope", "info.circle") { feedback("Library first. Phone Files opens Apple file search. Online searches Internet Archive public PDFs. Other sites need a direct link.") }]]
        case .library:
            let matches = documents.matching(documentQuery)
            let controls = [action("libraryOnline", "Search online", "globe", enabled: !documentQuery.isEmpty && !documents.busy) { searchDocumentsOnline() }, action("libraryFiles", "Phone Files", "folder") { importing = true }, action("libraryAsk", "Ask documents", "questionmark.bubble", enabled: !documents.documents.isEmpty) { openQuestions() }]
            return [controls] + chunks(matches.enumerated().map { index, item in action("library\(index)", "Book \(index + 1)", "book", value: item.title) { documents.select(item.id); open(.read) } })
        case .online:
            return chunks(documents.results.enumerated().map { index, item in action("online\(index)", "PDF \(index + 1)", "arrow.down.doc", value: item.title, enabled: !busy) {
                busy = true; feedback("downloading")
                Task { do { try await documents.download(item); open(.read) } catch { fail(error.localizedDescription) }; busy = false }
            } })
        case .talk:
            return [[action("talkWrite", "Write", "circle.grid.2x2") { writingObject = false; open(.write) },
                     action("talkSpeak", "Speak", "speaker.wave.2", enabled: !draft.isEmpty) { conversation.stop(); speaker.speak(draft) },
                     action("talkShow", "Show", "text.bubble", enabled: !draft.isEmpty) { showingMessage = true },
                     action("talkRead", "Read", "waveform", enabled: !draft.isEmpty) { reader.playText(draft) },
                     action("talkReply", "Reply", "bubble.right") { page = 1; focused = nil; feedback("reply") },
                     action("talkType", "Type", "keyboard") { entry("draft", "Companion message input", draft) }],
                    [action("replyListen", conversation.listening ? "Stop" : "Listen", conversation.listening ? "stop.fill" : "mic", enabled: !busy) { listen() },
                     action("replyRead", "Read", "waveform", enabled: !conversation.transcript.isEmpty) { conversation.stop(); reader.playText(conversation.transcript) },
                     action("replyType", "Type", "keyboard") { entry("reply", "Companion reply input", conversation.transcript) },
                     action("replySend", "Write", "circle.grid.2x2") { writingObject = false; open(.write) },
                     action("replyCopy", "Keep reply", "doc", enabled: !conversation.transcript.isEmpty) { documents.close(); reading = conversation.transcript; open(.read) },
                     action("replyClear", "Clear reply", "xmark") { conversation.stop(); conversation.transcript = ""; feedback("cleared") }],
                    ["Hello, I use touch to communicate.", "Please type your reply.", "Please give me more time.", "Yes.", "No.", "Thank you."].enumerated().map { index, phrase in
                        action("phrase\(index)", ["Hello", "Type reply", "More time", "Yes", "No", "Thanks"][index], "text.bubble") { draft = phrase; feedback(phrase) }
                    },
                    [action("talkSave", "Save message", "square.and.arrow.down", enabled: !draft.isEmpty) { saveNote() },
                     action("talkSaveReply", "Save reply", "square.and.arrow.down", enabled: !conversation.transcript.isEmpty) { saveNote(conversation.transcript) },
                     action("talkSaved", "Saved", "tray.full") { open(.storage) }]]
        case .find:
            return [[], [
                action("findWrite", "Write name", "hand.draw") { openObjectWriting() },
                action("findDraft", "Use draft", "doc", enabled: !draft.isEmpty) { object = draft; feedback(object) },
                action("findSearch", "Find position", "mappin", enabled: !object.isEmpty && !room.searching) { startFinding() },
                action("findCheck", "Check position", "checkmark", enabled: room.guiding) { labels.stop(); focused = nil; room.resumeFeedback(); room.check() },
                action("findStop", "Stop", "stop.fill") { captureRequested = false; room.stop(); feedback("stopped") },
                action("findReject", "Wrong object", "xmark") { room.reject() }
            ], [
                action("findRecord", room.recording ? "Finish scan" : "Map room", "viewfinder") { if room.recording { endRoomCapture() } else { beginRoomCapture() } },
                action("findResume", "Resume position", "mappin", enabled: !object.isEmpty) { focused = nil; readingLabel=false; if room.guiding { room.resumeFeedback() } else { room.find(object) }; page = 0 },
                action("findMark", "Mark center", "mappin.and.ellipse", enabled: !object.isEmpty && !room.roomFrames.isEmpty && !room.searching) { focused = nil; room.markCenter(object); page = 0 },
                action("findDiscard", "Clear scan", "trash") { captureRequested = false; room.discardRoom(); feedback("cleared") },
                action("findGuide", "Cue guide", "hand.tap") { readingLabel=true; reader.playText("Single approach pulses grow stronger and faster near the saved position. Two short pulses mean tracking is uncertain. Camera tracking is required. Objects may move. No obstacle detection.") },
                action("findTags", "Tags", "antenna.radiowaves.left.and.right") { open(.trackers) }
            ]] + chunks(room.pins.enumerated().map { index, pin in action("pin\(index)", "Position \(index + 1)", "mappin", value: pin.name) { object = pin.name; startFinding() } })
        case .go:
            return [[action("goWrite", "Write destination", "hand.draw") { destinationWriting=""; open(.write); writingDestination=true },
                     action("goDraft", "Use draft", "doc", enabled: !draft.isEmpty && !startingRoute) { destination = draft; startNavigation(draft) },
                     action("goLocation", "Location", "location") { guide.enable(); feedback("location requested") },
                     action("goSearch", startingRoute ? "Starting" : "Start route", "location.fill", enabled: !destination.isEmpty && !startingRoute) { startNavigation(destination) },
                     action("goSaved", "Saved", "bookmark") { open(.saved) },
                     action("goCurrent", "Current route", "map", enabled: guide.route != nil) { open(.route) }], [
                     action("goApple", "Apple route", "map", selected: guide.provider == .apple) { guide.chooseProvider(.apple); feedback("Apple Maps selected") },
                     action("goGoogle", "Google route", "map", selected: guide.provider == .google) { guide.chooseProvider(.google); feedback("Google Maps selected. Server setup required for in app routes.") },
                     action("goGoogleOpen", "Google Maps", "arrow.up.forward.app", enabled: !destination.isEmpty) { guide.stop(); openURL(GoogleRouting.directionsURL(query: destination)) },
                     action("goType", "Type destination", "keyboard") { entry("destination", "Companion destination input", destination) },
                     action("goProtocol", "Feedback guide", "waveform") { feedback("Approach pulses grow stronger and faster near the destination. Long pulses mean a route error. Two short pulses mean uncertain GPS or direction. No safe crossing detection.") }
                 ], [
                     action("goPrivacy", "Privacy", "hand.raised") { openURL(URL(string: "https://brailio-api.vercel.app/privacy.html")!) },
                     action("goTerms", "Terms", "doc.text") { openURL(URL(string: "https://brailio-api.vercel.app/terms.html")!) }
                 ]]
        case .places:
            return chunks(guide.places.enumerated().map { index, place in action("place\(index)", "Place \(index + 1)", "mappin", value: place.name ?? "") {
                notice = place.name ?? "place"; reader.playText(place.name ?? "place")
                Task { await guide.preview(place); if guide.route != nil && screen == .places { open(.route); pending?.cancel(); labels.stop(); readingLabel=false; focused=nil; guide.start() } else { fail(guide.error ?? "route unavailable") } }
            } })
        case .route:
            return [[], [action("routeRead", "Read step", "waveform", enabled: guide.current != nil) { if let text = guide.current?.instructions { readingLabel=true; reader.playText(ReadablePage.prepare(text).text) } },
                     action("routeStart", guide.guiding ? "Resume" : "Start", "location.fill") { pending?.cancel(); reader.stop(); labels.stop(); readingLabel=false; focused = nil; guide.start() },
                     action("routeNext", "Confirm step", "checkmark") { focused = nil; guide.next() },
                     action("routePreview", "Preview", "list.bullet") { readingLabel=true; reader.playText(ReadablePage.prepare(guide.steps.map(\.instructions).joined(separator: ". ")).text) },
                     action("routeSave", "Save", "bookmark") { var saved = UserDefaults.standard.stringArray(forKey: "savedPlaces") ?? []; if !saved.contains(destination) { saved.append(destination) }; UserDefaults.standard.set(saved, forKey: "savedPlaces"); feedback("saved") },
                     action("routeSafety", "Route limits", "info.circle") { notice = "GPS is approximate. This app cannot detect hazards or safe crossings. Use your usual mobility aid. Guidance stops in the background."; readingLabel=true; reader.playText("GPS is approximate. No obstacle or safe crossing detection. Use your mobility aid.") }],
                    [action("routeStop", "Stop", "stop.fill") { guide.stop(); navigationHaptics.stop(); feedback("stopped") },
                     action("routeGoogle", "Google Maps", "arrow.up.forward.app", enabled: guide.googleURL != nil) { if let url = guide.googleURL { guide.stop(); openURL(url) } },
                     action("routeReroute", "New route", "arrow.triangle.turn.up.right.diamond", enabled: !guide.busy) { Task { await guide.reroute(); if let error = guide.error { fail(error) } else { feedback("review new route before starting") } } },
                     action("routeProtocol", "Feedback guide", "waveform") { feedback("Single approach pulses intensify near the destination. Long pulses mean deviation. Two short pulses mean uncertain. Use your mobility aid. Resume after exploring controls.") },
                     action("routeProvider", "Approach pulses", "waveform", value:guide.proximityEnabled ? "On" : "Off", selected:guide.proximityEnabled) { guide.proximityEnabled.toggle(); feedback(guide.proximityEnabled ? "approach pulses on. Resume guidance" : "silent alignment mode. Resume guidance") },
                     action("routeStatus", "Route status", "info.circle") { feedback(guide.status) }],
                    [action("routeTestStrong", "Strong test", "waveform") { navigationHaptics.preview(RouteFeedback(kind: .deviated, strength: 1)) },
                     action("routeTestSoft", "Soft test", "waveform") { navigationHaptics.preview(RouteFeedback(kind: .deviated, strength: 0.25)) },
                     action("routeTestSilent", "Silent test", "speaker.slash") { navigationHaptics.stop() },
                     action("routeTestUncertain", "Uncertain test", "questionmark") { navigationHaptics.preview(.uncertain) },
                     action("routeTestStop", "Stop test", "stop.fill") { navigationHaptics.stop(); feedback("stopped") },
                     action("routeTestLimits", "Route limits", "info.circle") { feedback("GPS cannot establish a safe crossing or detect obstacles. Use your mobility aid. Guidance stops outside this screen.") }]]
        case .saved:
            return chunks((UserDefaults.standard.stringArray(forKey: "savedPlaces") ?? []).enumerated().map { index, place in action("saved\(index)", "Place \(index + 1)", "bookmark", value: place) { destination = place; open(.go); startNavigation(place) } })
        case .learn:
            let letter = Braille.alphabet[selectedLetter]
            return [[action("learnPlay", "Play", "waveform") { reader.load(TactileEncoding.translate(letter.0).cells); reader.play(single: true); if !practiced.contains(letter.0) { practiced += letter.0 } },
                     action("learnPrevious", "Previous", "arrow.left", enabled: selectedLetter > 0) { selectedLetter -= 1; feedback(Braille.alphabet[selectedLetter].0) },
                     action("learnNext", "Forward", "arrow.right", enabled: selectedLetter < 25) { selectedLetter += 1; feedback(Braille.alphabet[selectedLetter].0) },
                     action("learnName", "Letter", "textformat") { feedback(letter.0) },
                     action("learnDots", TactileMode.current == .morse ? "Pattern" : "Dots", "circle.grid.2x2") { if TactileMode.current == .morse { reader.playText(letter.0) } else { reader.playText(letter.1.sorted().map(String.init).joined(separator: " ")) } },
                     action("learnWrite", "Write", "pencil") { open(.write) }],
                    TactileMode.current == .morse ? [
                        action("learnMorseDot", "Dot", "circle.fill") { reader.playText("e") },
                        action("learnMorseDash", "Dash", "minus") { reader.playText("t") },
                        action("learnMorseSOS", "SOS example", "waveform") { reader.playText("sos") },
                        action("learnCodeGuide", "Timing", "info.circle") { feedback("Dot one beat. Dash three beats. One beat inside a letter. Three between letters. Seven between words.") }
                    ] : [1,4,2,5,3,6].map { dot in action("learnDot\(dot)", "\(dot)", "circle") { cuePattern("Dot \(dot)", [dot]) } }]
        case .settings:
            return [[action("settingsMorse", "Morse", "waveform", selected: tactileMode == "morse") { selectTactileMode(.morse) },
                     action("settingsBraille", "Braille", "circle.grid.2x2", selected: tactileMode == "braille") { selectTactileMode(.braille) },
                     action("settingsSlower", "Slower", "tortoise") { pace = min(0.6, pace + 0.04); feedback("slower") },
                     action("settingsFaster", "Faster", "hare") { pace = max(0.18, pace - 0.04); feedback("faster") },
                     action("settingsTest", "Test SOS", "waveform") { reader.playText("sos") },
                     action("settingsAI", "AI connection", "link", value: DemoAccess.configured ? "Private demo" : "Setup") { showingConnection = true }], [
                     action("settingsStronger", "Stronger", "plus") { intensity = min(1, intensity + 0.1); feedback("stronger") },
                     action("settingsSofter", "Softer", "minus") { intensity = max(0.2, intensity - 0.1); feedback("softer") },
                     action("settingsCodeGuide", "Code guide", "info.circle") { feedback(TactileMode.current == .morse ? "Morse uses short dots and long dashes. Learn has examples." : "Braille uses six timed dot slots. Learn has examples.") }],
                    [action("settingsClear", "Clear data", "trash") { clearAllRequested = true; feedback("confirm clear") },
                     action("settingsConfirmClear", "Confirm clear", "trash", enabled: clearAllRequested) {
                         questions.clear(); questionSelection = []; questionWriting = ""; reader.load([]); draft = ""; reading = ""; notesData = Data(); practiced = ""; trackerNames = Data(); room.deletePins(); documents.deleteAll(); UserDefaults.standard.removeObject(forKey: "savedPlaces"); clearAllRequested = false; feedback("cleared")
                     },
                     action("settingsCancelClear", "Cancel", "xmark") { clearAllRequested = false; feedback("cancelled") },
                     action("settingsVoice", "Voice check", "speaker.wave.2", value: spokenFindResults ? "On" : "Off", selected: spokenFindResults) { spokenFindResults.toggle(); feedback(spokenFindResults ? "voice on" : "voice off") }]]
        case .storage:
            return [[action("storageNotes", "Notes", "note.text", value: "\(notes.count)") { open(.notes) },
                     action("storagePlaces", "Places", "bookmark", value: "\(savedPlaces.count)") { open(.saved) },
                     action("storageObjects", "Objects", "mappin", value: "\(room.pins.count)") { open(.objects) },
                     action("storageLibrary", "Library", "books.vertical", value: "\(documents.documents.count)") { documentQuery = ""; open(.library) },
                     action("storageSaveDraft", "Save draft", "square.and.arrow.down", enabled: !draft.isEmpty) { saveNote() },
                     action("storageWhere", "Storage", "iphone") { feedback("Saved on this iPhone only. Nothing is uploaded.") }]]
        case .objects:
            return chunks(room.pins.reversed().enumerated().map { index, pin in action("object\(index)", pin.name, "mappin", value: pin.seen ?? "position saved") { object = pin.name; open(.find); startFinding() } })
        case .notes:
            return chunks(notes.enumerated().map { index, note in action("note\(index)", "Note \(index + 1)", "note.text", value: String(note.text.prefix(24))) { documents.close(); reading = note.text; open(.read) } })
        case .trackers:
            let names = (try? JSONDecoder().decode([String: String].self, from: trackerNames)) ?? [:]
            let controls = [action("tagScan", scanner.scanning ? "Stop" : "Scan", "antenna.radiowaves.left.and.right") { if scanner.scanning { scanner.stop(); feedback("stopped") } else { scanner.start() } }, action("tagName", "Name tag", "pencil", enabled: selectedTracker != nil) { entry("tag", "Companion tag name", "") }]
            return [controls] + chunks(scanner.trackers.enumerated().map { index, tracker in action("tag\(tracker.id)", "Tag \(index + 1)", "sensor.tag.radiowaves.forward", value: names[tracker.id.uuidString] ?? tracker.name) { selectedTracker = tracker.id; scanner.selected = tracker.id; focused = nil; reader.playText(names[tracker.id.uuidString] ?? tracker.name) } })
        }
    }
    private func openQuestions() {
        questionSelection.formIntersection(Set(documents.documents.map(\.id)))
        if questionSelection.isEmpty, let id = documents.active ?? documents.documents.first?.id { questionSelection = [id] }
        open(.questions)
    }
    private func askDocuments() {
        pending?.cancel(); reader.stop(); labels.stop(); readingLabel = false
        questions.ask(questionWriting, ids: questionSelection, library: documents) { success in
            guard screen == .questions, phase == .active else { return }
            if success { labels.stop(); readingLabel = true; reader.playText(ReadablePage.prepare(questions.answer).text) }
            else { feedback(questions.status) }
        }
    }
    private func selectTactileMode(_ mode: TactileMode) {
        stopAll(); tactileMode = mode.rawValue; practiced = ""
        // Cell offsets differ between codes; retain the document page and restart its characters.
        if documents.active != nil { documents.bookmark(0) }
        reader.load(TactileEncoding.translate(reading, mode: mode).cells, mode: mode)
        feedback(mode.title + " selected")
    }
    private func commitCharacter() {
        guard let character else { return }
        draft += character; dots = []; deleted = nil; page = 1; focused = nil
        notice = "Added \(character)."; playLabel(character)
    }
    private func playReading() {
        continuousBook = false
        let translation = TactileEncoding.translate(reading)
        guard translation.unsupported.isEmpty else { fail("Unsupported characters. Use English letters, digits and basic punctuation."); return }
        if reader.isPlaying { reader.stop() }
        else {
            if reader.cells.map(\.label) != translation.cells.map(\.label) { reader.load(translation.cells) }
            reader.play()
        }
    }
    private func loadDocumentPage(play: Bool) {
        let request = UUID(); pageRequest = request; loadingPage = true; reader.load([]); reading = ""
        let id = documents.active; let page = documents.page; let cell = documents.cell
        Task {
            do {
                let text = try await documents.pageText()
                guard request == pageRequest, documents.active == id, documents.page == page else { return }
                reading = text.text; reader.load(TactileEncoding.translate(text.text).cells); reader.move(cell); loadingPage = false
                notice = "Page \(page + 1)." + (text.replacements > 0 ? " Unsupported symbols are announced." : "")
                if screen != .read { open(.read) }
                else if play { labels.stop(); reader.play() }
                else { feedback("page \(page + 1)") }
            } catch { guard request == pageRequest else { return }; loadingPage = false; continuousBook = false; fail(error.localizedDescription) }
        }
    }
    private func changeDocumentPage(_ offset: Int) { continuousBook = false; documents.bookmark(reader.index); documents.setPage(documents.page + offset); loadDocumentPage(play: false) }
    private func searchLibraryFirst() {
        if documents.matching(documentQuery).isEmpty { searchDocumentsOnline() }
        else { open(.library); feedback("library results") }
    }
    private func searchDocumentsOnline() {
        open(.online)
        documents.searchOnline(documentQuery) { if screen == .online { page = 0; feedback(documents.results.isEmpty ? "no results" : "results ready") } }
    }
    private func downloadLink(_ raw: String) {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("Use a direct HTTPS PDF link."); return }
        busy = true; feedback("downloading")
        Task { do { try await documents.downloadURL(url); open(.read) } catch { fail(error.localizedDescription) }; busy = false }
    }
    private var savedPlaces: [String] { UserDefaults.standard.stringArray(forKey: "savedPlaces") ?? [] }
    private func saveNote(_ text: String? = nil) {
        let text = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { feedback("empty"); return }
        var values = notes; values.insert(SavedNote(id: UUID(), text: text, date: Date()), at: 0)
        guard let data = try? JSONEncoder().encode(values) else { fail("Could not save"); return }
        notesData = data; feedback("saved. \(values.count) notes")
    }
    private func assist(_ task: String) {
        busy = true; suggestionSource = draft; let requestSource = draft; notice = "Preparing suggestion."
        Task {
            defer { busy = false }
            do { suggestion = try await AIClient.request(task: task, text: requestSource).text; if screen == .write && draft == requestSource { feedback("suggestion ready") } }
            catch { if screen == .write { fail(error.localizedDescription) } }
        }
    }
    private func listen() {
        if conversation.listening { conversation.stop(); feedback("stopped") }
        else {
            pending?.cancel(); reader.stop(); speaker.stop(); busy = true
            Task { await conversation.start(); busy = false; if let error = conversation.error { fail(error) } }
        }
    }
    private func stopScan() { scanID = UUID(); room.stop(); reader.stop() }

}

/// Optional companion entry; never required for Braille writing or tactile navigation.
private struct CompanionEntry: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var value: String
    let save: (String) -> Void
    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.headline)
            TextField("Text", text: $value, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("companionInput")
            PrimaryButton(title: "Save", symbol: "checkmark") { save(value); dismiss() }
            Button("Cancel") { dismiss() }.frame(minHeight: 48)
            Spacer()
        }.padding(24).background(Theme.paper)
    }
}
