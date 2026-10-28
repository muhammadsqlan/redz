import AppKit
import WebKit
import AVFoundation

@MainActor
final class SelfTests {
    let reader: ReaderController
    let directory: URL
    var started = false
    var checks: [[String: Any]] = []
    init(reader: ReaderController, directory: URL) { self.reader = reader; self.directory = directory }

    func start() {
        guard !started else { return }; started = true
        Task { await run() }
    }
    func check(_ name: String, _ passed: Bool, details: String = "") {
        checks.append(["check": name, "passed": passed, "details": details])
        print("\(passed ? "PASS" : "FAIL") \(name) \(details)"); fflush(stdout)
    }
    func js(_ code: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            reader.evaluate(code) { value, error in
                if let error = error { continuation.resume(throwing: error) } else { continuation.resume(returning: value) }
            }
        }
    }
    func delay(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    func wait(_ seconds: Double = 15, until predicate: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds { if predicate() { return true }; await delay(0.1) }
        return predicate()
    }
    func snapshot(_ name: String) async throws {
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            reader.webView.takeSnapshot(with: nil) { image, error in
                if let image = image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? ReaderError(message: "No snapshot.")) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw ReaderError(message: "No snapshot pixels.") }
        try png.write(to: directory.appendingPathComponent(name))
    }
    func state() async throws -> [String: Any] { (try await js("Reader.state()") as? [String: Any]) ?? [:] }

    func interfaceSnapshot(_ name: String = "window.png") async throws {
        let web: NSImage = try await withCheckedThrowingContinuation { continuation in
            reader.webView.takeSnapshot(with: nil) { image, error in
                if let image = image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? ReaderError(message: "No snapshot.")) }
            }
        }
        guard let root = reader.window.contentView, let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let image = NSImage(size: root.bounds.size); image.addRepresentation(bitmap)
        image.lockFocus()
        web.draw(in: reader.webView.convert(reader.webView.bounds, to: root), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        if let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) { try png.write(to: directory.appendingPathComponent(name)) }
    }

    func themeMetrics() async throws -> [String: Any] {
        (try await js("""
        (() => {
            const root=getComputedStyle(document.documentElement), body=getComputedStyle(document.body);
            const word=document.querySelector('p .reader-word:not(.speaking)') || document.querySelector('.reader-word');
            const spoken=document.querySelector('.reader-word.speaking');
            const channel=n=>{n/=255;return n<=.04045?n/12.92:((n+.055)/1.055)**2.4;};
            const luminance=color=>{
                const rgb=color.startsWith('#')?[1,3,5].map(i=>parseInt(color.slice(i,i+2),16)):color.match(/[0-9.]+/g).slice(0,3).map(Number);
                return rgb.map(channel).reduce((sum,n,i)=>sum+n*[.2126,.7152,.0722][i],0);
            };
            const contrast=(a,b)=>{a=luminance(a);b=luminance(b);return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);};
            const image=document.querySelector('#reader-zoom img') || document.querySelector('#reader-flow img');
            const text=word?getComputedStyle(word).color:body.color;
            const highlight=spoken?getComputedStyle(spoken):null;
            return {theme:Reader.state().theme,paper:body.backgroundColor,ink:text,scheme:root.colorScheme,
                textContrast:contrast(text,body.backgroundColor),linkContrast:contrast(root.getPropertyValue('--accent').trim(),body.backgroundColor),
                highlightContrast:highlight?contrast(highlight.color,highlight.backgroundColor):0,
                imagePaper:image?getComputedStyle(image).backgroundColor:'',imageFilter:image?getComputedStyle(image).filter:'',zoom:Reader.state().zoom};
        })()
        """) as? [String: Any]) ?? [:]
    }

    func checkSavedAppearance(_ mode: ReaderAppearance) async throws {
        guard let book = reader.book else { return }
        let oldMenu = NSApp.mainMenu, oldWindowMenu = NSApp.windowsMenu
        let restored = try ReaderController(library: reader.library, testing: true, preferences: reader.defaults)
        defer {
            restored.speech.shutdown(); restored.webView.stopLoading()
            restored.webView.configuration.userContentController.removeScriptMessageHandler(forName: "reader", contentWorld: .defaultClient)
            if let monitor = restored.keyMonitor { NSEvent.removeMonitor(monitor) }
            restored.window.delegate = nil; restored.window.close()
            NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindowMenu
        }
        var loaded = false
        restored.onReady = { loaded = true }
        restored.openBook(book.source)
        let opened = await wait(15, until: { loaded })
        let theme: String? = try await withCheckedThrowingContinuation { continuation in
            restored.evaluate("Reader.state().theme") { value, error in
                if let error = error { continuation.resume(throwing: error) } else { continuation.resume(returning: value as? String) }
            }
        }
        let expected = mode == .dark ? "dark" : "light"
        check("Saved \(mode.title) mode applies on a fresh launch", opened && restored.appearanceMode == mode && theme == expected && restored.renderedTheme == expected && restored.appearanceButton.titleOfSelectedItem == mode.title)
    }

    func checkAppearance() async throws {
        let original = NSApp.appearance
        defer { NSApp.appearance = original; reader.setAppearance(.light) }
        let inherited = NSApp.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua ? "dark" : "light"
        let initial = try await themeMetrics()
        check("System appearance is the default on first launch", reader.appearanceMode == .system && reader.window.appearance == nil && reader.appearanceButton.titleOfSelectedItem == "System" && initial["theme"] as? String == inherited)
        check("Appearance dropdown offers System, Light, and Dark", reader.appearanceButton.itemTitles == ["System","Light","Dark"])
        let sampleWord = try await js("Reader.plan(0).find(u=>u.words.length>12).words[2].index") as? Int ?? 0
        _ = try await js("Reader.highlight(\(sampleWord))")
        // Only this silent test process changes its own application appearance.
        // The user's macOS preference and installed reader remain untouched.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        _ = await wait(3, until: { self.reader.renderedTheme == "dark" })
        let dark = try await themeMetrics()
        var nativePaper = NSColor.black, nativeChrome = NSColor.black
        reader.window.effectiveAppearance.performAsCurrentDrawingAppearance {
            nativePaper = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
            nativeChrome = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
        }
        let nativePaperCSS = "rgb(\(Int((nativePaper.redComponent * 255).rounded())), \(Int((nativePaper.greenComponent * 255).rounded())), \(Int((nativePaper.blueComponent * 255).rounded())))"
        check("System mode follows a change to dark appearance", reader.window.appearance == nil && dark["theme"] as? String == "dark" && dark["paper"] as? String == nativePaperCSS && dark["scheme"] as? String == "dark")
        check("Dark text, links, and sentence highlight stay readable", (dark["textContrast"] as? Double ?? 0) >= 7 && (dark["linkContrast"] as? Double ?? 0) >= 4.5 && (dark["highlightContrast"] as? Double ?? 0) >= 4.5, details: "text=\(dark["textContrast"] ?? 0), highlight=\(dark["highlightContrast"] ?? 0)")
        let chrome = reader.window.contentView?.layer?.backgroundColor
        let chromeColor = chrome.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        let paperColor = reader.webView.underPageBackgroundColor.usingColorSpace(.sRGB)!
        let chromeMatches = chromeColor.map { abs($0.redComponent - nativeChrome.redComponent) < 0.002 && abs($0.greenComponent - nativeChrome.greenComponent) < 0.002 && abs($0.blueComponent - nativeChrome.blueComponent) < 0.002 } ?? false
        let paperMatches = abs(paperColor.redComponent - nativePaper.redComponent) < 0.002 && abs(paperColor.greenComponent - nativePaper.greenComponent) < 0.002 && abs(paperColor.blueComponent - nativePaper.blueComponent) < 0.002
        check("Dark mode uses the native macOS toolbar and neutral reading background", reader.window.effectiveAppearance.bestMatch(from: [.aqua,.darkAqua]) == .darkAqua && chromeMatches && paperMatches && abs(paperColor.redComponent - paperColor.greenComponent) < 0.002 && abs(paperColor.redComponent - paperColor.blueComponent) < 0.002, details: nativePaperCSS)
        try await interfaceSnapshot("dark-mode.png")
        NSApp.appearance = NSAppearance(named: .aqua)
        _ = await wait(3, until: { self.reader.renderedTheme == "light" })
        let followed = try await themeMetrics()
        check("System mode follows a change back to light appearance", reader.window.appearance == nil && followed["theme"] as? String == "light" && followed["paper"] as? String == "rgb(250, 249, 245)")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        reader.appearanceButton.selectItem(withTitle: "Light"); reader.appearanceChanged()
        let light = try await themeMetrics()
        check("Light override wins over a dark system", reader.appearanceMode == .light && reader.window.appearance?.name == .aqua && light["theme"] as? String == "light" && reader.defaults.string(forKey: "appearanceMode") == "light")
        try await checkSavedAppearance(.light)
        try await interfaceSnapshot("light-mode.png")
        NSApp.appearance = NSAppearance(named: .aqua)
        reader.appearanceButton.selectItem(withTitle: "Dark"); reader.appearanceChanged()
        let forced = try await themeMetrics()
        check("Dark override wins over a light system", reader.appearanceMode == .dark && reader.window.appearance?.name == .darkAqua && forced["theme"] as? String == "dark" && reader.defaults.string(forKey: "appearanceMode") == "dark")
        try await checkSavedAppearance(.dark)
        reader.appearanceButton.selectItem(withTitle: "System"); reader.appearanceChanged()
        let system = try await themeMetrics()
        check("Selecting System removes the override", reader.appearanceMode == .system && reader.window.appearance == nil && system["theme"] as? String == "light" && reader.defaults.string(forKey: "appearanceMode") == "system")
        _ = try await js("Reader.clearHighlight(); Reader.setPage(0)")
    }

    func run() async {
        if reader.isPDF { await runPDF(); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let book = reader.book else { throw ReaderError(message: "Book not loaded.") }
            check("EPUB parsed", book.chapters.count == 32 && book.contents.count > 80, details: "\(book.chapters.count) chapters, \(book.contents.count) contents entries")
            let initial = try await state()
            check("Preface opens", reader.chapterIndex == book.initialChapter && (initial["wordCount"] as? Int ?? 0) > 500)
            check("Pagination available", (initial["pages"] as? Int ?? 0) > 1)
            let images = initial["images"] as? [[String: Any]] ?? []
            check("Preface images loaded", !images.isEmpty && images.allSatisfy { $0["loaded"] as? Bool == true }, details: "\(images.count) images")
            try await checkAppearance()
            try await snapshot("preface.png")
            try await interfaceSnapshot()
            let page = try await js("Reader.setPage(1)") as? [String: Any] ?? [:]
            let top = page["topWord"] as? Int ?? -1
            let plan = try await js("Reader.plan(\(top))") as? [[String: Any]] ?? []
            let firstWord = (plan.first?["words"] as? [[String: Any]])?.first?["index"] as? Int
            check("Play begins at current page top", top > 0 && firstWord == top)
            let continuity = try await js("(() => {const p=Reader.plan(0), w=p.flatMap(u=>u.words);return {ordered:w.every((x,i)=>x.index===i),count:w.length,expected:Reader.state().wordCount,offsets:p.every(u=>u.words.every(w=>u.text.slice(w.start,w.start+w.length).length===w.length))};})()") as? [String: Any] ?? [:]
            check("Speech covers every word in order", continuity["ordered"] as? Bool == true && continuity["count"] as? Int == continuity["expected"] as? Int && continuity["offsets"] as? Bool == true)
            let sentence = try await js("(() => {const p=Reader.plan(0), u=p.find(u=>u.words.length>12);Reader.highlight(u.words[2].index);const first=Reader.state();const spans=[...document.querySelectorAll('.reader-word.speaking')];const text=spans.map(s=>s.textContent).join(' ');const painted=spans.every(s=>getComputedStyle(s).backgroundColor==='rgb(247, 222, 129)');Reader.highlight(u.words[u.words.length-1].index);const last=Reader.state();return {full:text===u.text,words:first.sentenceWords.length,stable:first.highlightedSentence===last.highlightedSentence,painted};})()") as? [String: Any] ?? [:]
            check("Whole sentence is highlighted across words", sentence["full"] as? Bool == true && (sentence["words"] as? Int ?? 0) > 12 && sentence["painted"] as? Bool == true)
            check("Sentence highlight stays stable while speaking", sentence["stable"] as? Bool == true)
            let transition = try await js("(() => {const p=Reader.plan(0), a=p.findIndex(u=>u.words.length>12);Reader.highlight(p[a+1].words[0].index);return [...document.querySelectorAll('.reader-word.speaking')].map(s=>s.textContent).join(' ')===p[a+1].text && document.querySelectorAll('.reader-gap.speaking').length>0;})()") as? Bool ?? false
            check("Next sentence clears the previous highlight", transition)
            await delay(0.2)
            try await snapshot("sentence-highlight.png")
            _ = try await js("Reader.clearHighlight()")
            let figureIndex = try await js("Number(document.querySelector('figure .reader-word')?.dataset.word || -1)") as? Int ?? -1
            _ = try await js("Reader.restore(\(figureIndex))")
            await delay(0.3)
            try await snapshot("chart.png")
            _ = try await js("document.querySelector('figure img').click()")
            let zoom = try await state()
            check("Chart can be enlarged", zoom["zoom"] as? Bool == true)
            let imageSource = try await js("document.querySelector('#reader-zoom img').src") as? String
            reader.setAppearance(.dark)
            let darkZoom = try await themeMetrics()
            let sameImage = try await js("document.querySelector('#reader-zoom img').src") as? String
            check("Dark image viewer preserves chart colors and its open state", darkZoom["theme"] as? String == "dark" && darkZoom["zoom"] as? Bool == true && darkZoom["imagePaper"] as? String == "rgb(255, 255, 255)" && darkZoom["imageFilter"] as? String == "none" && imageSource == sameImage)
            try await snapshot("dark-chart.png")
            reader.setAppearance(.light)
            _ = try await js("Reader.closeZoom()")
            _ = try await js("Reader.setPage(0)")
            check("Four curated voices exclude novelty voices", reader.voices.count == 4 && reader.voices.filter { $0.gender == "Female" }.count == 2 && reader.voices.filter { $0.gender == "Male" }.count == 2 && reader.voices.allSatisfy { $0.identifier.hasPrefix("af_") || $0.identifier.hasPrefix("am_") }, details: reader.voices.map { $0.name }.joined(separator: ", "))
            let sampleText = "Inference engineering makes artificial intelligence faster, more reliable, and easier to use."
            let pieces = sampleText.split(separator: " ").map(String.init)
            var offset = 0
            let sampleWords = pieces.enumerated().map { i, word -> SpeechWord in
                defer { offset += (word as NSString).length + 1 }
                return SpeechWord(index: i, start: offset, length: (word as NSString).length)
            }
            let sample = SpeechUnit(text: sampleText, words: sampleWords)
            var validVoices: [String] = []
            var samples: [String: NeuralAudio] = [:]
            for voice in reader.voices {
                let audio: NeuralAudio = try await withCheckedThrowingContinuation { continuation in
                    reader.speech.request(sample, voice: voice) { continuation.resume(with: $0) }
                }
                let player = try AVAudioPlayer(data: audio.data)
                let times = audio.words.map { $0.start }
                samples[voice.identifier] = audio
                if player.duration > 1 && audio.words.count == pieces.count && times == times.sorted() && (times.last ?? 0) < player.duration { validVoices.append(voice.name) }
                try audio.data.write(to: directory.appendingPathComponent("voice-\(voice.name.lowercased()).wav"))
            }
            check("All four voices generate audio with timings", validVoices.count == 4, details: validVoices.joined(separator: ", "))
            reader.speech.cancel()
            let remapped = SpeechUnit(text: sampleText, words: sampleWords.map { SpeechWord(index: $0.index + 500, start: $0.start, length: $0.length) })
            let cacheBegin = Date(), oldHits = reader.speech.cacheHits
            let reused: NeuralAudio = try await withCheckedThrowingContinuation { continuation in
                reader.speech.request(remapped, voice: reader.voices[0]) { continuation.resume(with: $0) }
            }
            check("Recent audio survives cancellation and remaps book positions", reader.speech.cacheHits == oldHits + 1 && reused.data == samples[reader.voices[0].identifier]?.data && reused.words.map { $0.index } == remapped.words.map { $0.index } && Date().timeIntervalSince(cacheBegin) < 0.1)
            check("Audio cache keeps each voice separate", samples[reader.voices[0].identifier]?.data != samples[reader.voices[3].identifier]?.data && reader.speech.cachedCount <= 64 && reader.speech.cacheBytes <= 48 * 1024 * 1024)
            let faster: NeuralAudio = try await withCheckedThrowingContinuation { continuation in
                reader.speech.request(sample, voice: reader.voices[0], speed: 1.5) { continuation.resume(with: $0) }
            }
            reader.speech.cancel()
            let speedHits = reader.speech.cacheHits
            let fastReused: NeuralAudio = try await withCheckedThrowingContinuation { continuation in
                reader.speech.request(remapped, voice: reader.voices[0], speed: 1.5) { continuation.resume(with: $0) }
            }
            check("Prepared speed variants remain separate and survive cancellation", faster.data != reused.data && faster.duration < reused.duration && fastReused.data == faster.data && fastReused.words.map { $0.index } == remapped.words.map { $0.index } && reader.speech.cacheHits == speedHits + 1)
            let speakIndex = try await js("Number(document.querySelector('p .reader-word')?.dataset.word || 0)") as? Int ?? 0
            let normalUnit = reader.parseUnits(try await js("Reader.plan(\(speakIndex))")).first!
            let normalAudio: NeuralAudio = try await withCheckedThrowingContinuation { continuation in
                reader.speech.request(normalUnit, voice: reader.voices[reader.voiceButton.indexOfSelectedItem]) { continuation.resume(with: $0) }
            }
            var fastStarts: [String] = [], fastResumes: [String] = [], clockRates: [String] = [], bypasses: [String] = []
            for (selection, target) in [(2, Float(1.25)), (3, 1.5), (4, 1.75), (5, 2)] {
                reader.stopPlayback(); reader.speedButton.selectItem(at: selection)
                reader.startReading(at: speakIndex)
                let loaded = await wait(until: { self.reader.audioPlayer != nil })
                guard loaded, let player = reader.audioPlayer, reader.audioWords.count > 2 else { continue }
                let secondWord = reader.audioWords[1].start
                let tail = normalAudio.words.suffix(2).map { $0.start }
                let fastTail = reader.audioWords.suffix(2).map { $0.start }
                let measuredTempo = (tail[1] - tail[0]) / (fastTail[1] - fastTail[0])
                let lead = Double(target) - 0.25
                let expectedSecondWord = normalAudio.words[1].start / lead
                if abs(secondWord - expectedSecondWord) < 0.001 && abs(measuredTempo - Double(target)) < 0.01 && player.duration < normalAudio.duration && player.duration > normalAudio.duration / Double(target) { fastStarts.append("\(target)× starts at \(lead)×") }
                _ = await wait(until: { player.currentTime > secondWord + 0.4 })
                let audioTime = player.currentTime, wallTime = Date()
                await delay(0.25)
                let measured = (player.currentTime - audioTime) / Date().timeIntervalSince(wallTime)
                if abs(measured - 1) < 0.15 { clockRates.append("\(target)×=\(String(format: "%.2f", measured)) PCM clock") }
                if !player.enableRate && abs(player.rate - 1) < 0.001 { bypasses.append("\(target)×") }
                reader.pausePlayback(); reader.togglePlayback()
                let restarted = await wait(5, until: { self.reader.playback == .playing && self.reader.audioPlayer === player && player.currentTime < secondWord && !player.enableRate && abs(player.rate - 1) < 0.001 })
                if restarted { fastResumes.append("\(target)×") }
            }
            check("Each fast speed starts one step slower and maps later words to selected tempo", fastStarts.count == 4, details: fastStarts.joined(separator: ", "))
            check("Prepared audio plays with a normal PCM clock at every fast speed", clockRates.count == 4, details: clockRates.joined(separator: ", "))
            check("All fast speeds bypass the native time and pitch processor", bypasses.count == 4, details: bypasses.joined(separator: ", "))
            check("Resume repeats the first word at the prepared lead-in speed", fastResumes.count == 4, details: fastResumes.joined(separator: ", "))
            var steadyRates: [String] = []
            for (selection, target) in [(0, Float(0.75)), (1, 1)] {
                reader.stopPlayback(); reader.speedButton.selectItem(at: selection)
                reader.startReading(at: speakIndex)
                _ = await wait(until: { self.reader.audioPlayer != nil })
                guard let player = reader.audioPlayer, reader.audioWords.count > 1 else { continue }
                let expectedDuration = normalAudio.duration / Double(target)
                let expectedStart = normalAudio.words[1].start / Double(target)
                if !player.enableRate && abs(player.rate - 1) < 0.001 && abs(player.duration - expectedDuration) < 0.001 && abs(reader.audioWords[1].start - expectedStart) < 0.001 { steadyRates.append("\(target)×") }
            }
            check("Normal and slow recordings retain constant tempo with native processing bypassed", steadyRates.count == 2, details: steadyRates.joined(separator: ", "))
            reader.stopPlayback(); reader.speedButton.selectItem(at: 5)
            let singleWord = try await js("Reader.plan(0).find(u=>u.words.length===1)?.words[0].index ?? -1") as? Int ?? -1
            let singleUnit = reader.parseUnits(try await js("Reader.plan(\(singleWord))")).first!
            let singleNormal: NeuralAudio = try await withCheckedThrowingContinuation { continuation in
                reader.speech.request(singleUnit, voice: reader.voices[reader.voiceButton.indexOfSelectedItem]) { continuation.resume(with: $0) }
            }
            reader.startReading(at: singleWord)
            _ = await wait(until: { self.reader.audioPlayer != nil })
            var singleRates: [Float] = []
            var singleDuration = 0.0
            if let player = reader.audioPlayer, reader.audioWords.count == 1 {
                singleDuration = player.duration
                let begin = Date()
                while reader.audioPlayer === player && Date().timeIntervalSince(begin) < 5 {
                    singleRates.append(player.rate); await delay(0.04)
                }
            }
            check("A one-word sentence uses the one-step-slower lead-in speed", singleWord >= 0 && singleRates.count > 3 && singleRates.allSatisfy { abs($0 - 1) < 0.001 } && abs(singleDuration - singleNormal.duration / 1.75) < 0.001)
            reader.stopPlayback(); reader.speedButton.selectItem(at: 1)
            let callbacksBefore = reader.speechCallbacks
            reader.startReading(at: speakIndex)
            let talking = await wait(until: { self.reader.speechCallbacks >= callbacksBefore + 5 })
            check("Neural audio follows spoken word timings", talking)
            let highlighted = try await state()
            check("Narration highlights the current sentence", (highlighted["highlighted"] as? Int ?? -1) >= speakIndex && (highlighted["sentenceWords"] as? [Int] ?? []).count > 1)
            let playingAudio = reader.audioPlayer, themeGeneration = reader.generation
            let playingTime = playingAudio?.currentTime ?? -1
            reader.setAppearance(.dark)
            await delay(0.1)
            let playingTheme = try await themeMetrics()
            check("Changing appearance keeps narration running", reader.playback == .playing && reader.audioPlayer === playingAudio && reader.generation == themeGeneration && (reader.audioPlayer?.currentTime ?? -2) > playingTime && playingTheme["theme"] as? String == "dark")
            reader.pausePlayback()
            await delay(0.5)
            let pausedWord = reader.currentWord, pausedCallbacks = reader.speechCallbacks
            let pausedTime = reader.audioPlayer?.currentTime ?? -1
            let sentenceBeginning = try await js("Reader.sentenceStart(\(pausedWord))") as? Int ?? -1
            await delay(1)
            check("Pause holds exact audio position", reader.playback == .paused && reader.currentWord == pausedWord && reader.speechCallbacks == pausedCallbacks && reader.audioPlayer?.isPlaying == false && abs((reader.audioPlayer?.currentTime ?? -2) - pausedTime) < 0.02)
            let beforeTheme = try await state()
            reader.setAppearance(.light)
            let afterTheme = try await state()
            check("Changing appearance preserves paused audio, page, and highlighted sentence", reader.playback == .paused && reader.currentWord == pausedWord && abs((reader.audioPlayer?.currentTime ?? -2) - pausedTime) < 0.02 && beforeTheme["page"] as? Int == afterTheme["page"] as? Int && beforeTheme["highlightedSentence"] as? Int == afterTheme["highlightedSentence"] as? Int)
            reader.togglePlayback()
            let restarted = await wait(until: { self.reader.playback == .playing && self.reader.currentWord == sentenceBeginning && (self.reader.audioPlayer?.currentTime ?? 100) < 0.4 })
            check("Resume restarts the highlighted sentence", restarted && sentenceBeginning < pausedWord)
            let resumed = await wait(until: { self.reader.speechCallbacks >= pausedCallbacks + 4 })
            check("Narration continues after sentence restart", resumed)
            reader.pausePlayback()
            _ = try await js("document.querySelector('figure img').click()")
            check("Chart viewing keeps narration paused", reader.playback == .paused)
            _ = try await js("Reader.closeZoom()")
            reader.turnPage(1)
            await delay(0.3)
            check("Manual page turn resets playback", reader.playback == .idle)
            reader.stopPlayback()
            reader.startReading(at: speakIndex + 5)
            let partialReady = await wait(until: { self.reader.audioPlayer != nil && self.reader.currentWord >= speakIndex + 5 })
            reader.pausePlayback()
            reader.togglePlayback()
            let wholeAgain = await wait(until: { self.reader.playback == .playing && self.reader.units.first?.words.first?.index == speakIndex && self.reader.audioPlayer != nil })
            check("Resume restores the full sentence after a mid-sentence start", partialReady && wholeAgain)
            reader.stopPlayback()
            let starts = try await js("Reader.plan(0).map(u=>u.words[0].index)") as? [Int] ?? []
            guard starts.count > 8 else { throw ReaderError(message: "Not enough sentences for navigation checks.") }
            reader.speedButton.selectItem(at: 3)
            reader.voiceButton.selectItem(at: 3)
            reader.startReading(at: starts[5])
            _ = await wait(until: { self.reader.audioPlayer != nil })
            reader.pausePlayback()
            let nearby = reader.parseUnits(try await js("Reader.nearby(\(starts[5]))"))
            let neighboursReady = await wait(20, until: { nearby.allSatisfy { self.reader.speech.hasCachedAudio($0, voice: self.reader.voices[3], speed: 1.5) } })
            check("Nearby sentences are prepared for forward and backward skips", neighboursReady && nearby.count == 5)
            var skipLatencies: [Double] = []
            for (key, expected) in [(UInt16(126), starts[4]), (125, starts[5]), (126, starts[4]), (126, starts[3]), (125, starts[4]), (125, starts[5]), (125, starts[6])] {
                let began = Date()
                reader.handleReadingKey(key)
                let audible = await wait(3, until: {
                    guard let player = self.reader.audioPlayer, let first = self.reader.audioWords.first else { return false }
                    return first.index == expected && player.isPlaying && player.currentTime >= first.start
                })
                skipLatencies.append(audible ? Date().timeIntervalSince(began) : 100)
            }
            check("Prepared ↑ and ↓ start speech within one second at 1.5× with Fenrir", skipLatencies.allSatisfy { $0 < 1 }, details: skipLatencies.map { String(format: "%.2fs", $0) }.joined(separator: ", "))
            reader.stopPlayback(); reader.voiceButton.selectItem(at: 0)
            _ = try await js("Reader.highlight(\(starts[5]))")
            reader.handleReadingKey(126)
            let up = await wait(until: { self.reader.playback == .playing && self.reader.audioPlayer != nil && self.reader.audioWords.first?.index == starts[4] })
            check("↑ starts reading the previous sentence", up)
            reader.pausePlayback()
            try await snapshot("sentence-navigation.png")
            reader.nextSentenceButton.performClick(nil)
            let down = await wait(until: { self.reader.playback == .playing && self.reader.units.first?.words.first?.index == starts[5] })
            check("↓ button starts reading the next sentence while paused", down)
            reader.handleReadingKey(126); reader.handleReadingKey(126); reader.handleReadingKey(126)
            let repeatedUp = await wait(until: { self.reader.playback == .playing && self.reader.units.first?.words.first?.index == starts[2] && self.reader.sentenceNavigation == nil })
            check("Repeated ↑ counts every press", repeatedUp)
            reader.handleReadingKey(125); reader.handleReadingKey(125); reader.handleReadingKey(125); reader.previousSentenceButton.performClick(nil)
            let mixed = await wait(until: { self.reader.playback == .playing && self.reader.units.first?.words.first?.index == starts[4] && self.reader.sentenceMoves.isEmpty })
            check("Mixed repeated arrows preserve navigation order", mixed)
            reader.nextSentence(); reader.nextSentence(); reader.turnPage(1)
            await delay(0.3)
            let cancelled = try await state()
            check("Page turn cancels pending sentence navigation", reader.playback == .idle && reader.sentenceNavigation == nil && reader.sentenceMoves.isEmpty && cancelled["highlighted"] as? Int == -1)
            reader.stopPlayback()
            let nextPageSentence = starts.firstIndex(where: { $0 >= top })!
            _ = try await js("Reader.highlight(\(starts[nextPageSentence-1]))")
            reader.nextSentence()
            let sentencePage = await wait(until: { self.reader.playback == .playing && self.reader.units.first?.words.first?.index == starts[nextPageSentence] && self.reader.pageIndex > 0 })
            check("Sentence arrows follow across page boundaries", sentencePage)
            reader.stopPlayback()
            _ = try await js("Reader.selectSentenceEdge(1)")
            let preface = reader.chapterIndex
            reader.handleReadingKey(126); reader.handleReadingKey(126)
            let previousSection = await wait(until: { self.reader.chapterIndex == preface-1 && self.reader.ready && self.reader.playback == .playing && self.reader.sentenceNavigation == nil && !self.reader.units.isEmpty })
            reader.pausePlayback()
            let previousStarts = try await js("Reader.plan(0).map(u=>u.words[0].index)") as? [Int] ?? []
            check("Repeated ↑ crosses sections without losing presses", previousSection && previousStarts.count > 1 && reader.units.first?.words.first?.index == previousStarts[previousStarts.count-2])
            reader.handleReadingKey(125); reader.handleReadingKey(125)
            let returnSection = await wait(until: { self.reader.chapterIndex == preface && self.reader.ready && self.reader.playback == .playing && self.reader.units.first?.words.first?.index == starts[0] })
            check("Repeated ↓ returns to the next section's first sentence", returnSection)
            reader.stopPlayback()
            _ = try await js("Reader.setPage(0)")
            reader.speedButton.selectItem(at: 5)
            let crossingStart = max(0, top - 6)
            reader.startReading(at: crossingStart)
            let crossed = await wait(20, until: { self.reader.pageIndex > 0 && self.reader.currentWord >= top })
            check("Narration advances pages automatically", crossed, details: "page=\(reader.pageIndex) word=\(reader.currentWord) target=\(top) audio=\(reader.audioPlayer != nil)")
            reader.stopPlayback()
            let lastWord = (initial["wordCount"] as? Int ?? 0) - 3
            let originalChapter = reader.chapterIndex
            reader.startReading(at: lastWord)
            let nextChapter = await wait(20, until: { self.reader.chapterIndex == originalChapter + 1 && self.reader.ready })
            check("Narration continues into next chapter", nextChapter, details: "chapter=\(reader.chapterIndex) playback=\(reader.playback.rawValue) audio=\(reader.audioPlayer != nil)")
            reader.stopPlayback()
            var totalImages = 0, totalWords = 0, chapterErrors: [String] = []
            var themeErrors: [String] = []
            reader.setAppearance(.dark)
            for index in book.chapters.indices {
                reader.loadChapter(index)
                let loaded = await wait(15, until: { self.reader.ready && self.reader.chapterIndex == index })
                if !loaded { chapterErrors.append("\(index): timeout"); continue }
                let value = try await state()
                if value["theme"] as? String != "dark" { themeErrors.append("\(index)") }
                let imgs = value["images"] as? [[String: Any]] ?? []
                totalImages += imgs.count; totalWords += value["wordCount"] as? Int ?? 0
                if imgs.contains(where: { $0["loaded"] as? Bool != true }) { chapterErrors.append("\(index): image") }
            }
            check("All chapters render with images", chapterErrors.isEmpty, details: "\(totalWords) words, \(totalImages) images; \(chapterErrors)")
            check("Dark appearance applies to every new chapter", themeErrors.isEmpty, details: themeErrors.joined(separator: ", "))
            reader.loadChapter(book.initialChapter)
            _ = await wait(until: { self.reader.ready })
            _ = try await js("Reader.setPage(1)")
            let position = try await state()
            let saved = position["topWord"] as? Int ?? -1
            reader.savePosition(word: saved)
            let prefix = "position." + book.source.path
            check("Reading position persists", reader.defaults.integer(forKey: prefix + ".chapter") == book.initialChapter && reader.defaults.integer(forKey: prefix + ".word") == saved)
            let fontBefore = try await state()
            reader.setFont(27)
            await delay(0.3)
            let fontAfter = try await state()
            check("Text resize repaginates", (fontAfter["pages"] as? Int ?? 0) >= (fontBefore["pages"] as? Int ?? 0))
            reader.setFont(21)
            reader.window.setContentSize(NSSize(width: 780, height: 550))
            await delay(0.5)
            let compact = try await state()
            check("Compact window still paginates", (compact["pages"] as? Int ?? 0) > 1)
            let popup = reader.appearanceButton.convert(reader.appearanceButton.bounds, to: reader.window.contentView)
            check("Appearance dropdown fits a compact window", popup.minX >= 0 && popup.maxX <= reader.window.contentView!.bounds.width && reader.appearanceButton.itemTitles == ["System","Light","Dark"])
            try await snapshot("compact.png")
        } catch { check("Test run", false, details: error.localizedDescription) }
        reader.stopPlayback()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "date": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("report.json")) }
        print("SELF_TEST_RESULT \(passed ? "PASS" : "FAIL")"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
