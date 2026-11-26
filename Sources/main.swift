import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

// Presenter Notes
// A window that shows large-print speaker notes and keeps them in step with the
// Google Slides slide showing in the browser. The window is excluded from screen
// sharing and recording, so only the presenter sees it.

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
    @Stored(key: "pageIndex", fallback: 0) static var pageIndex: Int
    @Stored(key: "notesPath", fallback: "") static var notesPath: String
    @Stored(key: "followSlides", fallback: true) static var followSlides: Bool
    /// The browser that last showed Google Slides, asked first when no browser is in front.
    @Stored(key: "slidesBrowser", fallback: "") static var slidesBrowser: String
    /// Turning a note also moves the slideshow in the browser.
    @Stored(key: "moveSlideshow", fallback: true) static var moveSlideshow: Bool
    @Stored(key: "editorFontSize", fallback: 26.0) static var editorFontSize: Double
}

let textColours: [(name: String, colour: NSColor)] = [
    ("White", .white),
    ("Yellow", NSColor(red: 1.0, green: 0.92, blue: 0.2, alpha: 1)),
    ("Green", NSColor(red: 0.45, green: 1.0, blue: 0.45, alpha: 1)),
    ("Cyan", NSColor(red: 0.4, green: 0.95, blue: 1.0, alpha: 1)),
]

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

    Press Ctrl+Opt+Right for the next note and Ctrl+Opt+Left to go back. These work from any app.

    Ctrl+Opt+Up makes the text bigger and Ctrl+Opt+Down makes it smaller.
    ---
    This is the note for slide 2.

    When this window is in front, the Right and Left arrow keys turn the notes too.
    ---
    Press Ctrl+Opt+E to edit your notes.

    Put a line with three dashes between slides. Your changes save as you type and show here straight away.
    ---
    Press Ctrl+Opt+H for the list of shortcuts.
    """

    struct Page {
        var text: String
        /// The Google Slides ID of the slide this note belongs to, from a `slide:` line.
        var slideID: String?
        /// The lines above the note text exactly as written (`deck:`, `slide:` and blank lines), kept so saving changes nothing else.
        var header: String = ""
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
            if !FileManager.default.fileExists(atPath: url.path) {
                // The set in use was deleted or moved. Fall back to another set, or to a fresh sample.
                url = NotesStore.anyFile(near: url) ?? NotesStore.defaultURL
                Settings.notesPath = url.path
                createSampleIfMissing()
            }
        }
        load()
    }

    /// Another notes file to use when one goes missing: from the same folder, then the notes folder.
    static func anyFile(near missing: URL) -> URL? {
        for folder in [missing.deletingLastPathComponent(), defaultURL.deletingLastPathComponent()] {
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "txt" && $0.standardizedFileURL.path != missing.standardizedFileURL.path }
                .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            if let first = files.first { return first }
        }
        return nil
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

    /// Writes the notes back to the file. Lines above each note are kept exactly as they were.
    static func serialize(_ pages: [Page]) -> String {
        pages.map { $0.header + $0.text }.joined(separator: "\n---\n") + "\n"
    }

    /// Changes the text of one note. `save()` writes it to the file.
    func setText(_ text: String, page: Int) {
        guard pages.indices.contains(page) else { return }
        pages[page].text = text
    }

    /// Adds a note for a slide that has none, and returns its number. A set with no notes yet uses its empty first note.
    /// A set not yet linked to a deck is linked to this one.
    func addPage(slideID: String, deckID newDeck: String?) -> Int {
        if deckID == nil, let newDeck {
            pages[0].header = "deck: \(NotesEditing.deckLink(newDeck))\n\n" + pages[0].header
            deckID = newDeck
        }
        if pages.count == 1, pages[0].text.isEmpty, pages[0].slideID == nil {
            pages[0].header += "slide: \(slideID)\n"
            pages[0].slideID = slideID
            return 0
        }
        pages.append(Page(text: "", slideID: slideID, header: "slide: \(slideID)\n"))
        return pages.count - 1
    }

    func save() throws {
        try NotesStore.serialize(pages).write(to: url, atomically: true, encoding: .utf8)
        lastModified = modificationDate() // our own save is not a change from outside
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
            var headerLines: [String] = []
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
                headerLines.append(contentsOf: lines[...index])
                lines.removeSubrange(...index)
            }
            pages.append(Page(text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                              slideID: slideID, header: headerLines.isEmpty ? "" : headerLines.joined(separator: "\n") + "\n"))
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

// MARK: - Markdown in notes

/// A small part of Markdown, used to style notes:
/// `#` to `#####` headings (each bigger than normal text, `#` the biggest), `**bold**`, `*italic*`, and `- ` bullets.
/// Sizes are a percentage of the base text size, so changing the text size scales everything together.
enum NoteMarkdown {
    /// Size of each heading level against normal text: `#` is twice the size, `#####` a little bigger.
    static let headingScale: [CGFloat] = [2.0, 1.75, 1.5, 1.3, 1.15]

    struct Style {
        var base: CGFloat
        var colour: NSColor
        /// Weight of normal text. The notes window uses bold; the editor uses regular.
        var weight: NSFont.Weight
        /// True in the editor: the Markdown symbols stay, drawn dimmed. False in the notes window: they are hidden.
        var showMarkers: Bool
        var markerColour: NSColor = .secondaryLabelColor
        /// Lines such as `slide:`, `deck:` and `---`, drawn dimmed in the editor.
        var dimHeaderLines = false
    }

    /// The heading level of a line (1 to 5) and where its text starts, or nil for a line that is not a heading.
    static func heading(_ line: String) -> (level: Int, markerLength: Int)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6, line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " else { return nil }
        return (min(hashes, 5), hashes + 1)
    }

    static func sizeOf(line: String, base: CGFloat) -> CGFloat {
        heading(line).map { base * headingScale[$0.level - 1] } ?? base
    }

    private static let inline = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*|(?<![\*\w])\*(?![\s\*])(.+?)(?<![\s\*])\*(?![\*\w])"#)

    static func render(_ text: String, _ style: Style) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (number, rawLine) in lines.enumerated() {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeaderLine = style.dimHeaderLines && (trimmed.lowercased().hasPrefix("slide:") || trimmed.lowercased().hasPrefix("deck:")
                || (trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }))
            var size = style.base
            var weight = style.weight
            var prefix = ""
            if isHeaderLine {
                size = style.base * 0.8
            } else if let h = heading(line) {
                size = style.base * headingScale[h.level - 1]
                weight = .heavy
                prefix = String(line.prefix(h.markerLength))
                line = String(line.dropFirst(h.markerLength))
            } else if let bullet = line.range(of: #"^\s*[-*+] "#, options: .regularExpression) {
                prefix = String(line[bullet])
                line = String(line[bullet.upperBound...])
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = size * 0.1
            paragraph.paragraphSpacing = size * 0.3
            paragraph.lineBreakMode = .byWordWrapping
            func font(_ weight: NSFont.Weight, italic: Bool = false, size: CGFloat) -> NSFont {
                let plain = NSFont.systemFont(ofSize: size, weight: weight)
                guard italic else { return plain }
                return NSFont(descriptor: plain.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? plain
            }
            let normal: [NSAttributedString.Key: Any] = [
                .font: font(weight, size: size), .foregroundColor: isHeaderLine ? style.markerColour : style.colour, .paragraphStyle: paragraph,
            ]
            var marker = normal
            marker[.foregroundColor] = style.markerColour
            let lineOut = NSMutableAttributedString()
            if !prefix.isEmpty {
                if style.showMarkers {
                    lineOut.append(NSAttributedString(string: prefix, attributes: marker))
                } else if heading(prefix + "x") == nil {
                    lineOut.append(NSAttributedString(string: "\u{2022} ", attributes: normal)) // a bullet point
                }
            }
            // Bold and italic inside the line.
            let ns = line as NSString
            var cursor = 0
            for match in isHeaderLine ? [] : inline.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    lineOut.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: normal))
                }
                let isBold = match.range(at: 1).location != NSNotFound
                let inner = match.range(at: isBold ? 1 : 2)
                let markerText = isBold ? "**" : "*"
                var styled = normal
                styled[.font] = isBold ? font(.black, size: size) : font(weight, italic: true, size: size)
                if style.showMarkers { lineOut.append(NSAttributedString(string: markerText, attributes: marker)) }
                lineOut.append(NSAttributedString(string: ns.substring(with: inner), attributes: styled))
                if style.showMarkers { lineOut.append(NSAttributedString(string: markerText, attributes: marker)) }
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                lineOut.append(NSAttributedString(string: ns.substring(from: cursor), attributes: normal))
            }
            if number < lines.count - 1 { lineOut.append(NSAttributedString(string: "\n", attributes: normal)) }
            out.append(lineOut)
        }
        return out
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

    private var lastCode: Int?
    /// When the browser last answered. Used to tell a slide that did not move from a browser that is not answering.
    private(set) var lastAnswer: Date?
    /// The browser last seen showing Google Slides, if one has been.
    var slidesBrowserSeen: String? { Settings.slidesBrowser.isEmpty ? nil : Settings.slidesBrowser }

    /// Makes the next poll report the position again, even if it has not changed.
    func forget() { last = nil }

    /// Called when a browser has not answered for several seconds. macOS is almost always
    /// showing its "allow Presenter Notes to control this browser" prompt at that point.
    var onWaiting: ((String) -> Void)?
    private var pollStarted: Date?
    private var waitingReported = false
    private var lastTarget: String?
    private var lastCount = -1
    /// The browser that last showed Google Slides. Asked when another app is in front, such as the
    /// notes window or a meeting window, so the notes keep following the slides. Remembered between
    /// launches, so a notes window opened before the browser is touched still follows. Falls back to
    /// Chrome, the browser the app is tested with, and never asks a browser that has not shown Slides
    /// here, so no unexpected permission prompt appears.
    private var slidesBrowser: String? = Settings.slidesBrowser.isEmpty ? "com.google.Chrome" : Settings.slidesBrowser
    private var askingName = ""

    /// Call on the main thread, a few times a second.
    func poll() {
        if busy {
            if let started = pollStarted, Date().timeIntervalSince(started) > 4, !waitingReported {
                waitingReported = true
                Log.write("\(askingName) has not answered for 4 seconds. macOS is probably showing a permission prompt")
                onWaiting?(askingName)
            }
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var target: String?
        if let front, SlideFollower.browsers[front] != nil {
            target = front
        } else if let remembered = slidesBrowser,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: remembered).isEmpty {
            target = remembered
        }
        if target != lastTarget {
            lastTarget = target
            Log.write("asking: \(target.flatMap { SlideFollower.browsers[$0]?.name } ?? "no browser (front app is \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"))")")
        }
        guard let bundleID = target, let browser = SlideFollower.browsers[bundleID] else { return }
        guard !denied.contains(bundleID) else { return }
        busy = true
        pollStarted = Date()
        askingName = browser.name
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
                    onDenied?(browser.name)
                } else if code == nil {
                    lastAnswer = Date()
                    let count = addresses.filter { $0.contains("/presentation/d/") }.count
                    if count != lastCount {
                        lastCount = count
                        Log.write("\(browser.name) windows showing Google Slides: \(count)")
                    }
                    if count > 0, slidesBrowser != bundleID {
                        slidesBrowser = bundleID
                        Settings.slidesBrowser = bundleID
                    }
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
        guard let position = decks.first(where: { $0.slideID != nil }) ?? decks.first, position != last else { return }
        last = position
        Log.write("slide seen: deck \(position.deckID.prefix(8)) slide \(position.slideID ?? "none")")
        onPosition?(position)
    }
}

// MARK: - Moving the slideshow

/// Moves the slideshow by pressing an arrow key in the browser that shows it.
/// Works in any browser, including ones the app cannot read the slide from, such as Zen and Firefox.
/// Pressing keys in another app needs the Accessibility permission.
final class SlideDriver {
    static let browserIDs: Set<String> = Set(SlideFollower.browsers.keys).union([
        "app.zen-browser.zen", "org.mozilla.firefox", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ])

    /// The browser that was last in front. The slideshow is almost always there.
    private(set) var lastBrowser: NSRunningApplication?
    /// A browser known to show Google Slides, from the slide follower.
    var knownBrowser: () -> String? = { nil }
    /// Used by the self-test to aim at its own stand-in app.
    var targetOverride: NSRunningApplication?
    /// Presses a key in the front app. Replaced in the self-test.
    var post: (CGKeyCode) -> Void = { key in
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = [] // Ctrl and Opt are still held from the shortcut; the slideshow must see a plain arrow
            event?.post(tap: .cghidEventTap)
        }
    }
    private var pending: [CGKeyCode] = []
    private var returnAfter = false

    init() {
        if let front = NSWorkspace.shared.frontmostApplication, SlideDriver.isBrowser(front) { lastBrowser = front }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  SlideDriver.isBrowser(app) else { return }
            self?.lastBrowser = app
        }
    }

    static func isBrowser(_ app: NSRunningApplication) -> Bool { app.bundleIdentifier.map(browserIDs.contains) ?? false }

    /// The browser to press the key in: the front one, else the one last in front, else one known to show Slides.
    func target() -> NSRunningApplication? {
        if let targetOverride { return targetOverride.isTerminated ? nil : targetOverride }
        if let front = NSWorkspace.shared.frontmostApplication, SlideDriver.isBrowser(front) { return front }
        if let last = lastBrowser, !last.isTerminated { return last }
        if let id = knownBrowser() { return NSRunningApplication.runningApplications(withBundleIdentifier: id).first }
        return nil
    }

    /// Presses a key in the slideshow's browser. Returns the browser's name, or nil when no browser is running.
    /// When another app is in front, the browser comes forward for a moment and the app in front gets focus back.
    func press(_ key: CGKeyCode) -> String? {
        guard let app = target() else { return nil }
        let name = app.localizedName ?? "the browser"
        if app.isActive && pending.isEmpty {
            post(key)
            return name
        }
        pending.append(key)
        guard pending.count == 1 else { return name } // already bringing the browser forward
        returnAfter = NSApp.isActive
        if returnAfter { NSApp.yieldActivation(to: app) }
        app.activate(options: [])
        waitThenPress(in: app, triesLeft: 25)
        return name
    }

    private func waitThenPress(in app: NSRunningApplication, triesLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
            guard app.isActive || triesLeft == 0 else { return waitThenPress(in: app, triesLeft: triesLeft - 1) }
            if app.isActive {
                pending.forEach(post)
            } else {
                Log.write("\(app.localizedName ?? "the browser") did not come to the front, so the slide was not moved")
            }
            pending.removeAll()
            guard returnAfter else { return }
            // Give the browser a moment to take the key, then come back to the notes window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { NSApp.activate(ignoringOtherApps: true) }
        }
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

// MARK: - Notes window

/// A view filled with one colour. Holds the bars of the notes window and the test square.
final class FillView: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }

    init(_ fill: NSColor, content: NSView? = nil, insets: NSEdgeInsets = NSEdgeInsets()) {
        self.fill = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        guard let content else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Paint only inside the view. Since macOS 14 views do not clip their drawing by default, and the
    // area macOS asks a view to redraw can reach past its edges. Filling that area made the bottom bar
    // paint over the note text above it.
    override var clipsToBounds: Bool {
        get { true }
        set {}
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.intersection(dirtyRect).fill()
    }
}

/// The text of the notes window. It behaves as ordinary text: select, copy, find, scroll.
/// The Right and Left arrow keys turn the notes. Up and Down scroll one line of text at its current size.
final class NotesTextView: NSTextView {
    var onTurn: (Int) -> Void = { _ in }
    var onScrollLines: (CGFloat) -> Void = { _ in }

    /// Copy gives plain text, so pasting a note elsewhere does not bring huge white letters with it.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
            if key == NSRightArrowFunctionKey { onTurn(1); return }
            if key == NSLeftArrowFunctionKey { onTurn(-1); return }
            if key == NSDownArrowFunctionKey { onScrollLines(1); return }
            if key == NSUpArrowFunctionKey { onScrollLines(-1); return }
        }
        super.keyDown(with: event)
    }
}

/// The notes window: the note for the slide on screen, in large print. It is an ordinary window.
/// It can be moved, resized, made full screen and left with Cmd+Tab, and its text can be selected and scrolled.
final class NotesWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow
    let textView = NotesTextView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let scrollView = NSScrollView()
    var onClose: () -> Void = {}
    var onTurn: (Int) -> Void = { _ in }
    var onEdit: () -> Void = {}
    var onDismissMessage: () -> Void = {}
    /// The text in the edit box changed.
    var onEditorChange: (String) -> Void = { _ in }

    /// The edit box beside the notes: plain text, one size. The notes beside it show the sizes.
    private(set) var editor: NSTextView!
    private var editorPane: FillView!
    private var editButton: ClosureButton!
    private let editorTitle = NSTextField(labelWithString: "")
    private var lastPageKey: String?

    private let banner = NSTextField(wrappingLabelWithString: "")
    private var bannerBar: FillView!
    private let nameLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private let patch = FillView(.clear)
    private var shown: (text: String, size: CGFloat, colour: NSColor, tabStop: CGFloat?)?
    private var name = ""
    private var flashTimer: Timer?
    static let flashColour = NSColor(red: 1.0, green: 0.92, blue: 0.2, alpha: 1)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Presenter Notes"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 380)
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.delegate = self
        buildContent()
        window.initialFirstResponder = textView
        window.center()
        window.setFrameAutosaveName("PresenterNotesWindow")
    }

    private func buildContent() {
        // Text: never editable here, always selectable, and wrapped to the width of the window.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true // needed for mixed sizes; copying still gives plain text, see NotesTextView
        textView.drawsBackground = true
        textView.backgroundColor = .black
        textView.textContainerInset = NSSize(width: 36, height: 28)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 1000, height: CGFloat.greatestFiniteMagnitude)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1),
                                           .foregroundColor: NSColor.white]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("Note")
        textView.onTurn = { [unowned self] delta in onTurn(delta) }
        textView.onScrollLines = { [unowned self] lines in scroll(lines: lines) }
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // A bar across the top for messages, such as a permission macOS still needs. Hidden when there is none.
        banner.font = .systemFont(ofSize: 24, weight: .bold)
        banner.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let okButton = ClosureButton("OK", size: 20, bold: true) { [unowned self] in onDismissMessage() }
        okButton.fill = .systemBlue
        let bannerRow = NSStackView(views: [banner, okButton])
        bannerRow.spacing = 18
        bannerRow.alignment = .centerY
        bannerBar = FillView(NSColor(white: 0.2, alpha: 1), content: bannerRow,
                             insets: NSEdgeInsets(top: 16, left: 24, bottom: 16, right: 20))
        bannerBar.isHidden = true

        // A bar across the bottom: buttons to turn the notes, the set's name and which note is showing.
        let previous = ClosureButton("Previous", size: 20) { [unowned self] in onTurn(-1) }
        let next = ClosureButton("Next", size: 20, bold: true) { [unowned self] in onTurn(1) }
        next.fill = .systemBlue
        let edit = ClosureButton("Edit notes", size: 20) { [unowned self] in onEdit() }
        editButton = edit
        for label in [nameLabel, pageLabel] {
            label.textColor = .white
            label.lineBreakMode = .byTruncatingTail
        }
        nameLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pageLabel.font = .systemFont(ofSize: 26, weight: .bold)
        pageLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerRow = NSStackView(views: [previous, next, nameLabel, spacer, pageLabel, edit])
        footerRow.spacing = 14
        footerRow.alignment = .centerY
        let footerBar = FillView(NSColor(white: 0.13, alpha: 1), content: footerRow,
                                 insets: NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))

        // The edit box, on the left, shown and hidden with Edit notes.
        let editorScroll = NSTextView.scrollableTextView()
        editorScroll.borderType = .noBorder
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = NSColor(white: 0.1, alpha: 1)
        editor = (editorScroll.documentView as! NSTextView)
        editor.delegate = self
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.drawsBackground = true
        editor.backgroundColor = NSColor(white: 0.1, alpha: 1)
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.textContainerInset = NSSize(width: 12, height: 12)
        // Smart dashes would turn the three dashes that separate notes into a long dash.
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("Edit this slide's note")
        setEditorFontSize(CGFloat(Settings.editorFontSize))
        editorTitle.font = .systemFont(ofSize: 22, weight: .bold)
        editorTitle.textColor = .white
        editorTitle.lineBreakMode = .byTruncatingTail
        editorTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tip = NSTextField(wrappingLabelWithString: "Saves as you type. # makes a big heading, up to ##### for a smaller one. **bold**, *italic*, and - for a bullet.")
        tip.font = .systemFont(ofSize: 17)
        tip.textColor = NSColor(white: 0.75, alpha: 1)
        tip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let editorStack = NSStackView(views: [editorTitle, editorScroll, tip])
        editorStack.orientation = .vertical
        editorStack.alignment = .leading
        editorStack.spacing = 10
        editorPane = FillView(NSColor(white: 0.16, alpha: 1), content: editorStack,
                              insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        editorPane.isHidden = true
        NSLayoutConstraint.activate([
            editorScroll.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
            editorTitle.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
            tip.widthAnchor.constraint(equalTo: editorStack.widthAnchor),
        ])
        editorScroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)

        let body = NSStackView(views: [editorPane, scrollView])
        body.orientation = .horizontal
        body.spacing = 0
        body.alignment = .top
        body.distribution = .fill
        body.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let root = NSStackView(views: [bannerBar, body, footerBar])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(root)
        // The coloured square for the screen sharing check sits over the middle of the text.
        patch.isHidden = true
        content.addSubview(patch)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bannerBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            editorPane.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.42),
            editorPane.heightAnchor.constraint(equalTo: body.heightAnchor),
            scrollView.heightAnchor.constraint(equalTo: body.heightAnchor),
            footerBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            patch.widthAnchor.constraint(equalToConstant: 240),
            patch.heightAnchor.constraint(equalToConstant: 240),
            patch.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            patch.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        // The text takes all the spare height. The bars keep their natural height.
        // Without this the layout gave the spare height to the bottom bar and squashed the text to nothing.
        root.distribution = .fill
        body.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        body.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scrollView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        for bar in [bannerBar!, footerBar] {
            bar.setContentHuggingPriority(.required, for: .vertical)
            bar.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        window.contentView = content
    }

    // MARK: Showing

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    /// Shows a note. A different note starts at the top. A new size or colour keeps the place.
    /// `pageKey` names the note. A different note starts at the top; typing in the same note keeps the place.
    func render(text: String, size: CGFloat, colour: NSColor, tabStop: CGFloat? = nil, markdown: Bool = true, pageKey: String? = nil) {
        let key = pageKey ?? text
        let newPage = key != lastPageKey
        lastPageKey = key
        if !newPage, let shown, shown.text == text, shown.size == size, shown.colour == colour, shown.tabStop == tabStop { return }
        let newText = newPage
        shown = (text, size, colour, tabStop)
        scrollView.verticalLineScroll = lineHeight // a mouse wheel notch moves one line of text at this size
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.1
        paragraph.paragraphSpacing = size * 0.3
        paragraph.lineBreakMode = .byWordWrapping
        if let tabStop {
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: tabStop)]
            paragraph.headIndent = tabStop
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: colour,
            .paragraphStyle: paragraph,
        ]
        let styled = markdown
            ? NoteMarkdown.render(text, .init(base: size, colour: colour, weight: .bold, showMarkers: false))
            : NSAttributedString(string: text, attributes: attributes)
        textView.textStorage?.setAttributedString(styled)
        textView.typingAttributes = attributes
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        textView.sizeToFit()
        if newText {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func setLabels(name: String, page: String) {
        self.name = name
        if flashTimer == nil { nameLabel.stringValue = name }
        pageLabel.stringValue = page
    }

    /// Shows a short confirmation, such as "Text size 128", in place of the set's name.
    func flash(_ text: String) {
        nameLabel.stringValue = text
        nameLabel.textColor = NotesWindowController.flashColour
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.flashTimer = nil
            self.nameLabel.stringValue = self.name
            self.nameLabel.textColor = .white
        }
    }

    var message: (text: String, colour: NSColor)? {
        didSet {
            bannerBar.isHidden = message == nil
            banner.stringValue = message?.text ?? ""
            banner.textColor = message?.colour ?? .white
        }
    }

    var bannerText: String? { bannerBar.isHidden ? nil : banner.stringValue }
    var pageText: String { pageLabel.stringValue }

    // MARK: The edit box

    var isEditing: Bool { !editorPane.isHidden }

    func setEditing(_ on: Bool) {
        editorPane.isHidden = !on
        editButton.title = on ? "Hide editor" : "Edit notes"
        editButton.invalidateIntrinsicContentSize()
        editButton.needsDisplay = true
        window.makeFirstResponder(on ? editor : textView)
    }

    /// Puts a note in the edit box, unless it already holds that text. Typing is never overwritten.
    func loadEditor(_ text: String, title: String) {
        editorTitle.stringValue = title
        guard editor.string != text else { return }
        editor.string = text
        editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    var editorHasFocus: Bool { window.firstResponder === editor }

    func setEditorFontSize(_ size: CGFloat) {
        editor.font = .systemFont(ofSize: size)
    }

    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === editor else { return }
        onEditorChange(editor.string)
    }

    // MARK: Scrolling

    var scrollOffset: CGFloat { scrollView.contentView.bounds.origin.y }
    var maxScroll: CGFloat { max(0, textView.frame.height - scrollView.contentView.bounds.height) }

    /// The height of one line of the note at its current size, with the space between lines.
    var lineHeight: CGFloat { ceil((shown?.size ?? 40) * 1.3) }

    func scroll(pages: CGFloat) { scroll(points: pages * scrollView.contentView.bounds.height * 0.8) }

    func scroll(lines: CGFloat) { scroll(points: lines * lineHeight) }

    func scroll(points: CGFloat) {
        let clip = scrollView.contentView
        let y = min(max(clip.bounds.origin.y + points, 0), maxScroll)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Screen sharing check

    var testPatch: NSColor? {
        didSet {
            patch.fill = testPatch ?? .clear
            patch.isHidden = testPatch == nil
        }
    }

    /// Where the test square is, in screen coordinates.
    var patchFrameOnScreen: NSRect {
        window.convertToScreen(patch.convert(patch.bounds, to: nil))
    }
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

// MARK: - Editing notes

/// Text changes made by the notes window. Kept apart from the window so they can be tested.
enum NotesEditing {
    static func deckLink(_ deckID: String) -> String { "https://docs.google.com/presentation/d/\(deckID)/edit" }

    /// A file for a new set of notes, with a name that is free in the folder.
    static func newFileURL(named name: String, in folder: URL) -> URL {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\\"] { base = base.replacingOccurrences(of: bad, with: "-") }
        if base.lowercased().hasSuffix(".txt") { base = String(base.dropLast(4)) }
        if base.isEmpty { base = "Notes" }
        var url = folder.appendingPathComponent(base + ".txt")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).txt")
            number += 1
        }
        return url
    }

    /// What a new set starts with. If a deck is showing in the browser, the set is linked to it.
    static func starterText(deckID: String?, slideID: String?) -> String {
        guard let deckID else {
            return "Type the note for your first slide here.\n---\nType the note for your second slide here.\n"
        }
        var text = "deck: \(deckLink(deckID))\n\n"
        if let slideID { text += "slide: \(slideID)\n" }
        return text + "Type the note for this slide here.\n"
    }

}

/// A button drawn by the app itself: a solid colour with large white text.
/// System buttons vary with the appearance setting and can be low in contrast.
final class ClosureButton: NSButton {
    private var handler: () -> Void = {}
    private var textSize: CGFloat = 18
    private var bold = false
    /// The button's colour. Blue marks the main action.
    var fill = NSColor(white: 0.36, alpha: 1) { didSet { needsDisplay = true } }

    convenience init(_ title: String, size: CGFloat = 18, bold: Bool = false, handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        self.textSize = size
        self.bold = bold
        target = self
        action = #selector(fire)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: textSize, weight: bold ? .bold : .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    override var intrinsicContentSize: NSSize {
        let size = label.size()
        return NSSize(width: ceil(size.width) + textSize * 2, height: ceil(size.height) + textSize * 0.9)
    }

    override func draw(_ dirtyRect: NSRect) {
        let colour = isHighlighted ? (fill.blended(withFraction: 0.35, of: .black) ?? fill) : fill
        colour.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    @objc private func fire() { handler() }

    // A click anywhere on the painted button presses it. Left to the system, a borderless button
    // with its own drawing did not claim real mouse clicks, so pressing it did nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil // `point` and `frame` are both in the superview's coordinates
    }

    /// The first click works even when the window is not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        var inside = true
        isHighlighted = true
        display()
        // Follow the mouse until the button is let go. Letting go outside the button cancels the press.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isHighlighted = inside
            display()
            if next.type == .leftMouseUp { break }
        }
        isHighlighted = false
        display()
        if inside { handler() }
    }
}

/// A sheet with large text, for the questions the notes window asks.
enum LargeSheet {
    static func ask(in window: NSWindow, title: String, message: String, field: String? = nil,
                    actionTitle: String, completion: @escaping (_ answer: String?) -> Void) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 19)
        var input: NSTextField?
        if let field {
            let text = NSTextField(string: field)
            text.font = .systemFont(ofSize: 24)
            text.setAccessibilityLabel(title)
            input = text
        }
        func finish(_ answer: String?) {
            window.endSheet(sheet)
            completion(answer)
        }
        let cancel = ClosureButton("Cancel", size: 19) { finish(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let action = ClosureButton(actionTitle, size: 19, bold: true) { finish(input?.stringValue ?? "") }
        action.fill = actionTitle == "Delete" ? .systemRed : .systemBlue
        action.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, action])
        buttons.spacing = 14
        let stack = NSStackView(views: [titleLabel, messageLabel] + (input.map { [$0] } ?? []) + [buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 26, bottom: 22, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 620),
        ])
        input?.widthAnchor.constraint(equalToConstant: 560).isActive = true
        sheet.contentView = content
        sheet.initialFirstResponder = input
        window.beginSheet(sheet)
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func fire() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = NotesStore()
    private var notes: NotesWindowController!
    private var statusItem: NSStatusItem!
    private var commands: [Command] = []
    /// Registered shortcut IDs by key, so the self-test can press them.
    private var hotKeyIDs: [String: UInt32] = [:]
    static let ctrlOpt = controlKey | optionKey
    private var contextualHotKeys: [UInt32] = []
    /// True while the notes window is open. The shortcuts that turn the notes work only then.
    private var visible = false
    private var saveTimer: Timer?
    /// True while typing in the edit box has not been written to the file yet.
    private var unsaved = false
    /// How a deleted set is removed. The Trash, so it can be got back. The self-test removes its own files outright.
    private var removeFile: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    /// The File menu's list of sets, filled in each time it opens.
    private let setsMenu = NSMenu(title: "Open Set")
    private var sharingChecked = false
    private var showingHelp = false
    private var message: (text: String, colour: NSColor)?
    private var messageTimer: Timer?
    private var blockedShortcuts: [String] = []
    private let follower = SlideFollower()
    private let driver = SlideDriver()
    /// Sends a key to the slideshow. Replaced in the self-test so no real key is pressed.
    private lazy var sendToSlideshow: (CGKeyCode) -> String? = { [unowned self] key in driver.press(key) }
    private var askedForKeyPermission = false
    private var moveCheck = 0
    private var lastPosition: SlideFollower.Position?
    private var lastDeckSeen: String?
    /// True when the slide on screen has no note linked to it.
    private var noNoteForSlide = false
    private var pageIndex = Settings.pageIndex
    /// `--capturable` lets screen sharing see the notes. Used to rehearse and to test the hiding.
    private let capturable = CommandLine.arguments.contains("--capturable")
    private let selfTest = CommandLine.arguments.contains("--snapshot")

    /// Shows a message that clears itself. Used for confirmations that need no action.
    private func showBriefly(_ text: String, colour: NSColor, seconds: TimeInterval) {
        message = (text, colour)
        refresh()
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self, self.message?.text == text else { return }
            self.message = nil
            self.refresh()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        notes = NotesWindowController()
        notes.window.sharingType = capturable ? .readOnly : .none // .none keeps the notes out of screen sharing
        notes.onClose = { [unowned self] in notesWindowClosed() }
        notes.onTurn = { [unowned self] delta in run(delta > 0 ? kVK_RightArrow : kVK_LeftArrow) }
        notes.onEdit = { [unowned self] in toggleEditor() }
        notes.onEditorChange = { [unowned self] text in editorChanged(text) }
        notes.onDismissMessage = { [unowned self] in
            message = nil
            refresh()
        }

        buildCommands()
        buildMenu()
        for command in commands where command.always {
            if register(command) == nil { blockedShortcuts.append(command.keys) }
        }

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.store.reloadIfChanged() else { return }
            if let position = self.lastPosition, Settings.followSlides { self.show(position) }
            self.refresh()
            self.notes.flash("Notes reloaded")
        }

        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            Log.url = URL(fileURLWithPath: CommandLine.arguments[flag + 1]).appendingPathComponent("test.log")
        }
        Log.write("started. notes \(store.url.lastPathComponent), \(store.pages.count) notes, follow \(Settings.followSlides)")
        follower.onPosition = { [weak self] position in self?.show(position) }
        driver.knownBrowser = { [weak self] in self?.follower.slidesBrowserSeen }
        follower.onWaiting = { [weak self] browser in
            guard let self else { return }
            self.message = ("macOS is asking whether Presenter Notes may control \(browser). Find that prompt and choose Allow. Your notes cannot follow the slides until you do.", AppDelegate.warningColour)
            self.refresh()
        }
        follower.onDenied = { [weak self] browser in
            guard let self else { return }
            self.message = ("Presenter Notes is not allowed to ask \(browser) which slide is showing, so your notes will not follow the slides. Open System Settings, then Privacy & Security, then Automation. Under Presenter Notes, turn on \(browser).", .white)
            self.refresh()
        }
        // Ask the browser which slide is showing while either window is open.
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, Settings.followSlides, self.visible else { return }
            self.follower.poll()
        }

        buildMainMenu()
        refresh()

        if let flag = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > flag + 1 {
            writeSnapshots(to: CommandLine.arguments[flag + 1])
        } else if !CommandLine.arguments.contains("--hidden") {
            present(store.url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveNow() // never lose typing that has not been saved yet
    }

    // MARK: Commands

    private func buildCommands() {
        commands = [
            Command(title: "Show the notes window", keys: "Ctrl+Opt+N", keyCode: kVK_ANSI_N, always: true) { [unowned self] in
                present(store.url)
            },
            Command(title: "Next slide and note", keys: "Ctrl+Opt+Right", keyCode: kVK_RightArrow) { [unowned self] in
                turn(by: 1); moveSlideshow(kVK_RightArrow, "next slide")
            },
            Command(title: "Previous slide and note", keys: "Ctrl+Opt+Left", keyCode: kVK_LeftArrow) { [unowned self] in
                turn(by: -1); moveSlideshow(kVK_LeftArrow, "previous slide")
            },
            Command(title: "Back to the first slide and note", keys: "Ctrl+Opt+0", keyCode: kVK_ANSI_0) { [unowned self] in
                turn(by: -pageIndex); notes.flash("First note"); moveSlideshow(kVK_Home, "first slide")
            },
            Command(title: "Scroll down", keys: "Ctrl+Opt+Page Down", keyCode: kVK_PageDown) { [unowned self] in notes.scroll(pages: 1) },
            Command(title: "Scroll up", keys: "Ctrl+Opt+Page Up", keyCode: kVK_PageUp) { [unowned self] in notes.scroll(pages: -1) },
            Command(title: "Bigger text", keys: "Ctrl+Opt+Up", keyCode: kVK_UpArrow) { [unowned self] in resizeText(by: 8) },
            Command(title: "Smaller text", keys: "Ctrl+Opt+Down", keyCode: kVK_DownArrow) { [unowned self] in resizeText(by: -8) },
            Command(title: "Change text colour", keys: "Ctrl+Opt+C", keyCode: kVK_ANSI_C) { [unowned self] in
                Settings.colourIndex = (Settings.colourIndex + 1) % textColours.count
                refresh(); notes.flash(textColours[Settings.colourIndex].name)
            },
            Command(title: "Show or hide the editor", keys: "Ctrl+Opt+E", keyCode: kVK_ANSI_E) { [unowned self] in
                toggleEditor()
            },
            Command(title: "Open another notes file", keys: "Ctrl+Opt+O", keyCode: kVK_ANSI_O) { [unowned self] in chooseFile() },
            Command(title: "Follow slides on or off", keys: "Ctrl+Opt+F", keyCode: kVK_ANSI_F) { [unowned self] in
                Settings.followSlides.toggle()
                follower.forget()
                if !Settings.followSlides { noNoteForSlide = false }
                refresh()
                notes.flash(Settings.followSlides ? "Following slides" : "Not following slides")
            },
            Command(title: "Show status", keys: "Ctrl+Opt+I", keyCode: kVK_ANSI_I) { [unowned self] in showStatus() },
            Command(title: "Check notes are hidden", keys: "Ctrl+Opt+T", keyCode: kVK_ANSI_T) { [unowned self] in
                checkSharing(announce: true)
            },
            Command(title: "Show or hide help", keys: "Ctrl+Opt+H", keyCode: kVK_ANSI_H) { [unowned self] in
                showingHelp.toggle(); refresh()
            },
            Command(title: "Quit Presenter Notes", keys: "Ctrl+Opt+Shift+Q", keyCode: kVK_ANSI_Q,
                    modifiers: controlKey | optionKey | shiftKey, always: true) {
                NSApp.terminate(nil)
            },
        ]
    }

    private func register(_ command: Command) -> UInt32? {
        let id = HotKeyCenter.shared.register(keyCode: command.keyCode, modifiers: command.modifiers) { [unowned self] in
            perform(command)
        }
        if let id { hotKeyIDs["\(command.keyCode)/\(command.modifiers)"] = id }
        return id
    }

    /// Runs a command. Any shortcut clears a message. Turning the page closes the help first.
    private func perform(_ command: Command) {
        let turnsPage = [kVK_RightArrow, kVK_LeftArrow, kVK_ANSI_0].contains(command.keyCode)
        let hadHelp = showingHelp
        message = nil
        if turnsPage { showingHelp = false }
        refresh()
        // The key that closes the help should not also turn the page.
        if turnsPage, hadHelp { return }
        command.run()
    }

    private func run(_ keyCode: Int, _ modifiers: Int = AppDelegate.ctrlOpt) {
        if let command = commands.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) { perform(command) }
    }

    // MARK: Menu bar

    static let menuFont = NSFont.menuFont(ofSize: 18) // larger than the system menu text
    static let textSizes: [Double] = [48, 64, 84, 100, 120, 140, 160, 200, 240]

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Presenter Notes")
            button.imagePosition = .imageLeading
            button.title = " Notes"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func menuItem(_ title: String, checked: Bool = false, _ action: (() -> Void)? = nil) -> NSMenuItem {
        let item: NSMenuItem = action.map { ClosureMenuItem(title: title, handler: $0) }
            ?? NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [.font: AppDelegate.menuFont])
        item.state = checked ? .on : .off
        item.isEnabled = action != nil
        return item
    }

    /// The menu is rebuilt each time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === setsMenu {
            let current = store.url.standardizedFileURL.path
            for file in notesFiles() {
                let item = ClosureMenuItem(title: file.deletingPathExtension().lastPathComponent) { [unowned self] in
                    present(store.url)
                    selectFile(file)
                }
                item.state = file.standardizedFileURL.path == current ? .on : .off
                menu.addItem(item)
            }
            return
        }
        menu.addItem(menuItem("Show notes window") { [unowned self] in present(store.url) })
        menu.addItem(menuItem("Show or hide the editor") { [unowned self] in toggleEditor() })
        menu.addItem(.separator())

        menu.addItem(menuItem("Next slide and note") { [unowned self] in run(kVK_RightArrow) })
        menu.addItem(menuItem("Previous slide and note") { [unowned self] in run(kVK_LeftArrow) })
        menu.addItem(.separator())

        menu.addItem(menuItem("Bigger text") { [unowned self] in run(kVK_UpArrow) })
        menu.addItem(menuItem("Smaller text") { [unowned self] in run(kVK_DownArrow) })
        let sizes = menuItem("Text size: \(Int(Settings.fontSize))") {}
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for size in AppDelegate.textSizes {
            sizeMenu.addItem(menuItem("\(Int(size))", checked: Int(size) == Int(Settings.fontSize)) { [unowned self] in
                Settings.fontSize = size
                refresh()
                notes.flash("Text size \(Int(size))")
            })
        }
        sizes.submenu = sizeMenu
        menu.addItem(sizes)
        menu.addItem(.separator())

        menu.addItem(menuItem("Follow slides", checked: Settings.followSlides) { [unowned self] in run(kVK_ANSI_F) })
        menu.addItem(menuItem("Move the slideshow with the notes", checked: Settings.moveSlideshow) { [unowned self] in
            Settings.moveSlideshow.toggle()
            notes.flash(Settings.moveSlideshow ? "Turning a note moves the slideshow" : "Turning a note leaves the slideshow alone")
        })
        menu.addItem(.separator())

        menu.addItem(menuItem("Notes for this slideshow:"))
        let current = store.url.standardizedFileURL.path
        for file in notesFiles() {
            let name = file.deletingPathExtension().lastPathComponent
            menu.addItem(menuItem("    " + name, checked: file.standardizedFileURL.path == current) { [unowned self] in
                selectFile(file)
            })
        }
        menu.addItem(menuItem("Choose another file…") { [unowned self] in run(kVK_ANSI_O) })
        menu.addItem(menuItem("Open the notes folder") { [unowned self] in
            NSWorkspace.shared.open(store.url.deletingLastPathComponent())
        })
        menu.addItem(.separator())

        menu.addItem(menuItem("Show shortcuts") { [unowned self] in
            present(store.url)
            run(kVK_ANSI_H)
        })
        menu.addItem(menuItem("Show status") { [unowned self] in
            present(store.url)
            run(kVK_ANSI_I)
        })
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Presenter Notes") { NSApp.terminate(nil) })
    }

    // MARK: The two windows

    /// Opens the notes window with a set of notes, or brings it to the front.
    private func present(_ url: URL) {
        if url.standardizedFileURL.path != store.url.standardizedFileURL.path {
            selectFile(url)
        } else {
            follower.forget() // report the slide showing again, so the window opens on the right note
        }
        showingHelp = false
        let opening = !visible
        visible = true
        applyVisibility()
        refresh()
        notes.show()
        if !selfTest { NSApp.activate(ignoringOtherApps: true) }
        if opening {
            Log.write("notes window opened: \(store.url.lastPathComponent)")
            startedPresenting()
        }
    }

    private func notesWindowClosed() {
        visible = false
        showingHelp = false
        applyVisibility()
        Log.write("notes window closed")
    }

    // MARK: Editing

    /// Shows or hides the edit box beside the notes. Opens the notes window first if it is closed.
    private func toggleEditor() {
        if !visible {
            present(store.url)
            setEditor(true)
        } else {
            setEditor(!notes.isEditing)
        }
    }

    private func setEditor(_ on: Bool) {
        if !on { saveNow() }
        notes.setEditing(on)
        if on, !selfTest {
            NSApp.activate(ignoringOtherApps: true)
            notes.window.makeKeyAndOrderFront(nil)
        }
        refresh()
        Log.write(on ? "editor shown" : "editor hidden")
    }

    /// Typing in the edit box: the note changes in the notes beside it straight away and is saved shortly after.
    private func editorChanged(_ text: String) {
        if noNoteForSlide {
            // The slide on screen has no note yet. Typing creates one, tied to that slide.
            guard let position = lastPosition, let slide = position.slideID,
                  store.deckID == nil || store.deckID == position.deckID else {
                notes.flash("These notes belong to a different slide deck")
                return
            }
            pageIndex = store.addPage(slideID: slide, deckID: position.deckID)
            noNoteForSlide = false
            Log.write("new note for slide \(slide)")
        }
        store.setText(text, page: pageIndex)
        showingHelp = false
        unsaved = true
        refresh()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in self?.saveNow() }
    }

    private func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard unsaved else { return }
        do {
            try store.save()
            unsaved = false
        } catch {
            message = ("Could not save your notes: \(error.localizedDescription)", AppDelegate.warningColour)
            refresh()
        }
    }

    private func resizeEditor(by delta: Double) {
        Settings.editorFontSize = min(max(Settings.editorFontSize + delta, 14), 72)
        notes.setEditorFontSize(CGFloat(Settings.editorFontSize))
        notes.flash("Editor text size \(Int(Settings.editorFontSize))")
    }

    // MARK: Sets of notes

    private func newSet() {
        present(store.url)
        LargeSheet.ask(in: notes.window, title: "New set of notes",
                       message: "Give it a name, such as the name of the slideshow.",
                       field: "", actionTitle: "Create") { [weak self] answer in
            guard let self, let answer else { return }
            self.createSet(named: answer)
        }
    }

    /// Creates a set and opens it in the editor. If a deck is showing in the browser, the set is linked to it.
    @discardableResult
    private func createSet(named name: String, in folder: URL = NotesStore.defaultURL.deletingLastPathComponent()) -> URL? {
        saveNow()
        let url = NotesEditing.newFileURL(named: name, in: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try NotesEditing.starterText(deckID: lastPosition?.deckID, slideID: lastPosition?.slideID)
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            message = ("Could not create the notes: \(error.localizedDescription)", AppDelegate.warningColour)
            refresh()
            return nil
        }
        selectFile(url)
        setEditor(true)
        notes.editor.selectAll(nil) // typing replaces the starter text
        return url
    }

    private func deleteSet() {
        present(store.url)
        let url = store.url
        let name = url.deletingPathExtension().lastPathComponent
        LargeSheet.ask(in: notes.window, title: "Delete \u{201C}\(name)\u{201D}?",
                       message: "The notes move to the Trash, so you can get them back from there.",
                       actionTitle: "Delete") { [weak self] answer in
            guard let self, answer != nil else { return }
            self.saveTimer?.invalidate()
            self.unsaved = false
            do {
                try self.removeFile(url)
            } catch {
                self.message = ("Could not delete: \(error.localizedDescription)", AppDelegate.warningColour)
                self.refresh()
                return
            }
            Log.write("deleted set \(url.lastPathComponent)")
            var next = NotesStore.anyFile(near: url)
            if next == nil { // that was the last set: start again with the sample
                try? NotesStore.sample.write(to: NotesStore.defaultURL, atomically: true, encoding: .utf8)
                next = NotesStore.defaultURL
            }
            self.selectFile(next!)
            self.notes.flash("\u{201C}\(name)\u{201D} moved to the Trash")
        }
    }

    /// A normal app, with a Dock icon and a place in Cmd+Tab, while either window is open.
    /// A menu bar app the rest of the time.
    private func updateActivationPolicy() {
        let wanted: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
    }

    /// If the deleted set was the one in use, switch to another so the notes window never shows a missing file.
    private func notesFileDeleted(_ url: URL) {
        guard url.standardizedFileURL.path == store.url.standardizedFileURL.path else { return }
        if let other = NotesStore.anyFile(near: url) {
            selectFile(other)
        }
    }

    /// Once per launch, check quietly whether screen sharing can see the notes.
    private func startedPresenting() {
        guard !sharingChecked, !selfTest else { return }
        sharingChecked = true
        checkSharing(announce: false)
    }

    /// Opening the app again while it is running brings up the notes window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        present(store.url)
        return false
    }

    private func biggerText() {
        if notes.editorHasFocus { resizeEditor(by: 2) } else { run(kVK_UpArrow) }
    }

    private func smallerText() {
        if notes.editorHasFocus { resizeEditor(by: -2) } else { run(kVK_DownArrow) }
    }

    /// Menus for when the app is in front. They also make Cmd+C, Cmd+V, Cmd+F and the rest work.
    private func buildMainMenu() {
        let main = NSMenu()
        @discardableResult
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            main.addItem(top)
            return menu
        }
        func standard(_ title: String, _ action: Selector, _ key: String,
                      _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            return item
        }
        func item(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
                  _ handler: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, key: key, handler: handler)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        let arrow = { (key: Int) in String(Character(UnicodeScalar(UInt32(key))!)) }
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        add("Presenter Notes", [
            item("Hide Presenter Notes", "h") { NSApp.hide(nil) },
            .separator(),
            item("Quit Presenter Notes", "q") { NSApp.terminate(nil) },
        ])
        let openSet = NSMenuItem(title: "Open Set", action: nil, keyEquivalent: "")
        setsMenu.delegate = self
        openSet.submenu = setsMenu
        add("File", [
            item("Show Notes Window", "1") { [unowned self] in present(store.url) },
            item("Show or Hide the Editor", "e") { [unowned self] in toggleEditor() },
            .separator(),
            item("New Set of Notes…", "n") { [unowned self] in newSet() },
            openSet,
            item("Open Notes File…", "o") { [unowned self] in chooseFile() },
            item("Open the Notes Folder") { [unowned self] in NSWorkspace.shared.open(store.url.deletingLastPathComponent()) },
            .separator(),
            item("Save", "s") { [unowned self] in saveNow() },
            item("Delete This Set…") { [unowned self] in deleteSet() },
            .separator(),
            standard("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        add("Edit", [
            standard("Undo", Selector(("undo:")), "z"),
            standard("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            standard("Cut", #selector(NSText.cut(_:)), "x"),
            standard("Copy", #selector(NSText.copy(_:)), "c"),
            standard("Paste", #selector(NSText.paste(_:)), "v"),
            standard("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            standard("Find…", finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
            standard("Find Next", finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue),
            standard("Find Previous", finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue),
        ])
        add("View", [
            item("Bigger Text", "=") { [unowned self] in biggerText() },
            item("Smaller Text", "-") { [unowned self] in smallerText() },
            item("Change Text Colour") { [unowned self] in run(kVK_ANSI_C) },
            item("Show Shortcuts", "/") { [unowned self] in
                present(store.url)
                run(kVK_ANSI_H)
            },
            .separator(),
            standard("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        add("Go", [
            item("Next Note", arrow(NSRightArrowFunctionKey), [.control, .option]) { [unowned self] in run(kVK_RightArrow) },
            item("Previous Note", arrow(NSLeftArrowFunctionKey), [.control, .option]) { [unowned self] in run(kVK_LeftArrow) },
            item("First Note", "0", [.control, .option]) { [unowned self] in run(kVK_ANSI_0) },
            .separator(),
            item("Follow Slides On or Off", "f", [.control, .option]) { [unowned self] in run(kVK_ANSI_F) },
        ])
        let windows = add("Window", [
            standard("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    /// Every notes file in the notes folder and in the folder of the file in use, by name.
    private func notesFiles() -> [URL] {
        let folders = Set([NotesStore.defaultURL.deletingLastPathComponent().standardizedFileURL,
                           store.url.deletingLastPathComponent().standardizedFileURL])
        var files = folders.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }.filter { $0.pathExtension.lowercased() == "txt" }
        if !files.contains(where: { $0.standardizedFileURL.path == store.url.standardizedFileURL.path }) {
            files.append(store.url)
        }
        return files.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Switches to another notes file, from the menu or the file chooser.
    private func selectFile(_ url: URL) {
        saveNow() // typing in the set being left is written first
        store.use(url)
        pageIndex = 0
        noNoteForSlide = false
        follower.forget() // if this file belongs to the deck on screen, jump to the slide showing
        Log.write("notes file chosen: \(url.lastPathComponent), \(store.pages.count) notes")
        refresh()
        notes.flash("Notes: \(url.deletingPathExtension().lastPathComponent)")
    }

    // MARK: Keeping slide and note in step

    private func showStatus() {
        let position = lastPosition
        var lines = ["Notes: \(store.url.deletingPathExtension().lastPathComponent), \(store.pages.count) notes."]
        if !Settings.followSlides {
            lines.append("Following slides: off.")
        } else if let slide = position?.slideID {
            let linked = store.pages.contains { $0.slideID == slide }
            lines.append("Following slides: on. Slide seen: \(slide), \(linked ? "has a note" : "no note linked").")
        } else {
            lines.append("Following slides: on. No slide seen yet.")
        }
        Log.write("status: " + lines.joined(separator: " | "))
        showBriefly(lines.joined(separator: " "), colour: .white, seconds: 20)
    }

    /// Shows the note linked to the slide the browser is showing.
    private func show(_ position: SlideFollower.Position) {
        lastPosition = position
        let deckChanged = position.deckID != lastDeckSeen
        lastDeckSeen = position.deckID
        if position.deckID != store.deckID {
            // Open this deck's notes by themselves, but only when the deck in the browser has
            // just changed. A file picked by hand stays until a different deck comes up.
            if deckChanged, let file = store.file(forDeck: position.deckID) {
                store.use(file)
                Log.write("opened \(file.lastPathComponent) for the deck on screen")
                notes.flash("Notes: \(file.deletingPathExtension().lastPathComponent)")
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
        refresh()
    }

    static let keyPermissionText = "To move your slides, Presenter Notes needs permission to press keys in your browser. Open System Settings, then Privacy & Security, then Accessibility. Turn on Presenter Notes. Your notes still turn without it."

    /// Presses a key in the browser so the slideshow moves with the note.
    private func moveSlideshow(_ key: Int, _ label: String) {
        guard Settings.moveSlideshow else { return }
        if !selfTest, !AXIsProcessTrusted() {
            Log.write("cannot move the slide: no Accessibility permission")
            if !askedForKeyPermission {
                askedForKeyPermission = true
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            message = (AppDelegate.keyPermissionText, .white)
            refresh()
            return
        }
        guard let browser = sendToSlideshow(CGKeyCode(key)) else {
            Log.throttled("no-browser", every: 30, "cannot move the slide: no browser running")
            notes.flash("No browser to move the slide in")
            return
        }
        Log.write("pressed \(label) in \(browser)")
        // If the browser can report the slide and still shows the same one after the key, the key played an
        // animation or hit the end of the deck. Then the note goes back to the slide on screen.
        guard let before = lastPosition else { return }
        let pressedAt = Date()
        moveCheck += 1
        let check = moveCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, check == self.moveCheck, Settings.followSlides, self.lastPosition == before,
                  let answered = self.follower.lastAnswer, answered > pressedAt,
                  self.store.pages.contains(where: { $0.slideID != nil }) else { return }
            Log.write("the slide did not change after the key, so the note goes back to the slide on screen")
            self.show(before)
        }
    }

    private func turn(by delta: Int) {
        noNoteForSlide = false
        let last = store.pages.count - 1
        let target = pageIndex + delta
        if target < 0 { notes.flash("First note") }
        if target > last { notes.flash("Last note") }
        pageIndex = min(max(target, 0), last)
        refresh()
    }

    private func resizeText(by delta: Double) {
        Settings.fontSize = min(max(Settings.fontSize + delta, 24), 400)
        refresh()
        notes.flash("Text size \(Int(Settings.fontSize))")
    }

    private func chooseFile() {
        let open = NSOpenPanel()
        open.message = "Choose a notes file. Separate slides with a line of three dashes."
        open.directoryURL = store.url.deletingLastPathComponent()
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let chosen = open.url { selectFile(chosen) }
    }

    // MARK: Screen sharing check

    static let hiddenText = "Your notes are hidden from screen sharing. A full-screen capture taken on this Mac just now did not show them."
    static let exposedText = "Sharing your entire screen WILL show your notes. Share one window or one browser tab instead."
    static let rehearsalText = "Rehearsal mode is on, so screen sharing can see your notes. Quit and open Presenter Notes normally before you present."
    static let permissionText = "This check needs permission to capture the screen. Open System Settings, then Privacy & Security, then Screen & System Audio Recording. Turn on Presenter Notes, then quit Presenter Notes and open it again."
    static let warningColour = NSColor(red: 1.0, green: 0.45, blue: 0.35, alpha: 1)
    static let okColour = NSColor(red: 0.45, green: 1.0, blue: 0.45, alpha: 1)

    /// Takes two real full-screen captures with a different coloured square in the notes window each time.
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
        if announce { notes.window.orderFrontRegardless() } // the square must be on screen to be captured
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
                if announce { outcome = ("The check could not run. \(error.localizedDescription)", .white) }
            }
            notes.testPatch = nil
            if let outcome { message = outcome }
            refresh()
        }
    }

    /// Draws a square of the given colour in the notes window, captures the whole display the way a
    /// meeting app does, and returns the red, green and blue (0 to 255) found where the square is.
    @MainActor
    private func captureCentre(showing colour: NSColor) async throws -> [Int] {
        notes.testPatch = colour
        notes.window.displayIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)

        guard let screen = notes.window.screen ?? NSScreen.main else { throw CocoaError(.featureUnsupported) }
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

        // Centre of the square, in image pixels measured from the top left.
        let square = notes.patchFrameOnScreen
        let x = (square.midX - screen.frame.minX) * CGFloat(image.width) / screen.frame.width
        let y = (screen.frame.maxY - square.midY) * CGFloat(image.height) / screen.frame.height
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

    // MARK: Self-test

    /// `--snapshot <folder>` runs the checks, writes pictures of the notes window to a folder and quits.
    private func writeSnapshots(to folder: String) {
        func save(_ name: String) {
            guard let content = notes.window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            notes.window.displayIfNeeded()
            // A cached bitmap draws the way the screen does. A PDF drawing once hid a blank text area.
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        func press(_ keyCode: Int, _ modifiers: Int = AppDelegate.ctrlOpt) {
            guard let id = hotKeyIDs["\(keyCode)/\(modifiers)"] else { print("FAIL shortcut with key code \(keyCode) is not registered"); return }
            HotKeyCenter.shared.simulatePress(id: id)
        }
        func key(_ code: Int, _ character: Int) -> NSEvent {
            let text = String(Character(UnicodeScalar(UInt32(character))!))
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: notes.window.windowNumber, context: nil, characters: text,
                                    charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code))!
        }
        func check(_ ok: Bool, _ text: String) { print("\(ok ? "ok  " : "FAIL") \(text)") }

        let savedPage = pageIndex, savedSize = Settings.fontSize, savedPath = Settings.notesPath, realNotes = store.url
        // Keys for the slideshow are recorded, not pressed.
        var slideKeys: [CGKeyCode] = []
        let realSend = sendToSlideshow
        sendToSlideshow = { slideKeys.append($0); return "Test browser" }
        present(store.url)
        save("notes.png")
        let w = notes.window
        check(w.level == .normal, "the notes window is an ordinary window, not one that floats over other apps")
        check(w.collectionBehavior.contains(.fullScreenPrimary) && w.styleMask.contains(.resizable), "the notes window can be resized and made full screen")
        check(NSApp.activationPolicy() == .regular, "the app is in the Dock and in Cmd+Tab while the notes window is open")
        check(notes.textView.isSelectable && !notes.textView.isEditable, "the note text can be selected but not changed")
        notes.window.contentView?.layoutSubtreeIfNeeded()
        let textHeight = notes.scrollView.frame.height, windowHeight = notes.window.contentView?.bounds.height ?? 0
        check(textHeight > windowHeight * 0.6, "the note text area fills most of the window: \(Int(textHeight)) of \(Int(windowHeight)) points high")
        check(notes.textView.textContainer?.widthTracksTextView == true && !notes.textView.isHorizontallyResizable
              && !notes.scrollView.hasHorizontalScroller, "the note text wraps to the width of the window")

        // Shortcuts and the arrow keys.
        pageIndex = 0; noNoteForSlide = false; refresh()
        press(kVK_RightArrow); press(kVK_UpArrow)
        check(pageIndex == min(1, store.pages.count - 1) && Settings.fontSize == savedSize + 8,
              "Ctrl+Opt+Right and Ctrl+Opt+Up: note \(pageIndex + 1), text size \(Int(Settings.fontSize))")
        save("after-next-and-bigger.png")
        check(slideKeys == [CGKeyCode(kVK_RightArrow)], "Ctrl+Opt+Right also presses Right in the slideshow: keys \(slideKeys)")
        slideKeys = []
        press(kVK_LeftArrow); press(kVK_RightArrow)
        check(slideKeys == [CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow)], "Ctrl+Opt+Left presses Left in the slideshow: keys \(slideKeys)")
        slideKeys = []
        notes.textView.keyDown(with: key(kVK_RightArrow, NSRightArrowFunctionKey))
        notes.textView.keyDown(with: key(kVK_LeftArrow, NSLeftArrowFunctionKey))
        check(slideKeys == [CGKeyCode(kVK_RightArrow), CGKeyCode(kVK_LeftArrow)], "the arrow keys in the notes window move the slideshow too: keys \(slideKeys)")
        slideKeys = []
        Settings.moveSlideshow = false
        press(kVK_RightArrow); press(kVK_LeftArrow)
        Settings.moveSlideshow = true
        check(slideKeys.isEmpty, "with the setting off, turning a note leaves the slideshow alone")
        Settings.fontSize = savedSize; refresh()
        let before = pageIndex
        notes.textView.keyDown(with: key(kVK_LeftArrow, NSLeftArrowFunctionKey))
        check(pageIndex == max(before - 1, 0), "Left arrow key in the notes window: note \(before + 1) to \(pageIndex + 1)")
        notes.textView.keyDown(with: key(kVK_RightArrow, NSRightArrowFunctionKey))
        check(pageIndex == before, "Right arrow key in the notes window: back to note \(pageIndex + 1)")
        notes.textView.setSelectedRange(NSRange(location: 0, length: min(12, (notes.textView.string as NSString).length)))
        let selected = (notes.textView.string as NSString).substring(with: notes.textView.selectedRange())
        check(!selected.isEmpty, "text can be selected: \"\(selected)\"")
        press(kVK_ANSI_H); save("help.png")
        check(notes.pageText == "Shortcuts" && notes.textView.string.contains("Ctrl+Opt+Right"), "Ctrl+Opt+H shows the shortcuts in the window")
        press(kVK_RightArrow)
        check(!showingHelp && pageIndex == before, "the next turn closes the help without turning the page")
        message = (AppDelegate.exposedText, AppDelegate.warningColour); refresh(); save("warning.png")
        check(notes.bannerText == AppDelegate.exposedText, "a message shows in a bar at the top of the window")
        message = nil; refresh()
        notes.flash("Text size 84"); save("flash.png")

        // A note longer than one window, and a very long word.
        let long = URL(fileURLWithPath: folder).appendingPathComponent("long-note.txt")
        let paragraphs = (1...12).map { "Point \($0). This is a longer talking point that runs over more than one line of large text." }
        try? (paragraphs.joined(separator: "\n\n") + "\n---\nSecond slide.\n---\nAveryveryverylongwordwithnospacesthatmustwrapratherthanrunoffthesideofthewindow")
            .write(to: long, atomically: true, encoding: .utf8)
        store.use(long, remember: false); pageIndex = 0; refresh(); save("long-1-top.png")
        check(notes.scrollOffset == 0 && notes.maxScroll > 0, "a long note starts at the top and can scroll (\(Int(notes.maxScroll)) points more)")
        notes.textView.keyDown(with: key(kVK_DownArrow, NSDownArrowFunctionKey))
        let down = notes.scrollOffset
        check(abs(down - notes.lineHeight) < 1 && notes.lineHeight >= CGFloat(Settings.fontSize),
              "Down arrow in the window scrolls one line of text: \(Int(down)) points at text size \(Int(Settings.fontSize))")
        notes.textView.keyDown(with: key(kVK_DownArrow, NSDownArrowFunctionKey))
        notes.textView.keyDown(with: key(kVK_UpArrow, NSUpArrowFunctionKey))
        check(abs(notes.scrollOffset - down) < 1, "Up arrow in the window scrolls back one line")
        check(notes.scrollView.verticalLineScroll == notes.lineHeight, "a mouse wheel notch moves one line of text (\(Int(notes.scrollView.verticalLineScroll)) points)")
        let bigSize = Settings.fontSize
        Settings.fontSize = 240; refresh()
        check(notes.lineHeight > ceil(CGFloat(bigSize) * 1.3) || bigSize >= 240, "at text size 240 each arrow press moves further: \(Int(notes.lineHeight)) points")
        Settings.fontSize = bigSize; refresh()
        notes.scroll(points: -notes.scrollOffset)
        press(kVK_PageDown)
        let once = notes.scrollOffset
        save("long-2-down-once.png")
        for _ in 0..<1000 {
            let before = notes.scrollOffset
            press(kVK_PageDown)
            if notes.scrollOffset == before { break } // reached the end
        }
        check(once > 0 && abs(notes.scrollOffset - notes.maxScroll) < 1, "Ctrl+Opt+Page Down scrolls: \(Int(once)) after one press, \(Int(notes.scrollOffset)) at the end")
        save("long-3-end.png")
        press(kVK_PageUp)
        check(notes.scrollOffset < notes.maxScroll, "Ctrl+Opt+Page Up scrolls back")
        press(kVK_RightArrow)
        check(notes.scrollOffset == 0, "the next note starts at the top")
        press(kVK_RightArrow); save("long-word.png")
        let width = notes.textView.textContainer?.containerSize.width ?? 0
        let used = notes.textView.layoutManager?.usedRect(for: notes.textView.textContainer!).width ?? .infinity
        check(used <= width + 1, "a word wider than the window wraps (text \(Int(used)) wide, window text area \(Int(width)))")

        // Markdown: headings sized as a share of the text size, symbols hidden in the notes window.
        let markdownSample = "# Biggest heading\n### Middle heading\n##### Smallest heading\nNormal text with **bold** and *italic*.\n- A bullet point"
        let mdFile = URL(fileURLWithPath: folder).appendingPathComponent("markdown.txt")
        try? markdownSample.write(to: mdFile, atomically: true, encoding: .utf8)
        store.use(mdFile, remember: false); pageIndex = 0; noNoteForSlide = false; refresh()
        save("markdown.png")
        let shownText = notes.textView.string
        check(shownText == "Biggest heading\nMiddle heading\nSmallest heading\nNormal text with bold and italic.\n\u{2022} A bullet point",
              "the notes window hides the Markdown symbols: \(shownText.replacingOccurrences(of: "\n", with: " / "))")
        func sizeAt(_ phrase: String, in view: NSTextView) -> CGFloat {
            let at = (view.string as NSString).range(of: phrase).location
            guard at != NSNotFound, let storage = view.textStorage else { return 0 }
            return (storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
        let base = CGFloat(Settings.fontSize)
        let sizes = ["Biggest", "Middle", "Smallest", "Normal"].map { sizeAt($0, in: notes.textView) }
        check(sizes == [base * 2, base * 1.5, base * 1.15, base],
              "heading sizes at text size \(Int(base)): # \(Int(sizes[0])), ### \(Int(sizes[1])), ##### \(Int(sizes[2])), normal \(Int(sizes[3]))")
        let boldFont = notes.textView.textStorage?.attribute(.font, at: (shownText as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont
        let italicFont = notes.textView.textStorage?.attribute(.font, at: (shownText as NSString).range(of: "italic").location, effectiveRange: nil) as? NSFont
        check(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) == true && italicFont?.fontDescriptor.symbolicTraits.contains(.italic) == true,
              "**bold** and *italic* are styled")
        Settings.fontSize = base * 2; refresh()
        check(sizeAt("Biggest", in: notes.textView) == base * 4, "doubling the text size doubles the headings too")
        Settings.fontSize = Double(base); refresh()
        let colourBefore = notes.textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        check(colourBefore == textColours[min(Settings.colourIndex, textColours.count - 1)].colour, "headings use the normal text colour, no extra colours")

        // Slide following: two decks in the folder, the browser reports addresses from the first.
        let demo = URL(fileURLWithPath: folder).appendingPathComponent("demo-deck.txt")
        let other = URL(fileURLWithPath: folder).appendingPathComponent("other-deck.txt")
        try? "deck: https://docs.google.com/presentation/d/DECK-one_1/edit\n\nslide: p (Slide 1: Title)\nNote for slide one.\n---\nslide: https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.g2f_0_5\nNote for slide two.\n---\nslide: id.g3abc\nNote for slide three, linked by its slide ID."
            .write(to: demo, atomically: true, encoding: .utf8)
        try? "deck: DECK-two\n\nslide: p\nA different deck.".write(to: other, atomically: true, encoding: .utf8)
        store.use(other, remember: false)
        follower.forget()
        follower.ingest(addresses: ["https://mail.example.com/", "https://docs.google.com/presentation/d/DECK-one_1/edit?slide=id.p#slide=id.g3abc", ""])
        save("follow-slide-3.png")
        check(store.url.lastPathComponent == "demo-deck.txt" && pageIndex == 2, "deck one on screen opens its notes at slide 3: \(store.url.lastPathComponent), note \(pageIndex + 1)")
        follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.g2f_0_5"])
        check(pageIndex == 1, "slide 2 on screen: note \(pageIndex + 1)")
        press(kVK_RightArrow)
        follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.g2f_0_5"])
        check(pageIndex == 2, "a note turned by hand stays while the same slide is on screen: note \(pageIndex + 1)")
        follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.gNEW"])
        save("follow-unlinked.png")
        check(notes.pageText == "No note for this slide", "a slide with no note says so")
        press(kVK_ANSI_I); save("status.png")
        check(notes.bannerText?.hasPrefix("Notes: demo-deck") == true, "Ctrl+Opt+I shows the status in the window")
        message = nil

        // Menu bar: what it lists, and that a file picked by hand stays put.
        menuNeedsUpdate(statusItem.menu!)
        print("menu: " + statusItem.menu!.items.map { item -> String in
            if item.isSeparatorItem { return "|" }
            return (item.state == .on ? "[x] " : "") + item.title.trimmingCharacters(in: .whitespaces)
                + (item.isEnabled ? "" : " (label)") + (item.submenu.map { " > \($0.items.count) sizes" } ?? "")
        }.joined(separator: " ; "))
        func current() -> String { store.url.deletingPathExtension().lastPathComponent }
        let deckOne = "https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.g3abc"
        follower.forget(); follower.ingest(addresses: [deckOne])
        selectFile(other)
        follower.ingest(addresses: [deckOne])
        check(current() == "other-deck", "picked other-deck by hand, deck one still showing: notes file \(current())")
        follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-two/edit#slide=id.p"])
        follower.ingest(addresses: [deckOne])
        check(current() == "demo-deck" && pageIndex == 2, "browser moved to deck two and back to deck one: \(current()), note \(pageIndex + 1)")

        // The edit box: one window, shown and hidden beside the notes.
        func pump(_ seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            }
        }
        store.use(mdFile, remember: false); pageIndex = 0; noNoteForSlide = false; refresh()
        check(!notes.isEditing, "the edit box starts hidden")
        press(kVK_ANSI_E)
        notes.window.contentView?.layoutSubtreeIfNeeded()
        check(notes.isEditing && notes.editor.string == markdownSample, "Ctrl+Opt+E shows the edit box with this note's text, symbols and all")
        let editorFonts = Set((0..<(notes.editor.string as NSString).length).compactMap {
            (notes.editor.textStorage?.attribute(.font, at: $0, effectiveRange: nil) as? NSFont)?.pointSize })
        check(editorFonts == [CGFloat(Settings.editorFontSize)], "the edit box shows every line at one size: \(editorFonts.map { Int($0) })")
        let editorFrame = notes.editor.enclosingScrollView!.convert(notes.editor.enclosingScrollView!.bounds, to: nil)
        let notesFrame = notes.scrollView.convert(notes.scrollView.bounds, to: nil)
        check(editorFrame.width > 200 && notesFrame.width > 200 && editorFrame.maxX <= notesFrame.minX + 1,
              "the edit box sits to the left of the notes: \(Int(editorFrame.width)) and \(Int(notesFrame.width)) points wide")
        notes.editor.setSelectedRange(NSRange(location: (notes.editor.string as NSString).length, length: 0))
        notes.editor.insertText("\n## Typed heading", replacementRange: notes.editor.selectedRange())
        check(notes.textView.string.hasSuffix("Typed heading") && sizeAt("Typed heading", in: notes.textView) == base * 1.75,
              "typing shows straight away in the notes beside it, sized as a heading (\(Int(sizeAt("Typed heading", in: notes.textView))))")
        save("editor.png")
        pump(1.0) // saves 0.7 seconds after the last key
        check(((try? String(contentsOf: mdFile, encoding: .utf8)) ?? "") == markdownSample + "\n## Typed heading\n",
              "the note is saved by itself, as plain text with the symbols")

        // Saving one note leaves the slide lines and the other notes as they were.
        let demoBefore = (try? String(contentsOf: demo, encoding: .utf8)) ?? ""
        store.use(demo, remember: false); pageIndex = 1; noNoteForSlide = false; refresh()
        check(notes.editor.string == "Note for slide two.", "the edit box follows the note on screen: \(notes.editor.string)")
        notes.editor.setSelectedRange(NSRange(location: (notes.editor.string as NSString).length, length: 0))
        notes.editor.insertText(" Extra words.", replacementRange: notes.editor.selectedRange())
        saveNow()
        let demoAfter = (try? String(contentsOf: demo, encoding: .utf8)) ?? ""
        check(demoAfter == demoBefore.replacingOccurrences(of: "Note for slide two.", with: "Note for slide two. Extra words.")
                + (demoBefore.hasSuffix("\n") ? "" : "\n"),
              "saving one note changes only that note's text; slide lines and labels stay as written")

        // A slide with no note: typing creates one tied to that slide.
        follower.forget(); follower.ingest(addresses: ["https://docs.google.com/presentation/d/DECK-one_1/edit#slide=id.gNEW7"])
        check(noNoteForSlide && notes.editor.string.isEmpty, "a slide with no note gives an empty edit box")
        notes.editor.insertText("Brand new note", replacementRange: NSRange(location: 0, length: 0))
        saveNow()
        let withNew = (try? String(contentsOf: demo, encoding: .utf8)) ?? ""
        check(!noNoteForSlide && withNew.hasSuffix("---\nslide: gNEW7\nBrand new note\n") && store.pages[pageIndex].slideID == "gNEW7",
              "typing on a slide with no note creates a note for that slide")
        press(kVK_ANSI_E)
        check(!notes.isEditing, "Ctrl+Opt+E hides the edit box again")

        // Sets of notes: create and delete, from the File menu.
        let testFolder = URL(fileURLWithPath: folder)
        let created = createSet(named: "My talk: part 1/2", in: testFolder)
        let again = createSet(named: "My talk: part 1/2", in: testFolder)
        check(created?.lastPathComponent == "My talk- part 1-2.txt" && again?.lastPathComponent == "My talk- part 1-2 2.txt"
              && store.url == again && notes.isEditing,
              "New Set makes a file with a safe, free name and opens it in the editor: \(again?.lastPathComponent ?? "none")")
        removeFile = { try FileManager.default.removeItem(at: $0) } // nothing goes to the user's Trash
        deleteSet()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if let sheet = notes.window.attachedSheet, let content = sheet.contentView {
            func buttons(in view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) } }
            buttons(in: content).first { $0.title == "Delete" }?.performClick(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check(again.map { !FileManager.default.fileExists(atPath: $0.path) } == true && store.url != again,
                  "Delete This Set asks first, then removes the set and opens another: \(store.url.lastPathComponent)")
        } else {
            check(false, "Delete This Set asks first")
        }
        setEditor(false)

        // Mouse clicks on the app's own buttons. A press and release go to the window the way the system
        // delivers them, so the window finds the button under the pointer. (Clicks posted from outside the
        // app land in the wrong place when macOS Zoom is on, so they cannot be used here.)
        func click(_ title: String) -> Bool {
            func allButtons(in view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? allButtons(in: $0) } }
            guard let content = notes.window.contentView,
                  let button = allButtons(in: content).first(where: { $0.title == title && !$0.isHiddenOrHasHiddenAncestor }) else { return false }
            let r = button.convert(button.bounds, to: nil)
            let point = NSPoint(x: r.midX, y: r.midY)
            func mouse(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: notes.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            NSApp.postEvent(mouse(.leftMouseUp), atStart: false) // the button follows the mouse until it is let go
            notes.window.sendEvent(mouse(.leftMouseDown))
            return true
        }
        check(!notes.isEditing && click("Edit notes") && notes.isEditing, "clicking Edit notes shows the edit box")
        check(click("Hide editor") && !notes.isEditing, "clicking Hide editor hides it")
        let beforeClick = pageIndex
        check(click("Next") && pageIndex == min(beforeClick + 1, store.pages.count - 1), "clicking Next turns the note")
        check(click("Previous") && pageIndex == beforeClick, "clicking Previous turns it back")

        // Closing the notes window frees the shortcuts that turn the notes.
        store.use(long, remember: false); pageIndex = 0; refresh()
        notes.window.performClose(nil)
        press(kVK_RightArrow)
        check(!visible && contextualHotKeys.isEmpty && pageIndex == 0, "closing the notes window switches off the note shortcuts")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check(NSApp.activationPolicy() == .accessory, "with both windows closed the app goes back to the menu bar only")

        for (bundleID, browser) in SlideFollower.browsers {
            var error: NSDictionary?
            let script = NSAppleScript(source: SlideFollower.source(bundleID: bundleID, tab: browser.tab))
            let compiled = script?.compileAndReturnError(&error) ?? false
            print("script for \(browser.name): \(compiled ? "compiles" : "FAILED \(error ?? [:])")")
        }

        // Live: a real key pressed in a stand-in app while the notes window is in front, then focus comes back.
        if let pidText = ProcessInfo.processInfo.environment["PN_DRIVE_TEST"], let pid = pid_t(pidText),
           let standIn = NSRunningApplication(processIdentifier: pid) {
            sendToSlideshow = realSend
            driver.targetOverride = standIn
            present(store.url)
            NSApp.activate(ignoringOtherApps: true)
            notes.window.makeKeyAndOrderFront(nil)
            func pump(_ seconds: Double) {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until {
                    if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
                }
            }
            pump(1.0)
            print("live: notes app in front before the key: \(NSApp.isActive), accessibility permission: \(AXIsProcessTrusted())")
            fflush(stdout)
            if ProcessInfo.processInfo.environment["PN_DRIVE_HOTKEY"] != nil {
                print("READY-FOR-SHORTCUT"); fflush(stdout)
                pump(4.0) // a real Ctrl+Opt+Right is pressed from outside during this time
            } else {
                print("live: sent to \(sendToSlideshow(CGKeyCode(kVK_RightArrow)) ?? "nothing")")
                pump(1.5)
            }
            print("live: notes app in front again afterwards: \(NSApp.isActive)")
            fflush(stdout)
            driver.targetOverride = nil
        }

        // Leave the user's settings as they were.
        store.use(realNotes, remember: false)
        Settings.notesPath = savedPath
        Settings.fontSize = savedSize
        Settings.pageIndex = savedPage
        NSApp.terminate(nil)
    }

    // MARK: State to screen

    private func applyVisibility() {
        if visible {
            if contextualHotKeys.isEmpty {
                for command in commands where !command.always {
                    if let id = register(command) { contextualHotKeys.append(id) } else { blockedShortcuts.append(command.keys) }
                }
            }
            if !blockedShortcuts.isEmpty {
                message = ("These shortcuts are in use by another app, so they will not work: "
                           + blockedShortcuts.joined(separator: ", "), .white)
                blockedShortcuts.removeAll()
            }
            follower.forget()
        } else {
            contextualHotKeys.forEach(HotKeyCenter.shared.unregister)
            contextualHotKeys.removeAll()
        }
        updateActivationPolicy()
    }

    private func refresh() {
        pageIndex = min(max(pageIndex, 0), store.pages.count - 1)
        Settings.pageIndex = pageIndex
        guard let notes else { return }
        let fontSize = CGFloat(Settings.fontSize)
        if showingHelp {
            let size = max(28, min(fontSize * 0.5, 60))
            notes.render(text: commands.map { "\($0.keys)\t\($0.title)" }.joined(separator: "\n")
                            + "\n\nIn this window the Right and Left arrow keys also turn the notes.",
                         size: size, colour: .white, tabStop: size * 9.5, markdown: false)
            notes.setLabels(name: store.url.deletingPathExtension().lastPathComponent, page: "Shortcuts")
        } else {
            notes.render(text: noNoteForSlide ? "" : store.pages[pageIndex].text, size: fontSize,
                         colour: textColours[min(Settings.colourIndex, textColours.count - 1)].colour,
                         pageKey: "\(store.url.path)#\(pageIndex)#\(noNoteForSlide)")
            notes.setLabels(name: store.url.deletingPathExtension().lastPathComponent,
                            page: noNoteForSlide ? "No note for this slide" : "Note \(pageIndex + 1) of \(store.pages.count)")
        }
        notes.message = message
        if notes.isEditing {
            // The edit box holds the note showing beside it, as plain text.
            let title = noNoteForSlide
                ? "New note for this slide"
                : "Note \(pageIndex + 1) of \(store.pages.count)" + (store.pages[pageIndex].slideID.map { ", slide \($0)" } ?? "")
            notes.loadEditor(noNoteForSlide ? "" : store.pages[pageIndex].text, title: title)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // becomes a Dock app once a window opens
app.run()
