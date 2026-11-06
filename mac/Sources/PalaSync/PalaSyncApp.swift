import SwiftUI
import AppKit

@main
struct PalaSyncApp: App {
    @StateObject private var model = SyncModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The log window is managed with AppKit so it never opens by itself at
/// launch (a SwiftUI `Window` scene would).
enum LogWindow {
    private static var window: NSWindow?

    static func show(model: SyncModel) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Pala Sync"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LogView().environmentObject(model))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: SyncModel

    var body: some View {
        Text(model.statusLine)
        if let summary = model.lastSummary {
            Text(summary)
        }

        Divider()

        Button(model.isSyncing ? "Synchronisiert …" : "Jetzt synchronisieren") {
            model.startSync()
        }
        .keyboardShortcut("s")
        .disabled(model.isSyncing)

        Button("Zitate anzeigen …") {
            QuotesWindow.show(store: model.quoteStore)
        }
        .keyboardShortcut("z")

        Button("Protokoll anzeigen") {
            LogWindow.show(model: model)
        }

        Divider()

        if let folder = model.sourceFolder {
            Text("Ordner: \(folder.lastPathComponent)")
        }
        Button("Sync-Ordner wählen …") {
            model.chooseFolder()
        }
        Toggle("Automatisch beim Anstecken", isOn: $model.autoSync)
        Toggle("Beim Anmelden starten", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Pala Sync beenden") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

struct LogView: View {
    @EnvironmentObject var model: SyncModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusLine).font(.headline)
                    if let summary = model.lastSummary {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(model.isSyncing ? "Synchronisiert …" : "Jetzt synchronisieren") {
                    model.startSync()
                }
                .disabled(model.isSyncing)
            }

            if model.isSyncing {
                if let p = model.progress {
                    ProgressView(value: p) { Text(model.currentStep) }
                } else {
                    ProgressView { Text(model.currentStep) }
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logText.isEmpty ? "Noch kein Sync in dieser Sitzung." : model.logText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.logText) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            HStack {
                if let folder = model.sourceFolder {
                    Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Ordner wählen …") { model.chooseFolder() }
                Button("Protokolldatei") { model.revealLogFile() }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
    }
}
