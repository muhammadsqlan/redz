import Foundation

private struct PDFManifest: Decodable {
    struct Item: Decodable { let path: String; let title: String }
    struct Entry: Decodable { let title: String; let anchor: String; let depth: Int }
    let title: String
    let chapters: [Item]
    let contents: [Entry]
}

@MainActor
final class PDFImporter {
    private var process: Process?
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    func open(_ source: URL, library: URL, progress: @escaping (Int, Int) -> Void, completion: @escaping (Result<EPUBBook, Error>) -> Void) {
        cancel()
        let token = generation
        do {
            guard let resources = Bundle.main.resourceURL else { throw ReaderError(message: "Missing PDF reader.") }
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = resources.appendingPathComponent("Python/bin/python3.13")
            process.arguments = ["-u", resources.appendingPathComponent("PDFImport.py").path, source.path, library.path]
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = resources.appendingPathComponent("PDFPackages").path + ":" + resources.appendingPathComponent("SpeechPackages").path
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["OMP_NUM_THREADS"] = "2"
            process.environment = environment
            process.standardOutput = output; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            try process.run()
            self.process = process
            DispatchQueue.global(qos: .utility).async {
                while !errors.fileHandleForReading.availableData.isEmpty {}
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var buffer = Data()
                while true {
                    let data = output.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token,
                                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                                  let type = message["type"] as? String else { return }
                            if type == "progress" { progress(message["page"] as? Int ?? 0, message["total"] as? Int ?? 0) }
                            else if type == "ready", let path = message["root"] as? String {
                                self.generation = UUID(); self.process = nil
                                do {
                                    let root = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                                    guard root.path.hasPrefix(library.standardizedFileURL.resolvingSymlinksInPath().path + "/PDF/") else { throw ReaderError(message: "Invalid PDF import path.") }
                                    let manifest = try JSONDecoder().decode(PDFManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
                                    let chapters = try manifest.chapters.map { Chapter(url: try EPUBBook.safeURL($0.path, relativeTo: root, root: root), title: $0.title) }
                                    guard !chapters.isEmpty else { throw ReaderError(message: "No readable PDF content.") }
                                    let contents = manifest.contents.map { ContentsEntry(title: $0.title, chapter: 0, anchor: $0.anchor, depth: $0.depth) }
                                    completion(.success(EPUBBook(source: source, root: root, title: manifest.title, chapters: chapters, contents: contents, initialChapter: 0)))
                                } catch { completion(.failure(error)) }
                            } else if type == "error" {
                                self.generation = UUID(); self.process = nil
                                completion(.failure(ReaderError(message: message["message"] as? String ?? "Couldn’t read this PDF.")))
                            }
                        }
                    }
                }
                process.waitUntilExit()
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.process = nil
                    completion(.failure(ReaderError(message: "PDF import didn’t finish. Try opening it again.")))
                }
            }
        } catch { completion(.failure(error)) }
    }
}
