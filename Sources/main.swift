import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

// Presenter Notes
// A see-through, click-through overlay that shows large-print speaker notes
// on top of a slideshow. The window is excluded from screen sharing and
// recording, so only the presenter sees it.

// MARK: - Settings

@propertyWrapper
struct Stored<T> {
    let key: String
    let fallback: T
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? fallback }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum Settings {
    @Stored(key: "fontSize", fallback: 120.0) static var fontSize: Double
    @Stored(key: "colourIndex", fallback: 0) static var colourIndex: Int
    @Stored(key: "layoutIndex", fallback: 0) static var layoutIndex: Int
    @Stored(key: "screenIndex", fallback: 0) static var screenIndex: Int
    @Stored(key: "pageIndex", fallback: 0) static var pageIndex: Int
    @Stored(key: "notesPath", fallback: "") static var notesPath: String
    @Stored(key: "followSlides", fallback: true) static var followSlides: Bool
    @Stored(key: "mouseControl", fallback: true) static var mouseControl: Bool
}

let textColours: [(name: String, colour: NSColor)] = [
    ("White", .white),
    ("Yellow", NSColor(red: 1.0, green: 0.92, blue: 0.2, alpha: 1)),
    ("Green", NSColor(red: 0.45, green: 1.0, blue: 0.45, alpha: 1)),
    ("Cyan", NSColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1)),
]

let layoutNames = ["Full screen", "Top half", "Bottom half"]

// MARK: - Log

/// A short log of what the app saw and did, for working out why something did not happen.
/// It holds slide and deck IDs, never the text of notes or full web addresses.
enum Log {
    static var url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PresenterNotes.log")
    private static var lastWritten: [String: Date] = [:]
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ line: String) {
        let data = Data("\(stamp.string(from: Date()))  \(line)\n".utf8)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        if size == 0 || size > 300_000 {
            try? data.write(to: url) // start again rather than grow without limit
        } else if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    /// Writes at most once per `seconds` for each key, so repeated events do not flood the log.
    static func throttled(_ key: String, every seconds: TimeInterval, _ line: @autoclosure () -> String) {
        if let last = lastWritten[key], Date().timeIntervalSince(last) < seconds { return }
        lastWritten[key] = Date()
        write(line())
    }
}

// MARK: - Notes file

final class NotesStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("PresenterNotes/notes.txt")

    static let sample = """
    Presenter Notes is running.

    Press Ctrl+Opt+T to check that screen sharing cannot see this.

    Press Ctrl+Opt+H for the list of shortcuts.
    ---
    This is the note for slide 2.

    Press Ctrl+Opt+Right for the next note and Ctrl+Opt+Left to go back.
    ---
    Press Ctrl+Opt+E to open the notes file and write your own.

    Put a line with three dashes between slides. Save the file and the notes update here straight away.
    ---
    Ctrl+Opt+N hides and shows your notes.
    """

    struct Page {
        var text: String
        /// The Google Slides ID of the slide this note belongs to, from a `slide:` line.
        var slideID: String?
    }

    var url: URL
    private(set) var pages: [Page] = [Page(text: "")]
    /// The Google Slides deck this file belongs to, from a `deck:` line at the top.
    private(set) var deckID: String?
    private var lastModified: Date?

    init() {
        if Settings.notesPath.isEmpty {
            url = NotesStore.defaultURL
            createSampleIfMissing()
        } else {
            url = URL(fileURLWithPath: Settings.notesPath)
        }
        load()
    }

    private func createSampleIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NotesStore.sample.write(to: url, atomically: true, encoding: .utf8)
    }

    func use(_ newURL: URL, remember: Bool = true) {
        url = newURL
        if remember { Settings.notesPath = newURL.path }
        load()
    }

    /// Looks in the notes folders for a file whose `deck:` line names this Google Slides deck.
    func file(forDeck deck: String) -> URL? {
        let folders = Set([url.deletingLastPathComponent(), NotesStore.defaultURL.deletingLastPathComponent()])
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension.lowercased() == "txt" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                if NotesStore.parse(text).deckID == deck { return file }
            }
        }
        return nil
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func load() {
        lastModified = modificationDate()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            pages = [Page(text: "Could not read the notes file at\n\(url.path)\n\nPress Ctrl+Opt+O to choose a notes file.")]
            deckID = nil
            return
        }
        (deckID, pages) = NotesStore.parse(text)
    }

    /// Returns true when the file changed on disk and was reloaded.
    func reloadIfChanged() -> Bool {
        guard modificationDate() != lastModified else { return false }
        load()
        return true
    }

    /// One page per slide. A line holding only three or more dashes starts the next page.
    /// A page may start with `slide: <ID or link to the slide>`, which ties it to that Google Slides slide.
    /// The file may start with `deck: <ID or link to the deck>`.
    static func parse(_ text: String) -> (deckID: String?, pages: [Page]) {
        var deckID: String?
        var pages: [Page] = []
        var current: [String] = []

        func closePage() {
            var slideID: String?
            var lines = current
            // Header lines sit above the note text: `deck:` (first page only) and `slide:`.
            while let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                if pages.isEmpty, deckID == nil, let value = headerValue(line, "deck") {
                    deckID = NotesStore.deckID(from: value)
                } else if slideID == nil, let value = headerValue(line, "slide") {
                    slideID = NotesStore.slideID(from: value)
                } else {
                    break
                }
                lines.removeSubrange(...index)
            }
            pages.append(Page(text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                              slideID: slideID))
            current = []
        }

        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "-" }) { closePage() } else { current.append(line) }
        }
        closePage()
        if pages.count > 1, let last = pages.last, last.text.isEmpty, last.slideID == nil { pages.removeLast() }
        return (deckID, pages)
    }

    private static func headerValue(_ line: String, _ name: String) -> String? {
        guard line.lowercased().hasPrefix(name + ":") else { return nil }
        return String(line.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    private static func firstMatch(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    /// Accepts a bare ID (`g2f1b_0_5`), `id.g2f1b_0_5`, or a link holding `slide=id.g2f1b_0_5`.
    /// Anything after the first space is a label for the reader and is ignored.
    static func slideID(from value: String) -> String? {
        // An address can hold the ID twice: `?slide=id.A#slide=id.B`. The part after # is the slide showing now.
        if let id = firstMatch(#".*slide=id\.([A-Za-z0-9_:\-]+)"#, in: value) { return id }
        guard var token = value.split(separator: " ").first.map(String.init), !token.contains("/") else { return nil }
        if token.hasPrefix("id.") { token.removeFirst(3) }
        return token.isEmpty ? nil : token
    }

    /// Accepts a bare deck ID or a link holding `/presentation/d/<ID>`.
    static func deckID(from value: String) -> String? {
        if let id = firstMatch(#"/presentation/d/([A-Za-z0-9_\-]+)"#, in: value) { return id }
        guard !value.contains("/"), let token = value.split(separator: " ").first.map(String.init) else { return nil }
        return token.isEmpty ? nil : token
    }
}

// MARK: - Following Google Slides in the browser

/// Asks the frontmost browser which Google Slides slide is showing. Google Slides keeps the
/// current slide in the page address as `slide=id.<ID>`, so no access to the page itself is needed.
final class SlideFollower {
    struct Position: Equatable {
        let deckID: String
        let slideID: String?
    }

    /// Bundle ID to (name, AppleScript word for a window's visible tab).
    static let browsers: [String: (name: String, tab: String)] = [
        "com.google.Chrome": ("Google Chrome", "active tab"),
        "com.brave.Browser": ("Brave", "active tab"),
        "com.microsoft.edgemac": ("Microsoft Edge", "active tab"),
        "com.apple.Safari": ("Safari", "current tab"),
    ]

    var onPosition: ((Position) -> Void)?
    var onDenied: ((String) -> Void)?
    private let queue = DispatchQueue(label: "presenter-notes.slide-follower")
    private var scripts: [String: NSAppleScript] = [:] // touched only on `queue`
    private var busy = false
    private var last: Position?
    private var denied: Set<String> = []

    static func source(bundleID: String, tab: String) -> String {
        """
        with timeout of 2 seconds
            tell application id "\(bundleID)"
                set found to ""
                repeat with w in windows
                    try
                        set u to URL of \(tab) of w
                        if u contains "docs.google.com/presentation" then set found to found & u & linefeed
                    end try
                end repeat
                return found
            end tell
        end timeout
        """
    }

    /// True when the last poll found Google Slides showing in a window of the front browser.
    private(set) var slidesInFront = false
    /// True when the browser address is Google Slides' own slideshow page (`/present`).
    private(set) var slideshowAddress = false
    private var lastCode: Int?

    /// False once the user has refused to let Presenter Notes ask this browser.
    func mayAsk(_ bundleID: String) -> Bool { !denied.contains(bundleID) }

    /// Makes the next poll report the position again, even if it has not changed.
    func forget() { last = nil }

    /// Called when a browser has not answered for several seconds. macOS is almost always
    /// showing its "allow Presenter Notes to control this browser" prompt at that point.
    var onWaiting: ((String) -> Void)?
    private var pollStarted: Date?
    private var waitingReported = false
    private var lastTarget: String?
    private var lastCount = -1
    /// The browser that last showed Google Slides. Asked even when another app is in front,
    /// so the notes keep following while you click in a meeting window.
    private var slidesBrowser: String?

    /// Call on the main thread, a few times a second.
    func poll() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var target: String?
        if let front, SlideFollower.browsers[front] != nil {
            target = front
        } else {
            slidesInFront = false
            if let remembered = slidesBrowser,
               !NSRunningApplication.runningApplications(withBundleIdentifier: remembered).isEmpty { target = remembered }
        }
        if target != lastTarget {
            lastTarget = target
            Log.write("asking: \(target.flatMap { SlideFollower.browsers[$0]?.name } ?? "no browser (front app is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"))")")
        }
        guard let bundleID = target, let browser = SlideFollower.browsers[bundleID] else { return }
        if busy {
            if let started = pollStarted, Date().timeIntervalSince(started) > 4, !waitingReported {
                waitingReported = true
                Log.write("\(browser.name) has not answered for 4 seconds. macOS is probably showing a permission prompt")
                onWaiting?(browser.name)
            }
            return
        }
        guard !denied.contains(bundleID) else { return }
        busy = true
        pollStarted = Date()
        let isFront = (bundleID == front)
        queue.async { [self] in
            let script = scripts[bundleID]
                ?? NSAppleScript(source: SlideFollower.source(bundleID: bundleID, tab: browser.tab))!
            scripts[bundleID] = script
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            let code = error?[NSAppleScript.errorNumber] as? Int
            // One line per browser window whose visible tab is Google Slides.
            let addresses = (result.stringValue ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty }
            DispatchQueue.main.async { [self] in
                busy = false
                pollStarted = nil
                if waitingReported { Log.write("\(browser.name) answered after the wait") }
                waitingReported = false
                if code != lastCode || lastCount == -1 {
                    lastCode = code
                    Log.write("\(browser.name): \(code.map { "script error \($0)" } ?? "answering")")
                }
                if code == -1743 { // the user has not allowed Presenter Notes to ask this browser
                    denied.insert(bundleID)
                    slidesInFront = false
                    onDenied?(browser.name)
                } else if code == nil {
                    let count = addresses.filter { $0.contains("/presentation/d/") }.count
                    if count != lastCount {
                        lastCount = count
                        Log.write("\(browser.name) windows showing Google Slides: \(count)")
                    }
                    if count > 0 { slidesBrowser = bundleID }
                    if isFront { slidesInFront = count > 0 }
                    ingest(addresses: addresses)
                }
            }
        }
    }

    /// Picks the Google Slides address that names a slide, and reports it if it changed.
    func ingest(addresses: [String]) {
        let decks = addresses.compactMap { address -> Position? in
            guard let deck = NotesStore.deckID(from: address), address.contains("/presentation/d/") else { return nil }
            let slide = address.contains("slide=id.") ? NotesStore.slideID(from: address) : nil
            return Position(deckID: deck, slideID: slide)
        }
        // `/present` alone: the word also begins `/presentation/`, which every Slides address contains.
        let slideshowPage = addresses.contains { $0.contains("/present?") || $0.contains("/present#") || $0.hasSuffix("/present") }
        if slideshowPage != slideshowAddress {
            slideshowAddress = slideshowPage
            Log.write("address is the slideshow page: \(slideshowPage)")
        }
        guard let position = decks.first(where: { $0.slideID != nil }) ?? decks.first, position != last else { return }
        last = position
        Log.write("slide seen: deck \(position.deckID.prefix(8)) slide \(position.slideID ?? "none")")
        onPosition?(position)
    }
}

// MARK: - Global hotkeys (Carbon; needs no accessibility permission)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            HotKeyCenter.shared.handlers[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> UInt32? {
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x504E_6F74), id: id) // 'PNot'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        handlers[id] = action
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    /// Sends the event macOS sends when a registered shortcut is pressed. Used by `--snapshot` to test the wiring.
    func simulatePress(id: UInt32) {
        var event: EventRef?
        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
        var hotKeyID = EventHotKeyID(signature: OSType(0x504E_6F74), id: id)
        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          MemoryLayout<EventHotKeyID>.size, &hotKeyID)
        SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}

// MARK: - Mouse control

/// Watches the mouse so the wheel scrolls the notes and a right click goes back a slide.
/// macOS only lets an app intercept the mouse once it has Accessibility permission.
final class MouseControl {
    static let shared = MouseControl()
    /// Whether a mouse event at this point on screen should be acted on right now.
    /// The second value is true for the wheel and false for a click.
    var isActive: (CGPoint, Bool) -> Bool = { _, _ in false }
    /// Scroll distance. `lines` is true for a notched mouse wheel, false for trackpad points.
    var onScroll: (_ amount: Double, _ lines: Bool) -> Void = { _, _ in }
    /// The slideshow was told to move: +1 for the next slide, -1 for the previous one.
    var onStep: (_ delta: Int) -> Void = { _ in }
    /// Presses a key in the front app. Replaced in the self-test so no real key is sent.
    var sendKey: (CGKeyCode) -> Void = { key in
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }
    private var tap: CFMachPort?
    /// How many mouse events macOS has handed to the app since it started watching.
    private(set) var eventsSeen = 0
    private var swallowLeftUp = false
    private var swallowRightUp = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = MouseControl.shared.tap { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            MouseControl.shared.eventsSeen += 1
            if MouseControl.shared.eventsSeen == 1 { Log.write("mouse watching works: first mouse event received") }
            return MouseControl.shared.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        tap = nil
    }

    /// Returns true when the event should be kept from the app under the mouse.
    /// A click on the slideshow is kept and replaced by an arrow key, so the app knows for
    /// certain that the slide moved and can turn the note with it.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .scrollWheel:
            guard isActive(event.location, true) else { return false }
            if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 {
                onScroll(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), false)
            } else {
                onScroll(Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)), true)
            }
            return true
        case .leftMouseDown:
            // Ctrl+click is how macOS spells a right click. Leave modified clicks alone.
            guard event.flags.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty,
                  isActive(event.location, false) else { return false }
            swallowLeftUp = true
            sendKey(CGKeyCode(kVK_RightArrow))
            onStep(1)
            return true
        case .leftMouseUp:
            guard swallowLeftUp else { return false }
            swallowLeftUp = false
            return true
        case .rightMouseDown:
            guard isActive(event.location, false) else { return false }
            swallowRightUp = true
            sendKey(CGKeyCode(kVK_LeftArrow))
            onStep(-1)
            return true
        case .rightMouseUp:
            guard swallowRightUp else { return false }
            swallowRightUp = false
            return true
        default:
            return false
        }
    }
}

// MARK: - Overlay view

final class OverlayView: NSView {
    var text = ""
    var pageLabel = ""
    /// The shortcut list. Shown in place of the note, at reading size, and scrolls like a note.
    var helpText: String?
    /// A full-overlay message, such as the result of the screen sharing check.
    var message: (text: String, colour: NSColor)?
    /// A solid square drawn in the middle while the screen sharing check runs.
    var testPatch: NSColor?
    var fontSize: CGFloat = 84
    var backdropOpacity: CGFloat = 0.5
    var textOpacity: CGFloat = 1
    var textColour: NSColor = .white
    var scrollOffset: CGFloat = 0
    private var maxScroll: CGFloat = 0
    private var hud: String?
    private var hudTimer: Timer?
    private let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    override var isFlipped: Bool { true }

    func flash(_ message: String) {
        hud = message
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.hud = nil
            self?.needsDisplay = true
        }
        needsDisplay = true
    }

    func scroll(pages: CGFloat) { scroll(points: pages * bounds.height * 0.6) }

    func scroll(points: CGFloat) {
        scrollOffset = min(max(scrollOffset + points, 0), maxScroll)
        needsDisplay = true
    }

    /// Text is drawn twice: a thick black outline first, then the solid letters on top.
    /// One pass with an outline leaves stray lines inside the letters of the system font.
    private func styled(_ string: String, size: CGFloat, colour: NSColor, opacity: CGFloat, outline: Bool,
                        alignment: NSTextAlignment = .left, tabStop: CGFloat? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = size * 0.1
        paragraph.paragraphSpacing = size * 0.3
        paragraph.lineBreakMode = .byWordWrapping
        if let tabStop {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tabStop)]
            paragraph.headIndent = tabStop
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .paragraphStyle: paragraph,
        ]
        if outline {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(opacity)
            shadow.shadowBlurRadius = size * 0.1
            shadow.shadowOffset = .zero
            attributes[.strokeColor] = NSColor.black.withAlphaComponent(opacity)
            attributes[.strokeWidth] = 9.0 // percent of the font size; positive means outline only
            attributes[.shadow] = shadow
        } else {
            attributes[.foregroundColor] = colour.withAlphaComponent(opacity)
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    private func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: drawOptions).height)
    }

    private func textHeight(_ string: String, width: CGFloat, size: CGFloat, tabStop: CGFloat? = nil) -> CGFloat {
        height(of: styled(string, size: size, colour: .white, opacity: 1, outline: false, tabStop: tabStop), width: width)
    }

    private func drawText(_ string: String, in rect: NSRect, size: CGFloat, colour: NSColor, opacity: CGFloat,
                          alignment: NSTextAlignment = .left, tabStop: CGFloat? = nil) {
        NSGraphicsContext.current?.cgContext.setLineJoin(.round)
        for outline in [true, false] {
            styled(string, size: size, colour: colour, opacity: opacity, outline: outline,
                   alignment: alignment, tabStop: tabStop).draw(with: rect, options: drawOptions)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let margin = max(24, b.width * 0.04)
        let width = b.width - 2 * margin

        if let message {
            NSColor.black.withAlphaComponent(max(backdropOpacity, 0.85)).setFill()
            b.fill()
            var size: CGFloat = 96
            while size > 16, textHeight(message.text, width: width, size: size) > b.height - 2 * margin { size -= 2 }
            let bodyHeight = textHeight(message.text, width: width, size: size)
            drawText(message.text, in: NSRect(x: margin, y: (b.height - bodyHeight) / 2, width: width, height: bodyHeight),
                     size: size, colour: message.colour, opacity: 1, alignment: .center)
        } else {
            // The shortcut list uses the same scrolling page as a note, on a darker background.
            let showingHelp = helpText != nil
            let body = helpText ?? text
            let size = showingHelp ? max(36, min(fontSize * 0.75, 72)) : fontSize
            let colour = showingHelp ? NSColor.white : textColour
            let opacity = showingHelp ? 1 : textOpacity
            let tabStop: CGFloat? = showingHelp ? size * 9.5 : nil
            NSColor.black.withAlphaComponent(showingHelp ? max(backdropOpacity, 0.85) : backdropOpacity).setFill()
            b.fill()

            let footerSize = max(40, min(fontSize * 0.6, 84))
            let footerHeight = footerSize * 1.5
            let textArea = NSRect(x: margin, y: margin, width: width, height: b.height - 2 * margin - footerHeight)
            let bodyHeight = textHeight(body, width: width, size: size, tabStop: tabStop)
            maxScroll = max(0, bodyHeight - textArea.height)
            scrollOffset = min(max(scrollOffset, 0), maxScroll)

            NSGraphicsContext.saveGraphicsState()
            // Cut scrolled text off above the footer so a half-shown line never runs into it.
            NSBezierPath(rect: NSRect(x: 0, y: textArea.minY - margin * 0.5, width: b.width,
                                      height: textArea.height + margin * 0.5)).addClip()
            drawText(body, in: NSRect(x: textArea.minX, y: textArea.minY - scrollOffset, width: width, height: bodyHeight + size),
                     size: size, colour: colour, opacity: opacity, tabStop: tabStop)
            NSGraphicsContext.restoreGraphicsState()

            let footerRect = NSRect(x: margin, y: b.height - margin * 0.6 - footerHeight, width: width, height: footerHeight)
            drawText(showingHelp ? "Help" : pageLabel, in: footerRect, size: footerSize, colour: colour, opacity: opacity,
                     alignment: .right)
            if maxScroll > 0 {
                let hint: String
                if scrollOffset <= 0 { hint = "More: Ctrl+Opt+Down" }
                else if scrollOffset >= maxScroll { hint = "End. Ctrl+Opt+Up goes back" }
                else { hint = "More above and below" }
                drawText(hint, in: footerRect, size: footerSize, colour: colour, opacity: opacity)
            }
        }

        if let testPatch {
            testPatch.setFill()
            NSRect(x: b.midX - 120, y: b.midY - 120, width: 240, height: 240).fill()
        }

        if let hud {
            let size = max(40, min(fontSize * 0.6, 72))
            let label = styled(hud, size: size, colour: .white, opacity: 1, outline: false, alignment: .center)
            let labelWidth = min(width, label.size().width + 8)
            let labelHeight = height(of: label, width: labelWidth)
            let box = NSRect(x: (b.width - labelWidth) / 2 - size * 0.6, y: (b.height - labelHeight) / 2 - size * 0.4,
                             width: labelWidth + size * 1.2, height: labelHeight + size * 0.8)
            let outline = NSBezierPath(roundedRect: box, xRadius: size * 0.4, yRadius: size * 0.4)
            NSColor(white: 0.22, alpha: 1).setFill()
            outline.fill()
            NSColor.white.setStroke()
            outline.lineWidth = 4
            outline.stroke()
            label.draw(with: NSRect(x: (b.width - labelWidth) / 2, y: (b.height - labelHeight) / 2,
                                    width: labelWidth, height: labelHeight), options: drawOptions)
        }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

struct Command {
    let title: String
    let keys: String
    let keyCode: Int
    var modifiers: Int = controlKey | optionKey
    /// Stays registered while the notes are hidden.
    var always: Bool = false
    let run: () -> Void
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NotesStore()
    private let view = OverlayView()
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var commands: [Command] = []
    private var contextualHotKeys: [UInt32] = []
    private var visible = !CommandLine.arguments.contains("--hidden")
    private var showingHelp = false
    private var message: (text: String, colour: NSColor)?
    private var blockedShortcuts: [String] = []
    private let follower = SlideFollower()
    private var lastPosition: SlideFollower.Position?
    /// True when the slide on screen has no note linked to it.
    private var noNoteForSlide = false
    private var pageIndex = Settings.pageIndex
    /// `--capturable` lets screen sharing see the notes. Used to rehearse and to test the hiding.
    private let capturable = CommandLine.arguments.contains("--capturable")

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // clicks go through to the slides
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver // above a full-screen slideshow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = capturable ? .readOnly : .none // .none keeps it out of screen sharing
        panel.contentView = view

        buildCommands()
        buildMenu()
        for command in commands where command.always {
            if register(command) == nil { blockedShortcuts.append(command.keys) }
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.store.reloadIfChanged() else { return }
            if let position = self.lastPosition, Settings.followSlides, self.stepsSinceSlideSeen == 0 { self.show(position) }
            self.refresh()
            self.view.flash("Notes reloaded")
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            Log.url = URL(fileURLWithPath: CommandLine.arguments[flag + 1]).appendingPathComponent("test.log")
        }
        Log.write("started. notes \(store.url.lastPathComponent), \(store.pages.count) notes, follow \(Settings.followSlides), mouse setting \(Settings.mouseControl), accessibility \(AXIsProcessTrusted())")
        wireMouse()
        follower.onPosition = { [weak self] position in self?.slideSeen(position) }
        follower.onWaiting = { [weak self] browser in
            guard let self else { return }
            self.message = ("macOS is asking whether Presenter Notes may control \(browser).\n\nFind that prompt and choose Allow. Your notes cannot follow the slides until you do.\n\nPress Ctrl+Opt+N to hide your notes if they are in the way.", AppDelegate.warningColour)
            self.refresh()
        }
        follower.onDenied = { [weak self] browser in
            guard let self else { return }
            self.message = ("Presenter Notes is not allowed to ask \(browser) which slide is showing, so notes will not follow your slides.\n\nOpen System Settings, then Privacy & Security, then Automation. Under Presenter Notes, turn on \(browser).\n\nPress Ctrl+Opt+N to hide your notes while you do this.", .white)
            self.refresh()
        }
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, Settings.followSlides else { return }
            self.follower.poll()
        }

        applyVisibility()
        refresh()

        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            writeSnapshots(to: CommandLine.arguments[flag + 1])
        } else {
            checkSharing(announce: false)
        }
    }

    // MARK: Commands

    private func buildCommands() {
        commands = [
            Command(title: "Show or hide notes", keys: "Ctrl+Opt+N", keyCode: kVK_ANSI_N, always: true) { [unowned self] in
                visible.toggle(); showingHelp = false; applyVisibility(); refresh()
            },
            Command(title: "Next note", keys: "Ctrl+Opt+Right", keyCode: kVK_RightArrow) { [unowned self] in turn(by: 1) },
            Command(title: "Previous note", keys: "Ctrl+Opt+Left", keyCode: kVK_LeftArrow) { [unowned self] in turn(by: -1) },
            Command(title: "Back to the first note", keys: "Ctrl+Opt+0", keyCode: kVK_ANSI_0) { [unowned self] in
                turn(by: -pageIndex); view.flash("First note")
            },
            Command(title: "Scroll down", keys: "Ctrl+Opt+Down", keyCode: kVK_DownArrow) { [unowned self] in view.scroll(pages: 1) },
            Command(title: "Scroll up", keys: "Ctrl+Opt+Up", keyCode: kVK_UpArrow) { [unowned self] in view.scroll(pages: -1) },
            Command(title: "Bigger text", keys: "Ctrl+Opt+Plus", keyCode: kVK_ANSI_Equal) { [unowned self] in resizeText(by: 8) },
            Command(title: "Smaller text", keys: "Ctrl+Opt+Minus", keyCode: kVK_ANSI_Minus) { [unowned self] in resizeText(by: -8) },
            Command(title: "Change text colour", keys: "Ctrl+Opt+C", keyCode: kVK_ANSI_C) { [unowned self] in
                Settings.colourIndex = (Settings.colourIndex + 1) % textColours.count
                refresh(); view.flash(textColours[Settings.colourIndex].name)
            },
            Command(title: "Change layout", keys: "Ctrl+Opt+L", keyCode: kVK_ANSI_L) { [unowned self] in
                Settings.layoutIndex = (Settings.layoutIndex + 1) % layoutNames.count
                refresh(); view.flash(layoutNames[Settings.layoutIndex])
            },
            Command(title: "Move to next display", keys: "Ctrl+Opt+M", keyCode: kVK_ANSI_M) { [unowned self] in
                let count = NSScreen.screens.count
                Settings.screenIndex = (Settings.screenIndex + 1) % max(count, 1)
                refresh()
                view.flash(count > 1 ? "Display \(Settings.screenIndex + 1) of \(count)" : "Only one display")
            },
            Command(title: "Edit the notes file", keys: "Ctrl+Opt+E", keyCode: kVK_ANSI_E) { [unowned self] in
                NSWorkspace.shared.open(store.url)
            },
            Command(title: "Open another notes file", keys: "Ctrl+Opt+O", keyCode: kVK_ANSI_O) { [unowned self] in chooseFile() },
            Command(title: "Follow slides on or off", keys: "Ctrl+Opt+F", keyCode: kVK_ANSI_F) { [unowned self] in
                Settings.followSlides.toggle()
                follower.forget()
                if !Settings.followSlides { noNoteForSlide = false }
                refresh()
                view.flash(Settings.followSlides ? "Following slides" : "Not following slides")
            },
            Command(title: "Mouse control on or off", keys: "Ctrl+Opt+K", keyCode: kVK_ANSI_K) { [unowned self] in
                setMouseControl(!Settings.mouseControl, announce: true)
            },
            Command(title: "Show status", keys: "Ctrl+Opt+I", keyCode: kVK_ANSI_I) { [unowned self] in showStatus() },
            Command(title: "Check notes are hidden", keys: "Ctrl+Opt+T", keyCode: kVK_ANSI_T) { [unowned self] in
                checkSharing(announce: true)
            },
            Command(title: "Show or hide help", keys: "Ctrl+Opt+H", keyCode: kVK_ANSI_H) { [unowned self] in
                showingHelp.toggle(); view.scrollOffset = 0; refresh()
            },
            Command(title: "Quit Presenter Notes", keys: "Ctrl+Opt+Shift+Q", keyCode: kVK_ANSI_Q,
                    modifiers: controlKey | optionKey | shiftKey, always: true) {
                NSApp.terminate(nil)
            },
        ]
    }

    private func register(_ command: Command) -> UInt32? {
        HotKeyCenter.shared.register(keyCode: command.keyCode, modifiers: command.modifiers) { [unowned self] in
            perform(command)
        }
    }

    /// Runs a command. Any key closes a message or the help screen first.
    private func perform(_ command: Command) {
        let turnsPage = [kVK_RightArrow, kVK_LeftArrow, kVK_ANSI_0].contains(command.keyCode)
        let hadMessage = message != nil
        let hadHelp = showingHelp
        message = nil
        // Help stays up while you scroll it or change the text size. Turning the page closes it.
        if turnsPage { showingHelp = false }
        refresh()
        // The key that closes a message or the help should not also turn the page.
        if turnsPage, hadMessage || hadHelp {
            view.scrollOffset = 0
            return
        }
        command.run()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Notes"
        let menu = NSMenu()
        for command in commands {
            if command.keyCode == kVK_ANSI_Q { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem(title: "\(command.title)    \(command.keys)") { [unowned self] in perform(command) })
        }
        statusItem.menu = menu
    }

    // MARK: Actions

    // MARK: Mouse

    static let mousePermissionText = "To use the mouse, Presenter Notes needs permission.\n\nOpen System Settings, then Privacy & Security, then Accessibility. Turn on Presenter Notes.\n\nPress Ctrl+Opt+N to hide your notes while you do this. Then press Ctrl+Opt+K to switch the mouse on."

    private func setMouseControl(_ on: Bool, announce: Bool) {
        guard on else {
            Settings.mouseControl = false
            MouseControl.shared.stop()
            Log.write("mouse control switched off")
            if announce {
                // A full message, not a brief flash: on and off share one shortcut and are easy to mix up.
                message = ("Mouse control is OFF.\n\nPress Ctrl+Opt+K to switch it on again.", AppDelegate.warningColour)
                refresh()
            }
            return
        }
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: announce] as CFDictionary)
        Log.write("mouse control requested: accessibility permission \(trusted)")
        guard trusted, MouseControl.shared.start() else {
            Log.write("mouse control could not start")
            Settings.mouseControl = false
            if announce {
                message = (AppDelegate.mousePermissionText, .white)
                refresh()
            }
            return
        }
        Settings.mouseControl = true
        Log.write("mouse control is on")
        if announce {
            message = ("Mouse control is ON.\n\nIn a full-screen slideshow: left click goes forward, right click goes back, the wheel scrolls your notes.", AppDelegate.okColour)
            refresh()
        }
    }

    /// The mouse acts on a slideshow only: notes showing, Google Slides in a full-screen browser
    /// window, and the pointer over that window. Everywhere else the mouse behaves as normal.
    /// Returns nil when the mouse applies, or the reason it does not.
    private func mouseBlockedReason(at point: CGPoint?, wheel: Bool = false) -> String? {
        guard visible else { return "notes are hidden" }
        guard message == nil else { return "a message is on screen" }
        guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier,
              let browser = SlideFollower.browsers[bundleID] else {
            return "\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "another app") is in front, not a browser"
        }
        if Settings.followSlides, follower.mayAsk(bundleID), !follower.slidesInFront {
            return "\(browser.name) is not showing Google Slides"
        }
        guard follower.slideshowAddress || isFullScreen(front) else {
            return "the slideshow is not running full screen"
        }
        guard let point else { return nil }
        // The pointer position counts from the top left of the main screen. Window frames count from the bottom left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let overNotes = panel.frame.contains(CGPoint(x: point.x, y: mainHeight - point.y))
        let top = topWindow(at: point)
        return AppDelegate.pointerBlockedReason(overNotes: overNotes, wheel: wheel,
                                                topIsBrowser: top.map { $0.pid == front.processIdentifier },
                                                topFloats: (top?.layer ?? 0) > 0)
    }

    /// Decides whether the pointer is somewhere the mouse should drive the slideshow.
    /// `topIsBrowser` is nil when no window is under the pointer.
    /// With slides on one screen and notes on another, pointing at either one works.
    static func pointerBlockedReason(overNotes: Bool, wheel: Bool, topIsBrowser: Bool?, topFloats: Bool) -> String? {
        if overNotes && wheel { return nil }       // the wheel over the notes always scrolls the notes
        guard let topIsBrowser else { return overNotes ? nil : "the pointer is not over the slides or the notes" }
        if topIsBrowser { return nil }             // over the slideshow itself
        if !overNotes { return "the pointer is over another app's window" }
        // Over the notes, with another app's window underneath. Floating windows such as
        // meeting controls keep their clicks. An ordinary window under the notes does not.
        return topFloats ? "the pointer is over another app's floating window" : nil
    }

    private var fullScreenCheck: (time: Date, pid: pid_t, value: Bool)?

    /// Asks macOS whether the app's front window is full screen. A Google Slides slideshow is.
    private func isFullScreen(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if let check = fullScreenCheck, check.pid == pid, Date().timeIntervalSince(check.time) < 0.5 { return check.value }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var window: CFTypeRef?
        var flag: CFTypeRef?
        var value = false
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
           AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &flag) == .success {
            value = (flag as? Bool) ?? false
        }
        if value != fullScreenCheck?.value { Log.write("\(app.localizedName ?? "browser") front window full screen: \(value)") }
        fullScreenCheck = (Date(), pid, value)
        return value
    }

    /// The topmost window under the pointer, ignoring the notes overlay itself: its app and
    /// whether it sits above ordinary windows (layer over 0, as meeting controls and the menu bar do).
    private func topWindow(at point: CGPoint) -> (pid: pid_t, layer: Int)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for window in windows { // front to back
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.contains(point),
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  isOrdinaryApp(pid) else { continue }
            return (pid, window[kCGWindowLayer as String] as? Int ?? 0)
        }
        return nil
    }

    private var ordinaryApps: [pid_t: Bool] = [:]

    /// True for apps that appear in the Dock. macOS itself keeps invisible full-screen windows
    /// above everything (Notification Center is one), and those must not count as "another app".
    private func isOrdinaryApp(_ pid: pid_t) -> Bool {
        if let known = ordinaryApps[pid] { return known }
        let ordinary = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
        ordinaryApps[pid] = ordinary
        return ordinary
    }

    // MARK: Keeping slide and note in step

    /// True once the browser's address has been seen to change when the slide changes during this run.
    /// Then the address is the truth, and a step that turns out to be an animation is undone.
    private var addressTracksSlides = false
    /// Steps taken since the browser last reported a new slide.
    private var stepsSinceSlideSeen = 0
    private var stepCheck = 0

    /// A click told the slideshow to move. Turn the note with it straight away.
    private func slideStepped(by delta: Int) {
        guard !showingHelp else { return }
        Log.write("mouse \(delta > 0 ? "left click: next slide" : "right click: previous slide"), note \(pageIndex + 1) of \(store.pages.count) before")
        stepsSinceSlideSeen += delta
        turn(by: delta)
        guard addressTracksSlides, let position = lastPosition else { return }
        // The browser normally reports the new slide within a second. If it reports nothing,
        // the click played an animation or hit the end of the deck, so go back to the slide's note.
        stepCheck += 1
        let check = stepCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, check == self.stepCheck, self.lastPosition == position, self.stepsSinceSlideSeen != 0 else { return }
            Log.write("slide did not change after the click, returning to its note")
            self.stepsSinceSlideSeen = 0
            self.show(position)
        }
    }

    /// The browser reported which slide is showing.
    private func slideSeen(_ position: SlideFollower.Position) {
        if let last = lastPosition, last == position {
            // The same slide reported again. If clicks have moved on since, trust the clicks.
            if stepsSinceSlideSeen != 0 { return }
        } else if lastPosition != nil, position.deckID == lastPosition?.deckID, stepsSinceSlideSeen != 0 {
            if !addressTracksSlides { Log.write("the address follows the slideshow: using it to keep notes in step") }
            addressTracksSlides = true
        }
        stepsSinceSlideSeen = 0
        show(position)
    }

    private var mouseApplies: (CGPoint, Bool) -> Bool {
        { [unowned self] point, wheel in
            let reason = mouseBlockedReason(at: point, wheel: wheel)
            if let reason { Log.throttled("mouse-blocked", every: 3, "mouse left alone: \(reason)") }
            return reason == nil
        }
    }

    private func showStatus() {
        let position = lastPosition
        var lines = ["Notes: \(store.url.deletingPathExtension().lastPathComponent), \(store.pages.count) notes"]
        if !Settings.followSlides {
            lines.append("Following slides: off")
        } else if let slide = position?.slideID {
            let linked = store.pages.contains { $0.slideID == slide }
            lines.append("Following slides: on. Slide seen: \(slide), \(linked ? "has a note" : "no note linked")")
        } else {
            lines.append("Following slides: on. No slide seen yet")
        }
        if !Settings.mouseControl {
            lines.append("Mouse control: off")
        } else if !MouseControl.shared.isRunning {
            lines.append("Mouse control: on, but not allowed by macOS")
        } else {
            message = nil // the reason below should not be "a message is on screen"
            lines.append("Mouse control: on. " + (mouseBlockedReason(at: nil).map { "Waiting: \($0)" } ?? "Ready"))
        }
        Log.write("status: " + lines.joined(separator: " | "))
        message = (lines.joined(separator: "\n\n"), .white)
        refresh()
    }

    private func wireMouse() {
        MouseControl.shared.isActive = mouseApplies
        MouseControl.shared.onScroll = { [unowned self] amount, lines in
            // A positive amount means "towards the top". A wheel notch moves a line and a bit of large text.
            view.scroll(points: -CGFloat(amount) * (lines ? CGFloat(Settings.fontSize) * 1.3 : 1.5))
            Log.throttled("mouse-scroll", every: 2, "mouse wheel scrolled the notes")
        }
        MouseControl.shared.onStep = { [unowned self] delta in slideStepped(by: delta) }
        if Settings.mouseControl { setMouseControl(true, announce: false) }
    }

    /// Shows the note linked to the slide the browser is showing.
    private func show(_ position: SlideFollower.Position) {
        lastPosition = position
        if position.deckID != store.deckID {
            if let file = store.file(forDeck: position.deckID) {
                store.use(file)
                view.flash("Notes: \(file.deletingPathExtension().lastPathComponent)")
            } else if store.deckID != nil {
                return // these notes belong to a different deck
            }
        }
        guard let slideID = position.slideID, store.pages.contains(where: { $0.slideID != nil }) else { return }
        if let index = store.pages.firstIndex(where: { $0.slideID == slideID }) {
            pageIndex = index
            noNoteForSlide = false
            Log.write("showing note \(index + 1) for slide \(slideID)")
        } else {
            noNoteForSlide = true
            Log.write("no note linked to slide \(slideID)")
        }
        view.scrollOffset = 0
        refresh()
    }

    private func turn(by delta: Int) {
        noNoteForSlide = false
        let last = store.pages.count - 1
        let target = pageIndex + delta
        if target < 0 { view.flash("First note") }
        if target > last { view.flash("Last note") }
        pageIndex = min(max(target, 0), last)
        view.scrollOffset = 0
        refresh()
    }

    private func resizeText(by delta: Double) {
        Settings.fontSize = min(max(Settings.fontSize + delta, 24), 400)
        refresh()
        view.flash("Text size \(Int(Settings.fontSize))")
    }

    private func chooseFile() {
        let wasVisible = visible
        visible = false
        applyVisibility()
        let open = NSOpenPanel()
        open.message = "Choose a notes file. Separate slides with a line of three dashes."
        open.directoryURL = store.url.deletingLastPathComponent()
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url {
            store.use(url)
            pageIndex = 0
            view.scrollOffset = 0
            noNoteForSlide = false
            follower.forget()
        }
        visible = wasVisible
        applyVisibility()
        refresh()
    }

    @objc private func screensChanged() { refresh() }

    // MARK: Screen sharing check

    static let hiddenText = "Your notes are hidden from screen sharing.\n\nA full-screen capture taken on this Mac just now did not show them."
    static let exposedText = "WARNING\n\nSharing your entire screen WILL show your notes.\n\nShare one window or one browser tab instead. Your notes are a separate window, so they stay out of it."
    static let rehearsalText = "Rehearsal mode is on, so screen sharing can see your notes.\n\nQuit and open Presenter Notes normally before you present."
    static let permissionText = "This check needs permission to capture the screen.\n\nOpen System Settings, then Privacy & Security, then Screen & System Audio Recording. Turn on Presenter Notes.\n\nPress Ctrl+Opt+N to hide your notes while you do this. Then quit with Ctrl+Opt+Shift+Q and open Presenter Notes again."
    static let warningColour = NSColor(red: 1.0, green: 0.45, blue: 0.35, alpha: 1)
    static let okColour = NSColor(red: 0.45, green: 1.0, blue: 0.45, alpha: 1)

    /// Takes two real full-screen captures with a different coloured square on the overlay each time.
    /// If the captured pixels change with the square, screen sharing can see the notes.
    /// `announce` is false for the automatic check, which stays quiet unless the notes are exposed.
    private func checkSharing(announce: Bool) {
        guard CGPreflightScreenCaptureAccess() else {
            guard announce else { return }
            CGRequestScreenCaptureAccess()
            message = (AppDelegate.permissionText, .white)
            refresh()
            return
        }
        guard visible else { return }
        Task { @MainActor in
            var outcome: (text: String, colour: NSColor)?
            do {
                let first = try await captureCentre(showing: NSColor(red: 1, green: 0, blue: 1, alpha: 1))
                let second = try await captureCentre(showing: NSColor(red: 0, green: 1, blue: 0, alpha: 1))
                let difference = zip(first, second).map { abs($0 - $1) }.reduce(0, +)
                if difference > 60 {
                    outcome = (capturable ? AppDelegate.rehearsalText : AppDelegate.exposedText, AppDelegate.warningColour)
                } else if announce {
                    outcome = (AppDelegate.hiddenText, AppDelegate.okColour)
                }
            } catch {
                if announce { outcome = ("The check could not run.\n\n\(error.localizedDescription)", .white) }
            }
            view.testPatch = nil
            if let outcome { message = outcome }
            refresh()
        }
    }

    private var currentScreen: NSScreen? {
        let screens = NSScreen.screens
        return screens.isEmpty ? nil : screens[min(Settings.screenIndex, screens.count - 1)]
    }

    /// Draws a square of the given colour on the overlay, captures the whole display the way a
    /// meeting app does, and returns the red, green and blue (0 to 255) found where the square is.
    @MainActor
    private func captureCentre(showing colour: NSColor) async throws -> [Int] {
        view.testPatch = colour
        view.needsDisplay = true
        try await Task.sleep(nanoseconds: 400_000_000)

        guard let screen = currentScreen else { throw CocoaError(.featureUnsupported) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CocoaError(.featureUnsupported)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration)

        // Centre of the overlay, in image pixels measured from the top left.
        let x = (panel.frame.midX - screen.frame.minX) * CGFloat(image.width) / screen.frame.width
        let y = (screen.frame.maxY - panel.frame.midY) * CGFloat(image.height) / screen.frame.height
        guard let sample = image.cropping(to: CGRect(x: x - 8, y: y - 8, width: 16, height: 16)) else {
            throw CocoaError(.featureUnsupported)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.featureUnsupported)
        }
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
    }

    /// `--snapshot <folder>` writes pictures of each screen to a folder and quits. Used to check the drawing.
    private func writeSnapshots(to folder: String) {
        func save(_ name: String) {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        save("notes.png")
        // Shortcuts are numbered in the order they are registered: 3 is Next note, 8 is Bigger text.
        let savedPage = pageIndex, savedSize = Settings.fontSize
        HotKeyCenter.shared.simulatePress(id: 3)
        HotKeyCenter.shared.simulatePress(id: 8)
        save("after-next-and-bigger.png")
        pageIndex = savedPage; Settings.fontSize = savedSize; refresh()
        showingHelp = true; refresh(); save("help.png"); showingHelp = false
        message = (AppDelegate.exposedText, AppDelegate.warningColour); refresh(); save("warning.png")
        message = (AppDelegate.hiddenText, AppDelegate.okColour); refresh(); save("hidden.png")
        view.flash("Text size 84"); message = nil; refresh(); save("hud.png")

        // A note longer than one screen: shortcut 6 is Scroll down, 7 is Scroll up.
        let long = URL(fileURLWithPath: folder).appendingPathComponent("long-note.txt")
        let paragraphs = (1...12).map { "Point \($0). This is a longer talking point that runs over more than one line of large text." }
        try? (paragraphs.joined(separator: "\n\n") + "\n---\nSecond slide.").write(to: long, atomically: true, encoding: .utf8)
        let notesBeforeLong = store.url
        store.use(long, remember: false); pageIndex = 0; refresh(); save("long-1-top.png")
        HotKeyCenter.shared.simulatePress(id: 6); save("long-2-down-once.png")
        for _ in 0..<20 { HotKeyCenter.shared.simulatePress(id: 6) }
        save("long-3-end.png")
        HotKeyCenter.shared.simulatePress(id: 7); save("long-4-up-once.png")
        view.scrollOffset = 0; refresh(); save("mouse-0-top.png")
        let realActive = MouseControl.shared.isActive, realSendKey = MouseControl.shared.sendKey
        var keysSent: [CGKeyCode] = []
        MouseControl.shared.isActive = { _, _ in true }
        MouseControl.shared.sendKey = { keysSent.append($0) }
        func wheel(_ units: CGScrollEventUnit, _ amount: Int32) -> Bool {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)!
            return MouseControl.shared.handle(type: .scrollWheel, event: event)
        }
        func click(_ type: CGEventType) -> Bool {
            let button: CGMouseButton = (type == .leftMouseDown) ? .left : .right
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button)!
            event.flags = [] // a made-up event otherwise copies whatever keys are held down right now
            return MouseControl.shared.handle(type: type, event: event)
        }
        var report: [String] = []
        report.append("wheel down 3 notches: kept from browser=\(wheel(.line, -3)) offset=\(Int(view.scrollOffset))")
        save("mouse-1-wheel-down.png")
        report.append("trackpad down 200 points: kept=\(wheel(.pixel, -200)) offset=\(Int(view.scrollOffset))")
        report.append("wheel up 1 notch: kept=\(wheel(.line, 1)) offset=\(Int(view.scrollOffset))")
        report.append("left click: kept=\(click(.leftMouseDown)) note=\(pageIndex + 1) keys=\(keysSent)  (124 is right arrow)")
        report.append("left button up: kept=\(click(.leftMouseUp)); a second one: kept=\(click(.leftMouseUp))")
        report.append("right click: kept=\(click(.rightMouseDown)) note=\(pageIndex + 1) keys=\(keysSent)  (123 is left arrow)")
        report.append("right button up: kept=\(click(.rightMouseUp)); a second one: kept=\(click(.rightMouseUp))")
        MouseControl.shared.isActive = { _, _ in false }
        report.append("when no slideshow is running: wheel kept=\(wheel(.line, -3)) left kept=\(click(.leftMouseDown)) right kept=\(click(.rightMouseDown)) keys=\(keysSent)")
        print(report.joined(separator: "\n"))
        print("accessibility permission: \(AXIsProcessTrusted())")
        let watching = MouseControl.shared.start()
        let seenBefore = MouseControl.shared.eventsSeen
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        print("live mouse watcher: started=\(watching), events received from a posted zero-distance scroll=\(MouseControl.shared.eventsSeen - seenBefore)")
        MouseControl.shared.stop()
        store.use(notesBeforeLong, remember: false); pageIndex = savedPage; view.scrollOffset = 0; refresh()

        // Slide following: two decks in the folder, the browser reports addresses from the first.
        let demo = URL(fileURLWithPath: folder).appendingPathComponent("demo-deck.txt")
        let other = URL(fileURLWithPath: folder).appendingPathComponent("other-deck.txt")
        try? "deck: https://docs.google.com/presentation/d/DECK-one_1/edit\n\nslide: p (Slide 1: Title)\nNote for slide one.\n---\nslide: https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.g2f_0_5\nNote for slide two.\n---\nslide: id.g3abc\nNote for slide three, linked by its slide ID."
            .write(to: demo, atomically: true, encoding: .utf8)
        try? "deck: DECK-two\n\nslide: p\nA different deck.".write(to: other, atomically: true, encoding: .utf8)
        let realNotes = store.url, savedPath = Settings.notesPath
        store.use(other, remember: false)
        follower.ingest(addresses: ["https://mail.example.com/", "https://docs.google.com/presentation/d/DECK-one_1/edit?slide=id.p#slide=id.g3abc", ""])
        save("follow-slide-3.png")
        follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.g2f_0_5"])
        save("follow-slide-2.png")
        follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.gNEW"])
        save("follow-unlinked.png")
        showStatus(); save("status.png"); message = nil

        // Slide and note in step. Keys are still recorded, not sent.
        MouseControl.shared.isActive = { _, _ in true }
        var sync: [String] = []
        let deck = "https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id."
        follower.ingest(addresses: [deck + "p"])
        sync.append("slide 1 showing: note \(pageIndex + 1)")
        keysSent = []
        _ = click(.leftMouseDown); _ = click(.leftMouseUp)
        sync.append("left click, browser address silent: note \(pageIndex + 1), keys \(keysSent)")
        follower.forget(); follower.ingest(addresses: [deck + "p"])
        sync.append("browser repeats the old slide: note \(pageIndex + 1) (should stay 2)")
        follower.ingest(addresses: [deck + "g3abc"])
        sync.append("browser reports slide 3: note \(pageIndex + 1), address trusted from now: \(addressTracksSlides)")
        _ = click(.rightMouseDown); _ = click(.rightMouseUp)
        sync.append("right click: note \(pageIndex + 1) at once")
        follower.ingest(addresses: [deck + "g2f_0_5"])
        sync.append("browser confirms slide 2: note \(pageIndex + 1)")
        _ = click(.leftMouseDown); _ = click(.leftMouseUp)
        sync.append("left click that only plays an animation: note \(pageIndex + 1) at first")
        RunLoop.current.run(until: Date().addingTimeInterval(1.6))
        sync.append("no new slide reported after 1.6 seconds: note \(pageIndex + 1) (should return to 2)")
        print(sync.joined(separator: "\n"))

        // Where the pointer is: (over notes, wheel, window underneath is the browser / another app / nothing, floating)
        let cases: [(String, Bool, Bool, Bool?, Bool, Bool)] = [
            ("one screen: click on notes over the slideshow", true, false, true, false, true),
            ("one screen: click on meeting controls floating over the slideshow", true, false, false, true, false),
            ("one screen: wheel on notes over meeting controls", true, true, false, true, true),
            ("two screens: click on the slideshow, notes elsewhere", false, false, true, false, true),
            ("two screens: wheel on the slideshow, notes elsewhere", false, true, true, false, true),
            ("two screens: click on notes with an ordinary window underneath", true, false, false, false, true),
            ("two screens: click on notes with bare desktop underneath", true, false, nil, false, true),
            ("two screens: wheel on notes with an ordinary window underneath", true, true, false, false, true),
            ("click on another app, away from slides and notes", false, false, false, false, false),
            ("click on bare desktop, away from slides and notes", false, false, nil, false, false),
        ]
        for (name, overNotes, wheel, topIsBrowser, floats, expected) in cases {
            let applies = AppDelegate.pointerBlockedReason(overNotes: overNotes, wheel: wheel, topIsBrowser: topIsBrowser, topFloats: floats) == nil
            print("\(applies == expected ? "ok  " : "FAIL") \(name): mouse \(applies ? "drives the slideshow" : "left alone")")
        }
        MouseControl.shared.isActive = realActive; MouseControl.shared.sendKey = realSendKey
        store.use(realNotes, remember: false)
        Settings.notesPath = savedPath
        pageIndex = savedPage; Settings.pageIndex = savedPage
        for (bundleID, browser) in SlideFollower.browsers {
            var error: NSDictionary?
            let script = NSAppleScript(source: SlideFollower.source(bundleID: bundleID, tab: browser.tab))
            let compiled = script?.compileAndReturnError(&error) ?? false
            print("script for \(browser.name): \(compiled ? "compiles" : "FAILED \(error ?? [:])")")
        }
        NSApp.terminate(nil)
    }

    // MARK: State to screen

    private func applyVisibility() {
        if visible {
            for command in commands where !command.always {
                if let id = register(command) { contextualHotKeys.append(id) } else { blockedShortcuts.append(command.keys) }
            }
            if !blockedShortcuts.isEmpty {
                message = ("These shortcuts could not be set up, so they will not work:\n\n"
                           + blockedShortcuts.joined(separator: "\n"), .white)
                blockedShortcuts.removeAll()
            }
            follower.forget()
            panel.orderFrontRegardless()
        } else {
            contextualHotKeys.forEach(HotKeyCenter.shared.unregister)
            contextualHotKeys.removeAll()
            panel.orderOut(nil)
        }
    }

    private func refresh() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens[min(Settings.screenIndex, screens.count - 1)].frame
        var frame = screen
        switch Settings.layoutIndex {
        case 1: frame = NSRect(x: screen.minX, y: screen.midY, width: screen.width, height: screen.height / 2)
        case 2: frame = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height / 2)
        default: break
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }

        pageIndex = min(max(pageIndex, 0), store.pages.count - 1)
        Settings.pageIndex = pageIndex
        view.text = noNoteForSlide ? "" : store.pages[pageIndex].text
        view.pageLabel = noNoteForSlide ? "No note for this slide" : "\(pageIndex + 1) / \(store.pages.count)"
        view.helpText = showingHelp ? commands.map { "\($0.keys)\t\($0.title)" }.joined(separator: "\n") : nil
        view.message = message
        view.fontSize = CGFloat(Settings.fontSize)
        // The notes have their own screen, so the background is solid black and the text fully solid.
        view.backdropOpacity = 1
        view.textOpacity = 1
        view.textColour = textColours[min(Settings.colourIndex, textColours.count - 1)].colour
        view.needsDisplay = true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no Dock icon, never steals focus from the slides
app.run()
