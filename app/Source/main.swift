import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: ReaderController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = CommandLine.arguments
            let testing = args.contains("--self-test")
            let library: URL
            if testing {
                let testIndex = args.firstIndex(of: "--self-test")!
                library = URL(fileURLWithPath: args[testIndex + 2]).appendingPathComponent("library", isDirectory: true)
            } else {
                library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadAlong/Books", isDirectory: true)
            }
            let reader = try ReaderController(library: library, testing: testing)
            controller = reader
            if testing {
                let i = args.firstIndex(of: "--self-test")!
                let tests = SelfTests(reader: reader, directory: URL(fileURLWithPath: args[i+2]))
                reader.onReady = { tests.start() }
                reader.window.orderBack(nil)
                reader.openBook(URL(fileURLWithPath: args[i+1]))
            } else {
                // Launch behind the user's active app; they can open it from the Dock.
                reader.window.orderBack(nil)
                let specified = args.dropFirst().first(where: { ["epub", "pdf"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) })
                let previous = reader.defaults.string(forKey: "lastBook")
                if let path = [specified, previous].compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) { reader.openBook(URL(fileURLWithPath: path)) }
            }
        } catch { print(error.localizedDescription); NSApp.terminate(nil) }
    }
    func application(_ application: NSApplication, open urls: [URL]) { if let url = urls.first { controller?.openBook(url) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { controller?.stopPlayback(); controller?.speech.shutdown(); controller?.pdfImporter.cancel() }
}

let app = NSApplication.shared
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = appDelegate
app.setActivationPolicy(CommandLine.arguments.contains("--self-test") ? .accessory : .regular)
app.run()
