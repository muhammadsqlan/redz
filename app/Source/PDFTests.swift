import AppKit
import PDFKit

extension SelfTests {
    func runPDF() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let book = reader.book else { throw ReaderError(message: "PDF not loaded.") }
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: book.root.appendingPathComponent("manifest.json"))) as! [String: Any]
            let stats = manifest["stats"] as! [String: Any]
            let initial = try await state()
            let bert = book.title.contains("BERT")
            check("Research PDF opens as one reflowed article", reader.isPDF && book.chapters.count == 1 && book.contents.count > 10 && (initial["wordCount"] as? Int ?? 0) > 4000 && (stats["pages"] as? Int) == (bert ? 16 : 12))
            let readingOrder = try await js("""
            (()=>{const text=document.getElementById('reader-flow').textContent.replace(/\\s+/g,' ');return text;})()
            """) as? String ?? ""
            let landmarks = bert ? ["We introduce a new language representation", "BERT is conceptually simple", "Language model pre-training has been shown", "There are two existing strategies"] : ["Deeper neural networks are more difficult to train", "Deep convolutional neural networks", "An obstacle to answering this question"]
            let positions = landmarks.map { readingOrder.range(of: $0).map { readingOrder.distance(from: readingOrder.startIndex, to: $0.lowerBound) } ?? -1 }
            check("Two-column prose follows human reading order", positions.allSatisfy { $0 >= 0 } && positions == positions.sorted(), details: String(describing: positions))
            if bert {
                let section = ["3.1 Pre-training BERT", "Unlike Peters et al.", "Task #1: Masked LM", "In order to train a deep bidirectional representation", "Task #2: Next Sentence Prediction", "Many important downstream tasks"]
                let sectionPositions = section.map { readingOrder.range(of: $0).map { readingOrder.distance(from: readingOrder.startIndex, to: $0.lowerBound) } ?? -1 }
                check("Short headings do not jump into the other column", sectionPositions.allSatisfy { $0 >= 0 } && sectionPositions == sectionPositions.sorted(), details: String(describing: sectionPositions))
                let pageFourText = try await js("Array.from(document.querySelectorAll('p[data-source-page=\"4\"]:not(.pdf-footnote)')).map(p=>p.textContent).join(' ')") as? String ?? ""
                check("A footnote continued from the previous page stays out of narration", !pageFourText.contains("former is often referred"))
            }
            if !bert { check("Floating figure does not interrupt a sentence across columns", readingOrder.contains("have also greatly benefited from very deep models.")) }
            check("Line wraps and ligatures become readable words", !readingOrder.contains("representa- tion") && !readingOrder.contains("ﬁ") && !readingOrder.contains("ﬂ"))
            let images = initial["images"] as? [[String: Any]] ?? []
            check("PDF figures and tables render from the source", images.count > 3 && images.allSatisfy { $0["loaded"] as? Bool == true }, details: "\(images.count) images; \(stats)")
            if !bert { check("Displayed equations remain visible as PDF crops", (stats["formulas"] as? Int ?? 0) > 0) }
            try await checkAppearance()
            try await interfaceSnapshot("pdf-reading-light.png")
            reader.setAppearance(.dark)
            try await interfaceSnapshot("pdf-reading-dark.png")
            reader.setAppearance(.light)
            _ = try await js("document.querySelector('#reader-flow img').click()")
            check("A PDF figure enlarges", (try await state())["zoom"] as? Bool == true)
            try await snapshot("pdf-figure.png")
            _ = try await js("Reader.closeZoom()")
            let sourceWord = try await js("Number(document.querySelector('[data-source-page=\"3\"] .reader-word').dataset.word)") as? Int ?? -1
            _ = try await js("Reader.highlight(\(sourceWord))")
            reader.toggleOriginal()
            let originalOpened = await wait(5, until: { self.reader.showingOriginal })
            let originalIndex = reader.pdfView.currentPage.flatMap { reader.pdfView.document?.index(for: $0) } ?? -1
            check("Original PDF opens at the highlighted text's source page", originalOpened && originalIndex == 2 && reader.pdfView.document?.pageCount == stats["pages"] as? Int && !reader.playButton.isEnabled)
            check("Reading shortcuts leave the original PDF alone", !reader.handleReadingKey(49) && !reader.handleReadingKey(126))
            let beforeReturn = try await state()
            reader.toggleOriginal()
            let afterReturn = try await state()
            check("Returning from Original preserves the reading location", !reader.showingOriginal && beforeReturn["page"] as? Int == afterReturn["page"] as? Int && beforeReturn["highlighted"] as? Int == afterReturn["highlighted"] as? Int)
            reader.toggleOriginal()
            _ = await wait(3, until: { self.reader.showingOriginal })
            if let page = reader.pdfView.document?.page(at: 4) { reader.pdfView.go(to: page) }
            reader.toggleOriginal(); await delay(0.3)
            let pageVisible = try await js("(()=>{const w=document.querySelector('[data-source-page=\"5\"] .reader-word');const r=w.getBoundingClientRect(),v=document.getElementById('reader-viewport').getBoundingClientRect();return r.left>=v.left-2&&r.left<v.right;})()") as? Bool ?? false
            check("Changing original pages returns to that part of the reading view", pageVisible)
            _ = try await js("Reader.setPage(1)")
            let atPage = try await state(), top = atPage["topWord"] as? Int ?? -1
            reader.togglePlayback()
            let playing = await wait(45, until: { self.reader.playback == .playing && self.reader.audioPlayer?.isPlaying == true })
            check("PDF narration starts at the current reflowed page", playing && reader.units.first?.words.first?.index == top)
            await delay(0.3)
            reader.pausePlayback()
            let sentenceStart = try await js("Reader.sentenceStart(\(reader.currentWord))") as? Int ?? -1
            reader.toggleOriginal(); _ = await wait(3, until: { self.reader.showingOriginal }); reader.toggleOriginal()
            check("Original viewing keeps narration paused", reader.playback == .paused && reader.audioPlayer?.isPlaying != true, details: "state=\(reader.playback.rawValue)")
            reader.togglePlayback()
            let resumed = await wait(45, until: { self.reader.playback == .playing && self.reader.audioPlayer?.isPlaying == true })
            let resumedStart = reader.units.indices.contains(reader.unitIndex) ? reader.units[reader.unitIndex].words.first?.index ?? -1 : -1
            check("PDF resume restarts the highlighted sentence", resumed && resumedStart == sentenceStart && (reader.audioPlayer?.currentTime ?? 1) < 0.5, details: "started=\(resumed), expected=\(sentenceStart), actual=\(resumedStart), time=\(reader.audioPlayer?.currentTime ?? -1)")
            reader.pausePlayback()
            let nextWord = try await js("Reader.nearby(\(reader.currentWord)).find(u=>u.words[0].index>\(reader.currentWord))?.words[0].index") as? Int ?? -1
            reader.moveSentence(1)
            let moved = await wait(20, until: { self.reader.sentenceNavigation == nil && self.reader.playback == .playing })
            check("Sentence navigation works in converted PDF text", moved && reader.units.first?.words.first?.index == nextWord)
            reader.stopPlayback()
            let export = book.root.appendingPathComponent("Reading.epub")
            let exported = try EPUBBook.open(export, library: directory.appendingPathComponent("export-check"))
            check("Generated EPUB has a valid package and contents", exported.chapters.count == 1 && exported.contents.count == book.contents.count && exported.title == book.title)
            reader.openBook(book.source)
            let reopened = await wait(15, until: { self.reader.ready && self.reader.book?.root == book.root })
            check("Reopening reuses the cached PDF conversion", reopened)
            reader.window.setContentSize(NSSize(width: 780, height: 550)); reader.setFont(27); await delay(0.3)
            let compact = try await state()
            let button = reader.originalButton.convert(reader.originalButton.bounds, to: reader.window.contentView)
            check("Reflow and Original control fit a compact window", (compact["pages"] as? Int ?? 0) > 1 && button.minX >= 0 && button.maxX <= reader.window.contentView!.bounds.width)
            try await interfaceSnapshot("pdf-compact.png")
            reader.openBook(export)
            let epubOpened = await wait(15, until: { self.reader.ready && !self.reader.isPDF })
            let roundTrip = try await state()
            check("Exported EPUB opens with the same text and figures", epubOpened && roundTrip["wordCount"] as? Int == initial["wordCount"] as? Int && (roundTrip["images"] as? [[String: Any]])?.count == images.count && reader.originalButton.isHidden)
        } catch { check("PDF test run", false, details: error.localizedDescription) }
        reader.stopPlayback(); reader.pdfImporter.cancel()
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "checks": checks, "date": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("report.json")) }
        print("PDF_SELF_TEST_RESULT \(passed ? "PASS" : "FAIL")"); fflush(stdout)
        NSApp.terminate(nil)
    }
}
