import Foundation

struct ReadingVoice {
    let identifier: String
    let name: String
    let gender: String
    static let catalog = [
        ReadingVoice(identifier: "af_heart", name: "Heart", gender: "Female"),
        ReadingVoice(identifier: "af_bella", name: "Bella", gender: "Female"),
        ReadingVoice(identifier: "am_michael", name: "Michael", gender: "Male"),
        ReadingVoice(identifier: "am_fenrir", name: "Fenrir", gender: "Male")
    ]
}

struct AudioWord {
    let index: Int
    let start: Double
}
struct NeuralAudio {
    let data: Data
    let words: [AudioWord]
    let duration: Double
}
enum SpeechPriority: String { case foreground, background }

private struct SpeechCacheKey: Hashable {
    let voice: String
    let speed: Double
    let text: String
    let wordRanges: [Int]
    init(_ unit: SpeechUnit, voice: ReadingVoice, speed: Double) {
        self.voice = voice.identifier; self.speed = speed; text = unit.text
        wordRanges = unit.words.flatMap { [$0.start, $0.length] }
    }
}
private struct CachedSpeech {
    let data: Data
    let starts: [Double]
    let duration: Double
    var touched: Int
    func audio(for unit: SpeechUnit) -> NeuralAudio {
        NeuralAudio(data: data, words: zip(unit.words, starts).map { AudioWord(index: $0.index, start: $1) }, duration: duration)
    }
}

@MainActor
final class NeuralSpeech {
    private var process: Process?
    private var input: FileHandle?
    private var completions: [String: (Result<NeuralAudio, Error>) -> Void] = [:]
    private var inFlight: [SpeechCacheKey: String] = [:]
    private var waiters: [String: [(SpeechUnit, (Result<NeuralAudio, Error>) -> Void)]] = [:]
    private var pending: [(String, Data)] = []
    private var ready = false
    private var diagnostics = ""
    private var epoch = UUID().uuidString
    private var cache: [SpeechCacheKey: CachedSpeech] = [:]
    private var access = 0
    private(set) var cacheBytes = 0
    private(set) var cacheHits = 0
    private(set) var generatedCount = 0
    var cachedCount: Int { cache.count }

    func hasCachedAudio(_ unit: SpeechUnit, voice: ReadingVoice, speed: Double = 1) -> Bool {
        cache[SpeechCacheKey(unit, voice: voice, speed: speed)] != nil
    }

    func start() throws {
        if let process = process, process.isRunning { return }
        guard let resources = Bundle.main.resourceURL else { throw ReaderError(message: "Missing speech resources.") }
        let process = Process(), output = Pipe(), input = Pipe(), errors = Pipe()
        process.executableURL = resources.appendingPathComponent("Python/bin/python3.13")
        process.arguments = ["-u", resources.appendingPathComponent("SpeechWorker.py").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = resources.appendingPathComponent("SpeechPackages").path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["OMP_NUM_THREADS"] = "2"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        self.process = process; self.input = input.fileHandleForWriting; ready = false; diagnostics = ""
        let outputHandle = output.fileHandleForReading
        // Drain diagnostics separately so a full pipe cannot stall narration.
        let errorHandle = errors.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = errorHandle.availableData
                if data.isEmpty { break }
                let message = String(decoding: data, as: UTF8.self)
                Task { @MainActor [weak self] in
                    guard let self = self, self.process === process else { return }
                    self.diagnostics = String((self.diagnostics + message).suffix(4000))
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let data = outputHandle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                    Task { @MainActor [weak self] in self?.receive(line) }
                }
            }
            Task { @MainActor [weak self] in self?.failed(process) }
        }
    }

    func request(_ unit: SpeechUnit, voice: ReadingVoice, speed: Double = 1, priority: SpeechPriority = .foreground, completion: @escaping (Result<NeuralAudio, Error>) -> Void) {
        let key = SpeechCacheKey(unit, voice: voice, speed: speed)
        if var cached = cache[key] {
            access += 1; cached.touched = access; cache[key] = cached; cacheHits += 1
            completion(.success(cached.audio(for: unit))); return
        }
        if let id = inFlight[key] {
            waiters[id, default: []].append((unit, completion)); return
        }
        do {
            try start()
            let id = UUID().uuidString
            let text = unit.text as NSString
            let words = unit.words.map { ["index": $0.index, "text": text.substring(with: NSRange(location: $0.start, length: $0.length))] as [String: Any] }
            let request: [String: Any] = ["id": id, "epoch": epoch, "text": unit.text, "words": words, "voice": voice.identifier, "speed": speed, "priority": priority.rawValue]
            var data = try JSONSerialization.data(withJSONObject: request); data.append(10)
            inFlight[key] = id; waiters[id] = [(unit, completion)]
            completions[id] = { [weak self] result in
                guard let self = self else { return }
                if self.inFlight[key] == id { self.inFlight.removeValue(forKey: key) }
                if case .success(let audio) = result { self.remember(audio, key: key) }
                let callbacks = self.waiters.removeValue(forKey: id) ?? []
                for (requested, callback) in callbacks {
                    callback(result.map { audio in
                        NeuralAudio(data: audio.data, words: zip(requested.words, audio.words).map { AudioWord(index: $0.index, start: $1.start) }, duration: audio.duration)
                    })
                }
            }
            if ready { try input?.write(contentsOf: data) } else { pending.append((id, data)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self = self, let callback = self.completions.removeValue(forKey: id) else { return }
                callback(.failure(ReaderError(message: "Speech generation timed out.")))
                self.shutdown()
            }
        } catch { completion(.failure(error)) }
    }

    private func remember(_ audio: NeuralAudio, key: SpeechCacheKey) {
        generatedCount += 1
        if let existing = cache.removeValue(forKey: key) { cacheBytes -= existing.data.count }
        access += 1
        cache[key] = CachedSpeech(data: audio.data, starts: audio.words.map { $0.start }, duration: audio.duration, touched: access)
        cacheBytes += audio.data.count
        // Keep recent and nearby sentences without accumulating a whole book.
        while cache.count > 64 || cacheBytes > 48 * 1024 * 1024 {
            guard let oldest = cache.min(by: { $0.value.touched < $1.value.touched })?.key,
                  let removed = cache.removeValue(forKey: oldest) else { break }
            cacheBytes -= removed.data.count
        }
    }

    private func receive(_ line: Data) {
        guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if response["ready"] as? Bool == true {
            ready = true
            let requests = pending; pending = []
            for (_, data) in requests { try? input?.write(contentsOf: data) }
            return
        }
        guard let id = response["id"] as? String, let completion = completions.removeValue(forKey: id) else { return }
        if let message = response["error"] as? String { completion(.failure(ReaderError(message: message))); return }
        guard let encoded = response["audio"] as? String, let audio = Data(base64Encoded: encoded), let values = response["words"] as? [[String: Any]], let duration = response["duration"] as? Double else { completion(.failure(ReaderError(message: "Invalid speech response."))); return }
        let words = values.compactMap { value -> AudioWord? in
            guard let index = value["index"] as? Int, let start = value["start"] as? Double else { return nil }
            return AudioWord(index: index, start: start)
        }
        guard !audio.isEmpty, !words.isEmpty else { completion(.failure(ReaderError(message: "Empty speech response."))); return }
        completion(.success(NeuralAudio(data: audio, words: words, duration: duration)))
    }

    private func failed(_ source: Process) {
        guard process === source else { return }
        process = nil; input = nil; ready = false; pending = []
        let callbacks = completions; completions = [:]
        for completion in callbacks.values { completion(.failure(ReaderError(message: "Speech engine stopped. " + diagnostics))) }
    }

    func cancel() {
        completions = [:]; inFlight = [:]; waiters = [:]; pending = []; epoch = UUID().uuidString
        if ready, var data = try? JSONSerialization.data(withJSONObject: ["op": "cancel", "epoch": epoch]) {
            data.append(10); try? input?.write(contentsOf: data)
        }
    }
    func shutdown() { cancel(); input = nil; if process?.isRunning == true { process?.terminate() }; process = nil }
}
