import Foundation
import AppKit
import ServiceManagement
import UserNotifications

/// Runs the bundled `pala-sync` program (the existing Python sync, packaged
/// with PyInstaller) and watches /dev for the Pala's USB serial port.
/// All published state is changed on the main queue.
final class SyncModel: ObservableObject {
    @Published var sourceFolder: URL?
    @Published var isSyncing = false
    @Published var deviceConnected = false
    @Published var currentStep = ""
    @Published var progress: Double?
    @Published var lastSummary: String?
    @Published var lastFailed = false
    @Published var logText = ""
    @Published var autoSync: Bool {
        didSet { UserDefaults.standard.set(autoSync, forKey: Keys.autoSync) }
    }
    @Published var launchAtLogin: Bool

    private enum Keys {
        static let folder = "sourceFolder"
        static let autoSync = "autoSync"
        static let summary = "lastSummary"
        static let failed = "lastFailed"
    }

    private var monitorTimer: Timer?
    private var process: Process?
    private var outputPipe: Pipe?
    private var lineBuffer = ""
    private var doneStats: [String: Int]?
    private var errorMessage: String?
    private var uploadedNames: [String] = []

    private static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("pCloud Drive/books-articles")

    let logFileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PalaSync.log")

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [Keys.autoSync: true])
        autoSync = d.bool(forKey: Keys.autoSync)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        lastSummary = d.string(forKey: Keys.summary)
        lastFailed = d.bool(forKey: Keys.failed)

        if let path = d.string(forKey: Keys.folder) {
            sourceFolder = URL(fileURLWithPath: path)
        } else if FileManager.default.fileExists(atPath: Self.defaultFolder.path) {
            // Existing setup: use the folder the terminal script used.
            sourceFolder = Self.defaultFolder
            d.set(Self.defaultFolder.path, forKey: Keys.folder)
        }

        // Do not auto-sync just because the app was started while the Pala
        // is already plugged in; only react to plugging it in.
        deviceConnected = !Self.serialPorts().isEmpty
        startMonitoring()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Status

    var menuIcon: String {
        if isSyncing { return "arrow.triangle.2.circlepath" }
        if lastFailed { return "exclamationmark.triangle" }
        return deviceConnected ? "book.fill" : "book"
    }

    var statusLine: String {
        if isSyncing { return currentStep.isEmpty ? "Synchronisiere …" : "Synchronisiere: \(currentStep)" }
        if sourceFolder == nil { return "Kein Sync-Ordner gewählt" }
        return deviceConnected ? "Pala verbunden" : "Pala nicht verbunden"
    }

    // MARK: - USB monitoring

    static func serialPorts() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.usbmodem") }.sorted()
    }

    private func startMonitoring() {
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkDevice()
        }
    }

    private func checkDevice() {
        let connected = !Self.serialPorts().isEmpty
        guard connected != deviceConnected else { return }
        deviceConnected = connected
        if connected && autoSync && !isSyncing && sourceFolder != nil {
            // Give the USB serial driver a moment before talking to the Pala.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.deviceConnected else { return }
                self.startSync()
            }
        }
    }

    // MARK: - Settings

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Sync-Ordner wählen"
        panel.message = "Ordner mit deinen TXT- und EPUB-Dateien (z. B. in pCloud Drive)"
        panel.prompt = "Auswählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = sourceFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            sourceFolder = url
            UserDefaults.standard.set(url.path, forKey: Keys.folder)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            appendLog("Anmeldeobjekt konnte nicht geändert werden: \(error.localizedDescription)")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func revealLogFile() {
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
        }
    }

    // MARK: - Sync

    private func syncCommand() -> (URL, [String])? {
        if let res = Bundle.main.resourceURL {
            let bin = res.appendingPathComponent("pala-sync/pala-sync")
            if FileManager.default.isExecutableFile(atPath: bin.path) { return (bin, []) }
        }
        // Development fallback: PALA_SYNC_SCRIPT=/path/to/tools/sync_books.py
        if let script = ProcessInfo.processInfo.environment["PALA_SYNC_SCRIPT"] {
            return (URL(fileURLWithPath: "/usr/bin/env"), ["python3", "-u", script])
        }
        return nil
    }

    func startSync() {
        guard !isSyncing else { return }
        guard let folder = sourceFolder else { chooseFolder(); return }
        guard let command = syncCommand() else {
            finishWithError("Das Sync-Programm fehlt in der App.")
            return
        }
        let (exe, prefixArgs) = command

        isSyncing = true
        currentStep = "Verbinde mit dem Pala"
        progress = nil
        doneStats = nil
        errorMessage = nil
        uploadedNames = []
        lineBuffer = ""
        logText = ""
        appendLog("=== Sync gestartet \(Self.timestamp()) – \(folder.path) ===")

        let p = Process()
        p.executableURL = exe
        p.arguments = prefixArgs + ["--source", folder.path, "--events"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async { self?.processEnded(code: code) }
        }

        do {
            try p.run()
            process = p
            outputPipe = pipe
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            isSyncing = false
            finishWithError("Sync konnte nicht gestartet werden: \(error.localizedDescription)")
        }
    }

    private func consume(_ text: String) {
        lineBuffer += text
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            lineBuffer = String(lineBuffer[lineBuffer.index(after: nl)...])
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("@@PALA ") {
            handleEvent(String(line.dropFirst(7)))
            return
        }
        appendLog(line)
        // pala_upload.py prints upload progress as "  45%  (1234/5678 bytes)"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let pctEnd = trimmed.firstIndex(of: "%"), let pct = Int(trimmed[..<pctEnd]) {
            progress = Double(min(max(pct, 0), 100)) / 100.0
        }
    }

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        let name = obj["name"] as? String ?? ""
        switch event {
        case "step":
            currentStep = name
            progress = nil
        case "uploading":
            currentStep = "Lade „\(Self.prettyName(name))“ hoch"
            progress = 0
        case "uploaded":
            uploadedNames.append(Self.prettyName(name))
            progress = nil
        case "deleted_local":
            currentStep = "Gelesen: \(Self.prettyName(name))"
        case "deleted_pala":
            currentStep = "Vom Pala entfernt: \(Self.prettyName(name))"
        case "error":
            errorMessage = obj["message"] as? String ?? "Unbekannter Fehler"
        case "done":
            var stats: [String: Int] = [:]
            for (k, v) in obj where k != "event" { stats[k] = v as? Int ?? 0 }
            doneStats = stats
        default:
            break
        }
    }

    private func processEnded(code: Int32) {
        if let pipe = outputPipe {
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { consume(String(decoding: rest, as: UTF8.self)) }
            if !lineBuffer.isEmpty { handleLine(lineBuffer); lineBuffer = "" }
        }
        process = nil
        outputPipe = nil
        isSyncing = false
        currentStep = ""
        progress = nil

        if let stats = doneStats, code == 0 {
            let summary = Self.summaryText(stats)
            setSummary("Zuletzt \(Self.shortTime()): \(summary)", failed: (stats["upload_failed"] ?? 0) > 0)
            appendLog("=== Fertig: \(summary) ===")
            notify(title: "Pala synchronisiert", body: summary)
        } else {
            finishWithError(errorMessage ?? "Sync abgebrochen (Code \(code)). Details im Protokoll.")
        }
    }

    private func finishWithError(_ message: String) {
        appendLog("=== Fehler: \(message) ===")
        setSummary("Zuletzt \(Self.shortTime()): Fehler – \(message)", failed: true)
        notify(title: "Pala-Sync fehlgeschlagen", body: message)
    }

    private func setSummary(_ text: String, failed: Bool) {
        lastSummary = text
        lastFailed = failed
        UserDefaults.standard.set(text, forKey: Keys.summary)
        UserDefaults.standard.set(failed, forKey: Keys.failed)
    }

    // MARK: - Helpers

    private func appendLog(_ line: String) {
        logText += line + "\n"
        let entry = line + "\n"
        if let data = entry.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logFileURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    static func summaryText(_ s: [String: Int]) -> String {
        var parts: [String] = []
        let up = s["uploaded"] ?? 0, read = s["deleted_local"] ?? 0
        let removed = s["deleted_pala"] ?? 0, quotes = s["quotes"] ?? 0, failed = s["upload_failed"] ?? 0
        if up > 0 { parts.append(up == 1 ? "1 Buch hochgeladen" : "\(up) Bücher hochgeladen") }
        if read > 0 { parts.append(read == 1 ? "1 gelesenes entfernt" : "\(read) gelesene entfernt") }
        if removed > 0 { parts.append("\(removed) vom Pala gelöscht") }
        if quotes > 0 { parts.append(quotes == 1 ? "1 neues Zitat" : "\(quotes) neue Zitate") }
        if failed > 0 { parts.append("\(failed) Upload(s) fehlgeschlagen") }
        return parts.isEmpty ? "alles aktuell" : parts.joined(separator: ", ")
    }

    static func prettyName(_ file: String) -> String {
        var n = (file as NSString).lastPathComponent
        for ext in [".txt", ".epub", ".md"] where n.lowercased().hasSuffix(ext) {
            n = String(n.dropLast(ext.count))
        }
        return n.replacingOccurrences(of: "_", with: " ")
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return f.string(from: Date())
    }

    static func shortTime() -> String {
        let f = DateFormatter()
        f.dateFormat = "dd.MM. HH:mm"
        return f.string(from: Date())
    }
}
