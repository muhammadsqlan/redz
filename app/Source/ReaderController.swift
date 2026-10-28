import AppKit
import WebKit
import AVFoundation
import UniformTypeIdentifiers
import PDFKit

struct SpeechWord {
    let index: Int
    let start: Int
    let length: Int
}
struct SpeechUnit {
    let text: String
    let words: [SpeechWord]
}
enum PlaybackState: String { case idle, preparing, playing, paused }
enum ReaderAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var native: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ReaderChromeView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

@MainActor
final class ReaderController: NSObject, WKScriptMessageHandler, WKNavigationDelegate, AVAudioPlayerDelegate, NSWindowDelegate {
    let window: NSWindow
    let webView: WKWebView
    let library: URL
    let defaults: UserDefaults
    let testing: Bool
    let pdfImporter = PDFImporter()
    let pdfView = PDFView()
    private(set) var showingOriginal = false
    private var originalPageOnEntry = 0
    private var sourcePage = 1
    private var bookOpenGeneration = UUID()
    private var importingPDF = false
    private var exportMenuItem: NSMenuItem?
    var isPDF: Bool { book?.source.pathExtension.lowercased() == "pdf" }
    private let readerScript: String
    private(set) var renderedTheme = ""
    private var renderedPalette: [String: String] = [:]
    var appearanceMode: ReaderAppearance { ReaderAppearance(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system }
    var book: EPUBBook?
    var chapterIndex = 0
    var pageIndex = 0
    var pageCount = 1
    var ready = false
    var playback: PlaybackState = .idle
    var units: [SpeechUnit] = []
    var unitIndex = 0
    var currentWord = -1
    var audioPlayer: AVAudioPlayer?
    var audioWords: [AudioWord] = []
    var audioWordCursor = -1
    var audioCache: [Int: NeuralAudio] = [:]
    var audioRequests: Set<Int> = []
    var speechTimer: Timer?
    var generation = UUID()
    var pendingRestore = -1
    var pendingAnchor = ""
    var continueOnLoad = false
    var previousPageOnLoad = false
    var sentenceNavigation: UUID?
    var sentenceMoves: [Int] = []
    var pendingSentenceEdge: Int?
    var speechCallbacks = 0
    var finishCallbacks = 0
    var onReady: (() -> Void)?
    let speech = NeuralSpeech()
    let playButton = NSButton(title: "Play", target: nil, action: nil)
    let restartButton = NSButton()
    let previousButton = NSButton()
    let nextButton = NSButton()
    let previousSentenceButton = NSButton()
    let nextSentenceButton = NSButton()
    let openButton = NSButton()
    let originalButton = NSButton(title: "Original", target: nil, action: nil)
    let smallerButton = NSButton()
    let largerButton = NSButton()
    let contentsButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let speedButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let voiceButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let appearanceButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let titleLabel = NSTextField(labelWithString: "ReDZ")
    let pageLabel = NSTextField(labelWithString: "")
    let activity = NSProgressIndicator()
    var voices: [ReadingVoice] = []
    var fontSize: Int
    var keyMonitor: Any?

    init(library: URL, testing: Bool = false, preferences: UserDefaults? = nil) throws {
        self.library = library
        self.testing = testing
        // Keep existing ReadAlong settings without moving or rewriting the old library.
        self.defaults = preferences ?? (testing ? UserDefaults(suiteName: "com.muhammadsqlan.redz.tests.\(UUID().uuidString)")! : UserDefaults(suiteName: "com.local.ReadAlong")!)
        self.fontSize = defaults.integer(forKey: "fontSize") == 0 ? 21 : defaults.integer(forKey: "fontSize")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        guard let scriptURL = Bundle.main.url(forResource: "Reader", withExtension: "js") else { throw ReaderError(message: "Missing reader resource.") }
        readerScript = try String(contentsOf: scriptURL, encoding: .utf8)
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        config.userContentController.add(self, contentWorld: .defaultClient, name: "reader")
        webView.navigationDelegate = self
        window.delegate = self
        window.title = "ReDZ"
        window.appearance = appearanceMode.native
        window.minSize = NSSize(width: 760, height: 520)
        if !testing { window.setFrameAutosaveName("ReaderWindow") }
        window.center()
        window.isReleasedWhenClosed = false
        makeInterface()
        refreshAppearance()
        makeMenus()
        loadVoices()
        try? speech.start()
        updateControls()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.window == self.window, event.modifierFlags.intersection([.command,.control,.option]).isEmpty, !(self.window.firstResponder is NSTextView) else { return event }
            return self.handleReadingKey(event.keyCode) ? nil : event
        }
    }

    private func symbolButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.target = self; button.action = action; button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 38).isActive = true
    }

    private func makeInterface() {
        let root = ReaderChromeView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in self?.refreshAppearance() }
        window.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 0; stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor), stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let header = NSStackView(); header.orientation = .horizontal; header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 10, right: 20)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        contentsButton.target = self; contentsButton.action = #selector(contentsChanged)
        contentsButton.setAccessibilityLabel("Contents"); contentsButton.toolTip = "Contents"
        contentsButton.widthAnchor.constraint(lessThanOrEqualToConstant: 350).isActive = true
        appearanceButton.addItems(withTitles: ReaderAppearance.allCases.map { $0.title })
        appearanceButton.selectItem(at: ReaderAppearance.allCases.firstIndex(of: appearanceMode) ?? 0)
        appearanceButton.target = self; appearanceButton.action = #selector(appearanceChanged)
        appearanceButton.setAccessibilityLabel("Appearance"); appearanceButton.toolTip = "Appearance"
        appearanceButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        symbolButton(openButton, symbol: "folder", label: "Open EPUB or PDF", action: #selector(openEPUB))
        originalButton.bezelStyle = .rounded; originalButton.target = self; originalButton.action = #selector(toggleOriginal)
        originalButton.setAccessibilityLabel("Original PDF"); originalButton.isHidden = true
        header.addArrangedSubview(titleLabel); header.addArrangedSubview(NSView()); header.addArrangedSubview(contentsButton); header.addArrangedSubview(originalButton); header.addArrangedSubview(appearanceButton); header.addArrangedSubview(openButton)
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 12, right: 20)
        symbolButton(previousButton, symbol: "chevron.left", label: "Previous page", action: #selector(previousPage))
        symbolButton(nextButton, symbol: "chevron.right", label: "Next page", action: #selector(nextPage))
        symbolButton(previousSentenceButton, symbol: "arrow.up", label: "Previous sentence · ↑", action: #selector(previousSentence))
        symbolButton(nextSentenceButton, symbol: "arrow.down", label: "Next sentence · ↓", action: #selector(nextSentence))
        playButton.bezelStyle = .rounded; playButton.target = self; playButton.action = #selector(togglePlayback)
        playButton.widthAnchor.constraint(equalToConstant: 104).isActive = true
        playButton.toolTip = "Play / Pause · Space"
        symbolButton(restartButton, symbol: "arrow.counterclockwise", label: "Read page from the top", action: #selector(restartPage))
        speedButton.addItems(withTitles: ["0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×"])
        speedButton.selectItem(at: defaults.object(forKey: "speedIndex") == nil ? 1 : defaults.integer(forKey: "speedIndex"))
        speedButton.target = self; speedButton.action = #selector(speedChanged); speedButton.setAccessibilityLabel("Speed")
        voiceButton.target = self; voiceButton.action = #selector(voiceChanged); voiceButton.setAccessibilityLabel("Voice")
        voiceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        symbolButton(smallerButton, symbol: "textformat.size.smaller", label: "Smaller text", action: #selector(smallerText))
        symbolButton(largerButton, symbol: "textformat.size.larger", label: "Larger text", action: #selector(largerText))
        for view in [previousButton, nextButton, previousSentenceButton, nextSentenceButton, playButton, restartButton, speedButton, voiceButton] as [NSView] { controls.addArrangedSubview(view) }
        controls.addArrangedSubview(NSView()); controls.addArrangedSubview(smallerButton); controls.addArrangedSubview(largerButton)
        stack.addArrangedSubview(controls); controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let line = NSBox(); line.boxType = .separator; stack.addArrangedSubview(line); line.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let readingArea = NSView()
        stack.addArrangedSubview(readingArea); readingArea.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        readingArea.setContentHuggingPriority(.defaultLow, for: .vertical)
        pdfView.autoScales = true; pdfView.displayMode = .singlePageContinuous; pdfView.isHidden = true
        for view in [webView, pdfView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false; readingArea.addSubview(view)
            NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: readingArea.leadingAnchor), view.trailingAnchor.constraint(equalTo: readingArea.trailingAnchor), view.topAnchor.constraint(equalTo: readingArea.topAnchor), view.bottomAnchor.constraint(equalTo: readingArea.bottomAnchor)])
        }
        let footer = NSStackView(); footer.orientation = .horizontal; footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 10, right: 20)
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); pageLabel.textColor = .secondaryLabelColor
        pageLabel.lineBreakMode = .byTruncatingTail
        activity.style = .spinning; activity.controlSize = .small; activity.isDisplayedWhenStopped = false
        footer.addArrangedSubview(pageLabel); footer.addArrangedSubview(NSView()); footer.addArrangedSubview(activity)
        stack.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @objc func appearanceChanged() {
        guard ReaderAppearance.allCases.indices.contains(appearanceButton.indexOfSelectedItem) else { return }
        setAppearance(ReaderAppearance.allCases[appearanceButton.indexOfSelectedItem])
    }

    func setAppearance(_ mode: ReaderAppearance) {
        defaults.set(mode.rawValue, forKey: "appearanceMode")
        window.appearance = mode.native
        refreshAppearance()
    }

    private func refreshAppearance() {
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        func resolved(_ color: NSColor) -> NSColor {
            var result = color
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB) ?? color
            }
            return result
        }
        let paper = dark ? resolved(.textBackgroundColor) : NSColor(srgbRed: 250/255, green: 249/255, blue: 245/255, alpha: 1)
        let chrome = dark ? resolved(.windowBackgroundColor) : paper
        func hex(_ color: NSColor) -> String {
            let rgb = resolved(color), alpha = rgb.alphaComponent
            let components = [rgb.redComponent * alpha + paper.redComponent * (1 - alpha),
                              rgb.greenComponent * alpha + paper.greenComponent * (1 - alpha),
                              rgb.blueComponent * alpha + paper.blueComponent * (1 - alpha)]
            return "#" + components.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
        }
        let palette: [String: String] = dark ? [
            "paper": hex(paper), "ink": hex(.labelColor), "accent": hex(.linkColor),
            "highlight": hex(.selectedTextBackgroundColor), "highlight-ink": hex(.selectedTextColor),
            "muted": hex(.secondaryLabelColor), "border": hex(.separatorColor)
        ] : [:]
        window.backgroundColor = paper
        window.contentView?.layer?.backgroundColor = chrome.cgColor
        webView.underPageBackgroundColor = paper
        pdfView.backgroundColor = chrome
        appearanceButton.selectItem(at: ReaderAppearance.allCases.firstIndex(of: appearanceMode) ?? 0)
        let theme = dark ? "dark" : "light"
        guard theme != renderedTheme || palette != renderedPalette else { return }
        renderedTheme = theme
        renderedPalette = palette
        // Prepare the next chapter before its first paint. The current chapter
        // only changes colors, preserving its page, highlight, zoom, and audio.
        let bootstrap = """
        window.readAlongTheme = \(json(theme));
        window.readAlongDarkPalette = \(json(palette));
        if (document.documentElement) {
            document.documentElement.dataset.readerTheme = window.readAlongTheme;
            for (const [key, value] of Object.entries(window.readAlongDarkPalette)) {
                document.documentElement.style.setProperty('--' + key, value);
            }
            document.documentElement.style.backgroundColor = \(json(dark ? palette["paper"]! : "#faf9f5"));
            document.documentElement.style.colorScheme = window.readAlongTheme;
        }
        """
        let scripts = webView.configuration.userContentController
        scripts.removeAllUserScripts()
        scripts.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        scripts.addUserScript(WKUserScript(source: readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        if ready { evaluate("Reader.setTheme(\(json(theme)), \(json(palette)))") }
    }

    private func makeMenus() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app); app.submenu = NSMenu()
        let quit = NSMenuItem(title: "Quit ReDZ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); app.submenu?.addItem(quit)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""); menu.addItem(file); file.submenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open…", action: #selector(openEPUB), keyEquivalent: "o"); open.target = self; file.submenu?.addItem(open)
        let export = NSMenuItem(title: "Export EPUB…", action: #selector(exportEPUB), keyEquivalent: "e"); export.target = self; export.isEnabled = false; file.submenu?.addItem(export)
        file.submenu?.autoenablesItems = false; exportMenuItem = export
        let reading = NSMenuItem(title: "Reading", action: nil, keyEquivalent: ""); menu.addItem(reading); reading.submenu = NSMenu(title: "Reading")
        for (title, selector, key) in [("Play / Pause", #selector(togglePlayback), " "), ("Read Page from Top", #selector(restartPage), "r"), ("Previous Page", #selector(previousPage), "["), ("Next Page", #selector(nextPage), "]")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self
            if key == " " { item.keyEquivalentModifierMask = [] }
            reading.submenu?.addItem(item)
        }
        let windowMenu = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); menu.addItem(windowMenu); windowMenu.submenu = NSMenu(title: "Window")
        let minimize = NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"); windowMenu.submenu?.addItem(minimize)
        NSApp.windowsMenu = windowMenu.submenu; NSApp.mainMenu = menu
    }

    private func loadVoices() {
        voices = ReadingVoice.catalog
        voiceButton.removeAllItems()
        for voice in voices { voiceButton.addItem(withTitle: "\(voice.name) · \(voice.gender)"); voiceButton.lastItem?.representedObject = voice.identifier }
        let selected = defaults.string(forKey: "voiceID")
        let index = voices.firstIndex(where: { $0.identifier == selected }) ?? 0
        if !voices.isEmpty { voiceButton.selectItem(at: index) }
        defaults.set(voices[index].identifier, forKey: "voiceID")
    }

    func openBook(_ url: URL) {
        pdfImporter.cancel(); bookOpenGeneration = UUID()
        importingPDF = url.pathExtension.lowercased() == "pdf"
        showingOriginal = false; pdfView.isHidden = true; webView.isHidden = false; pdfView.document = nil
        originalButton.isHidden = true; originalButton.title = "Original"
        exportMenuItem?.isEnabled = false
        stopPlayback(); ready = false; updateControls(); activity.startAnimation(nil)
        if url.pathExtension.lowercased() == "pdf" {
            let token = bookOpenGeneration
            pageLabel.stringValue = "Opening PDF…"
            pdfImporter.open(url, library: library, progress: { [weak self] page, total in
                guard let self, self.bookOpenGeneration == token else { return }
                self.pageLabel.stringValue = "Opening PDF · \(page) / \(total)"
            }, completion: { [weak self] result in
                guard let self, self.bookOpenGeneration == token else { return }
                switch result {
                case .success(let loaded): self.displayBook(loaded)
                case .failure(let error): self.importingPDF = false; self.showError(error.localizedDescription)
                }
            })
            return
        }
        do {
            let loaded = try EPUBBook.open(url, library: library)
            displayBook(loaded)
        } catch { showError(error.localizedDescription) }
    }

    private func displayBook(_ loaded: EPUBBook) {
            importingPDF = false
            let url = loaded.source
            book = loaded; titleLabel.stringValue = loaded.title; window.title = loaded.title + " — ReDZ"
            originalButton.isHidden = !isPDF; exportMenuItem?.isEnabled = isPDF
            defaults.set(url.path, forKey: "lastBook")
            contentsButton.removeAllItems()
            for entry in loaded.contents { contentsButton.addItem(withTitle: entry.title); contentsButton.lastItem?.indentationLevel = min(3, entry.depth) }
            let prefix = "position." + url.path
            let savedChapter = defaults.object(forKey: prefix + ".chapter") as? Int
            let index = savedChapter.flatMap { loaded.chapters.indices.contains($0) ? $0 : nil } ?? loaded.initialChapter
            let word = defaults.object(forKey: prefix + ".word") as? Int ?? -1
            loadChapter(index, restoreWord: word)
    }

    func loadChapter(_ index: Int, restoreWord: Int = -1, anchor: String = "", autoplay: Bool = false, lastPage: Bool = false, sentenceEdge: Int? = nil) {
        guard let book = book, book.chapters.indices.contains(index) else { return }
        stopPlayback(cancelSentenceNavigation: sentenceEdge == nil); ready = false; chapterIndex = index; pageIndex = 0; pageCount = 1
        pendingSentenceEdge = sentenceEdge
        pendingRestore = restoreWord; pendingAnchor = anchor; continueOnLoad = autoplay; previousPageOnLoad = lastPage
        activity.startAnimation(nil); updateControls()
        let entry = book.contents.firstIndex(where: { $0.chapter == index && $0.anchor.isEmpty }) ?? book.contents.firstIndex(where: { $0.chapter == index })
        if let entry = entry { contentsButton.selectItem(at: entry) }
        webView.loadFileURL(book.chapters[index].url, allowingReadAccessTo: book.root)
    }

    func evaluate(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            switch result { case .success(let value): completion?(value, nil); case .failure(let error): completion?(nil, error) }
        }
    }

    func updateControls() {
        playButton.title = playback == .playing ? "Pause" : playback == .paused ? "Resume" : "Play"
        playButton.image = NSImage(systemSymbolName: playback == .playing ? "pause.fill" : "play.fill", accessibilityDescription: playButton.title)
        playButton.imagePosition = .imageLeading
        playButton.isEnabled = ready && playback != .preparing && !showingOriginal
        restartButton.isEnabled = ready && !showingOriginal
        previousSentenceButton.isEnabled = (ready || sentenceNavigation != nil) && !showingOriginal
        nextSentenceButton.isEnabled = (ready || sentenceNavigation != nil) && !showingOriginal
        previousButton.isEnabled = ready && (pageIndex > 0 || chapterIndex > 0)
        nextButton.isEnabled = ready && (pageIndex < pageCount - 1 || chapterIndex < (book?.chapters.count ?? 1) - 1)
        contentsButton.isEnabled = ready && !showingOriginal
        originalButton.isEnabled = ready
        smallerButton.isEnabled = !showingOriginal; largerButton.isEnabled = !showingOriginal
        if showingOriginal { previousButton.isEnabled = false; nextButton.isEnabled = false }
        speedButton.isEnabled = !voices.isEmpty; voiceButton.isEnabled = !voices.isEmpty
        if let book = book { pageLabel.stringValue = isPDF ? "PDF \(sourcePage)   ·   \(pageIndex + 1) / \(pageCount)" : "\(book.chapters[chapterIndex].title)   ·   \(pageIndex + 1) / \(pageCount)" }
    }

    @objc func togglePlayback() {
        guard ready, !showingOriginal else { return }
        if playback == .playing { pausePlayback(); return }
        if playback == .paused {
            resumeSentence()
            return
        }
        evaluate("Reader.closeZoom(); Reader.topWord()") { [weak self] value, _ in
            guard let self = self else { return }
            self.startReading(at: (value as? Int) ?? -1)
        }
    }

    func startReading(at word: Int, paused: Bool = false, clearHighlight: Bool = true) {
        stopPlayback(clearHighlight: clearHighlight); currentWord = word; playback = .preparing; updateControls()
        let token = generation
        evaluate("Reader.highlight(\(word)); Reader.plan(\(word))") { [weak self] value, error in
            guard let self = self, self.generation == token else { return }
            if let error = error { self.showError(error.localizedDescription); return }
            self.units = self.parseUnits(value)
            self.unitIndex = 0
            self.currentWord = word
            if self.units.isEmpty {
                self.playback = .idle; self.updateControls()
                if let book = self.book, self.chapterIndex + 1 < book.chapters.count { self.loadChapter(self.chapterIndex + 1, autoplay: true) }
                return
            }
            self.playback = paused ? .paused : .playing; self.updateControls()
            if !paused { self.speakNext() }
        }
    }

    func parseUnits(_ value: Any?) -> [SpeechUnit] {
        ((value as? [[String: Any]]) ?? []).compactMap { unit in
            guard let text = unit["text"] as? String, let raw = unit["words"] as? [[String: Any]], !text.isEmpty else { return nil }
            let words = raw.compactMap { item -> SpeechWord? in
                guard let i = item["index"] as? Int, let start = item["start"] as? Int, let length = item["length"] as? Int else { return nil }
                return SpeechWord(index: i, start: start, length: length)
            }
            return SpeechUnit(text: text, words: words)
        }
    }

    func prepareNearby(at word: Int? = nil) {
        guard ready, voices.indices.contains(voiceButton.indexOfSelectedItem) else { return }
        let token = generation, voice = voices[voiceButton.indexOfSelectedItem], speed = Double(selectedSpeed)
        let location = word.map(String.init) ?? "Reader.topWord()"
        evaluate("Reader.nearby(\(location))") { [weak self] value, _ in
            guard let self = self, self.generation == token, self.ready else { return }
            for unit in self.parseUnits(value) {
                self.speech.request(unit, voice: voice, speed: speed, priority: .background) { _ in }
            }
        }
    }

    func resumeSentence() {
        let token = generation
        evaluate("Reader.closeZoom(); Reader.sentenceStart(\(currentWord))") { [weak self] value, _ in
            guard let self = self, self.generation == token, self.playback == .paused, let start = value as? Int, start >= 0 else { return }
            if let player = self.audioPlayer, self.units.indices.contains(self.unitIndex), self.units[self.unitIndex].words.first?.index == start {
                player.currentTime = 0; self.audioWordCursor = -1; self.currentWord = start
                self.playback = .playing; self.evaluate("Reader.highlight(\(start))")
                player.play(); self.updateSpokenPosition(); self.updateControls(); self.savePosition(word: start)
            } else {
                // Page-start and word-seek audio may contain only part of the sentence.
                self.startReading(at: start, clearHighlight: false)
            }
        }
    }

    @discardableResult
    func handleReadingKey(_ keyCode: UInt16) -> Bool {
        guard !showingOriginal else { return false }
        switch keyCode {
        case 49: togglePlayback()
        case 123: turnPage(-1)
        case 124: turnPage(1)
        case 125: moveSentence(1)
        case 126: moveSentence(-1)
        default: return false
        }
        return true
    }

    @objc func previousSentence() { moveSentence(-1) }
    @objc func nextSentence() { moveSentence(1) }

    func moveSentence(_ delta: Int) {
        guard ready || sentenceNavigation != nil else { return }
        let starting = sentenceNavigation == nil
        if starting {
            stopPlayback(clearHighlight: false)
            sentenceNavigation = UUID()
        }
        sentenceMoves.append(delta)
        if starting { advanceSentenceMoves() }
    }

    private func advanceSentenceMoves() {
        guard ready, let token = sentenceNavigation, !sentenceMoves.isEmpty else { return }
        let delta = sentenceMoves.removeFirst()
        evaluate("Reader.closeZoom(); Reader.moveSentence(\(delta))") { [weak self] value, _ in
            guard let self = self, self.sentenceNavigation == token, let result = value as? [String: Any] else { return }
            let word = result["word"] as? Int ?? -1
            let boundary = result["boundary"] as? Int ?? 0
            if boundary != 0, self.loadSentenceChapter(boundary) { return }
            self.completeSentenceMove(at: word)
        }
    }

    private func loadSentenceChapter(_ direction: Int) -> Bool {
        guard let book = book, book.chapters.indices.contains(chapterIndex + direction) else { return false }
        loadChapter(chapterIndex + direction, sentenceEdge: direction)
        return true
    }

    private func completeSentenceMove(at word: Int) {
        guard sentenceNavigation != nil else { return }
        currentWord = word; savePosition(word: word)
        if !sentenceMoves.isEmpty { advanceSentenceMoves() }
        else {
            sentenceNavigation = nil
            if word >= 0 { startReading(at: word, clearHighlight: false) }
            else { stopPlayback() }
        }
    }

    func speakNext() {
        guard playback == .playing else { return }
        guard unitIndex < units.count else {
            audioPlayer = nil; units = []; playback = .idle; updateControls()
            if let book = book, chapterIndex + 1 < book.chapters.count { loadChapter(chapterIndex + 1, autoplay: true) }
            return
        }
        guard audioPlayer == nil else { return }
        if let audio = audioCache.removeValue(forKey: unitIndex) {
            do {
                let player = try AVAudioPlayer(data: audio.data)
                player.delegate = self; player.volume = testing ? 0 : 1
                audioPlayer = player; audioWords = audio.words; audioWordCursor = -1
                // The WAV already contains the selected tempo. Bypass Apple's
                // live time/pitch processor at every speed, including resume.
                player.enableRate = false
                player.rate = 1
                player.prepareToPlay()
                if playback == .playing { player.play(); updateSpokenPosition() }
                speechTimer?.invalidate()
                speechTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateSpokenPosition() }
                }
                requestAudio(at: unitIndex + 1)
                prepareNearby(at: audio.words.first?.index)
            } catch { speechFailed(error) }
        } else { requestAudio(at: unitIndex); requestAudio(at: unitIndex + 1) }
    }

    func requestAudio(at index: Int) {
        guard units.indices.contains(index), audioCache[index] == nil, !audioRequests.contains(index) else { return }
        let token = generation
        audioRequests.insert(index)
        speech.request(units[index], voice: voices[voiceButton.indexOfSelectedItem], speed: Double(selectedSpeed), priority: index == unitIndex ? .foreground : .background) { [weak self] result in
            guard let self = self, self.generation == token else { return }
            self.audioRequests.remove(index)
            switch result {
            case .success(let audio):
                self.audioCache[index] = audio
                if self.unitIndex == index && self.playback == .playing && self.audioPlayer == nil { self.speakNext() }
            case .failure(let error): self.speechFailed(error)
            }
        }
    }

    func updateSpokenPosition() {
        guard playback == .playing, let player = audioPlayer, !audioWords.isEmpty else { return }
        let cursor = audioWords.lastIndex(where: { $0.start <= player.currentTime }) ?? 0
        guard cursor != audioWordCursor else { return }
        audioWordCursor = cursor
        let word = audioWords[cursor].index
        currentWord = word; speechCallbacks += 1
        evaluate("Reader.highlight(\(word))")
        savePosition(word: word)
    }

    var selectedSpeed: Float {
        let multipliers: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]
        return multipliers[min(multipliers.count - 1, max(0, speedButton.indexOfSelectedItem))]
    }

    private func speechFailed(_ error: Error) {
        stopPlayback(); pageLabel.stringValue = "Voice unavailable"
        if testing { print("SPEECH_ERROR: \(error.localizedDescription)"); fflush(stdout) }
    }

    func pausePlayback() {
        guard playback == .playing else { return }
        playback = .paused
        audioPlayer?.pause()
        updateControls(); savePosition(word: currentWord)
    }

    func stopPlayback(clearHighlight: Bool = true, cancelSentenceNavigation: Bool = true) {
        generation = UUID(); audioPlayer?.stop(); audioPlayer = nil; units = []; unitIndex = 0; playback = .idle
        audioWords = []; audioCache = [:]; audioRequests = []; audioWordCursor = -1
        speechTimer?.invalidate(); speechTimer = nil; speech.cancel()
        if cancelSentenceNavigation { sentenceNavigation = nil; sentenceMoves = []; pendingSentenceEdge = nil }
        if clearHighlight && ready { evaluate("Reader.clearHighlight()") }
        updateControls()
    }

    @objc func restartPage() {
        stopPlayback()
        evaluate("Reader.closeZoom(); Reader.topWord()") { [weak self] value, _ in self?.startReading(at: (value as? Int) ?? -1) }
    }
    @objc func previousPage() { turnPage(-1) }
    @objc func nextPage() { turnPage(1) }
    func turnPage(_ delta: Int) {
        guard ready else { return }
        stopPlayback()
        evaluate("Reader.closeZoom(); Reader.navigate(\(delta))")
    }
    @objc func contentsChanged() {
        guard let book = book, book.contents.indices.contains(contentsButton.indexOfSelectedItem) else { return }
        let entry = book.contents[contentsButton.indexOfSelectedItem]
        loadChapter(entry.chapter, anchor: entry.anchor)
    }
    @objc func openEPUB() {
        pausePlayback()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data, .pdf]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK, let url = panel.url { self?.openBook(url) } }
    }

    @objc func toggleOriginal() {
        guard ready, isPDF, let book else { return }
        if showingOriginal {
            let selected = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? originalPageOnEntry
            showingOriginal = false; pdfView.isHidden = true; webView.isHidden = false; originalButton.title = "Original"; originalButton.setAccessibilityLabel("Original PDF")
            if selected != originalPageOnEntry { stopPlayback(); evaluate("Reader.goAnchor(\(json("pdf-page-\(selected + 1)")))") }
            updateControls()
        } else {
            pausePlayback()
            evaluate("Reader.sourcePage()") { [weak self] value, _ in
                guard let self, self.ready, self.book?.source == book.source else { return }
                if self.pdfView.document == nil { self.pdfView.document = PDFDocument(url: book.root.appendingPathComponent("original.pdf")) }
                guard let document = self.pdfView.document else { self.showError("Couldn’t display the original PDF."); return }
                self.originalPageOnEntry = max(0, min(document.pageCount - 1, (value as? Int ?? 1) - 1))
                self.showingOriginal = true; self.pdfView.isHidden = false; self.webView.isHidden = true; self.originalButton.title = "Reading"; self.originalButton.setAccessibilityLabel("Reading view")
                self.window.contentView?.layoutSubtreeIfNeeded()
                if let page = document.page(at: self.originalPageOnEntry) { self.pdfView.go(to: page) }
                self.updateControls()
            }
        }
    }

    @objc func exportEPUB() {
        guard isPDF, let book else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.nameFieldStringValue = book.source.deletingPathExtension().lastPathComponent + ".epub"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                // copyItem refuses to replace an existing file.
                try FileManager.default.copyItem(at: book.root.appendingPathComponent("Reading.epub"), to: destination)
            } catch { self?.pageLabel.stringValue = "Choose a new filename for export." }
        }
    }
    @objc func speedChanged() { defaults.set(speedButton.indexOfSelectedItem, forKey: "speedIndex"); applySpeechPreference() }
    @objc func voiceChanged() { if voices.indices.contains(voiceButton.indexOfSelectedItem) { defaults.set(voices[voiceButton.indexOfSelectedItem].identifier, forKey: "voiceID") }; applySpeechPreference() }
    func applySpeechPreference() {
        let previous = playback
        if previous == .playing || previous == .paused { startReading(at: max(0, currentWord), paused: previous == .paused) }
        else { prepareNearby() }
    }
    @objc func smallerText() { setFont(max(15, fontSize - 2)) }
    @objc func largerText() { setFont(min(35, fontSize + 2)) }
    func setFont(_ size: Int) { fontSize = size; defaults.set(size, forKey: "fontSize"); evaluate("Reader.setFont(\(size))") }

    func savePosition(word: Int) {
        guard let book = book, word >= 0 else { return }
        let prefix = "position." + book.source.path
        defaults.set(chapterIndex, forKey: prefix + ".chapter"); defaults.set(word, forKey: prefix + ".word")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !importingPDF, message.frameInfo.isMainFrame, let data = message.body as? [String: Any], let type = data["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true; pageCount = data["pages"] as? Int ?? 1; activity.stopAnimation(nil)
            var script = "Reader.setTheme(\(json(renderedTheme)), \(json(renderedPalette))); Reader.setFont(\(fontSize));"
            if previousPageOnLoad { script += "Reader.setPage(Reader.state().pages-1);" }
            else if !pendingAnchor.isEmpty { script += "Reader.goAnchor(\(json(pendingAnchor)));" }
            else if pendingRestore >= 0 { script += "Reader.restore(\(pendingRestore));" }
            let sentenceEdge = pendingSentenceEdge
            if let edge = sentenceEdge { script += "Reader.selectSentenceEdge(\(edge));" }
            let autoplay = continueOnLoad
            pendingRestore = -1; pendingAnchor = ""; previousPageOnLoad = false; continueOnLoad = false; pendingSentenceEdge = nil
            evaluate(script + "Reader.state()") { [weak self] value, _ in
                guard let self = self else { return }
                if let state = value as? [String: Any] { self.pageIndex = state["page"] as? Int ?? 0; self.pageCount = state["pages"] as? Int ?? 1; self.sourcePage = state["sourcePage"] as? Int ?? 1; self.savePosition(word: state["topWord"] as? Int ?? -1) }
                self.updateControls(); self.onReady?()
                if let edge = sentenceEdge, self.sentenceNavigation != nil {
                    let word = (value as? [String: Any])?["highlighted"] as? Int ?? -1
                    if word < 0, self.loadSentenceChapter(edge) { return }
                    self.completeSentenceMove(at: word)
                } else if autoplay { self.togglePlayback() }
                else { self.prepareNearby() }
            }
        case "page":
            pageIndex = data["page"] as? Int ?? 0; pageCount = data["pages"] as? Int ?? 1
            sourcePage = data["sourcePage"] as? Int ?? 1
            if data["source"] as? String != "speech" { savePosition(word: data["topWord"] as? Int ?? -1) }
            updateControls()
            if data["source"] as? String != "speech" { prepareNearby() }
        case "boundary":
            let delta = data["delta"] as? Int ?? 1
            if let book = book, book.chapters.indices.contains(chapterIndex + delta) { loadChapter(chapterIndex + delta, lastPage: delta < 0) }
        case "pause": pausePlayback()
        case "seek": if let word = data["index"] as? Int { startReading(at: word) }
        case "link":
            guard let book = book, let href = data["href"] as? String else { break }
            let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let anchor = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? String(parts[1]) : ""
            if parts.first?.isEmpty == true { stopPlayback(); evaluate("Reader.goAnchor(\(json(anchor)))") }
            else if let path = parts.first, let url = try? EPUBBook.safeURL(String(path), relativeTo: book.chapters[chapterIndex].url.deletingLastPathComponent(), root: book.root), let index = book.chapters.firstIndex(where: { $0.url == url }) { loadChapter(index, anchor: anchor) }
        case "error": showError(data["message"] as? String ?? "Couldn’t display this chapter.")
        default: break
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self = self, player === self.audioPlayer else { return }
            self.audioPlayer = nil; self.speechTimer?.invalidate(); self.speechTimer = nil
            self.unitIndex += 1; self.finishCallbacks += 1
            if self.playback == .playing { self.speakNext() }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL, let root = book?.root, url.standardizedFileURL.path.hasPrefix(root.path + "/"), navigationAction.navigationType != .linkActivated else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { showError(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error.localizedDescription) }
    func windowWillStartLiveResize(_ notification: Notification) { pausePlayback() }
    func windowWillClose(_ notification: Notification) { pausePlayback(); NSApp.terminate(nil) }

    func showError(_ message: String) {
        activity.stopAnimation(nil); stopPlayback(); ready = false; updateControls(); pageLabel.stringValue = message
        if testing { print("READER_ERROR: \(message)"); fflush(stdout) }
        else { let alert = NSAlert(); alert.messageText = "Couldn’t open book"; alert.informativeText = message; alert.beginSheetModal(for: window) }
    }

    func json(_ string: String) -> String { String(data: try! JSONSerialization.data(withJSONObject: string, options: .fragmentsAllowed), encoding: .utf8)! }
    func json(_ palette: [String: String]) -> String { String(data: try! JSONSerialization.data(withJSONObject: palette, options: .sortedKeys), encoding: .utf8)! }
}
