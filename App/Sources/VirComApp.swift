import SwiftUI
import VirComKit

@main
struct VirComApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("VirCom", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 980, height: 600)
        .defaultLaunchBehavior(model.state.settings.startMinimized ? .suppressed : .presented)
        .commands { commands }

        Window("Device Management", id: "devices") {
            DeviceManagerView(model: model)
        }
        .defaultSize(width: 1100, height: 460)

        WindowGroup("Device Settings", id: "device-settings", for: DeviceEditRequest.self) { $request in
            DeviceSettingsWindow(model: model, request: request)
        }
        .defaultSize(width: 900, height: 640)

        Window("Send Files to Device", id: "download") {
            DownloadToolView(model: model)
        }
        .windowResizability(.contentSize)

        Window("4G Config Tools", id: "4g") {
            FourGToolView(tool: model.fourG) {
                model.downloads.viaSerial = true
                model.downloads.serialPort = model.fourG.port
                openWindow(id: "download")
            }
        }

        Window("Data Monitor", id: "monitor") {
            MonitorView(model: model)
        }

        Settings {
            SettingsView(model: model)
        }

        // Replaces VirCom's tray icon: the bridges keep running while windows are closed.
        MenuBarExtra("VirCom", systemImage: model.serviceRunning ? "cable.connector" : "cable.connector.slash") {
            Button("Show VirCom") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Button("Device Management") {
                openWindow(id: "devices")
                NSApp.activate()
            }
            Divider()
            Button(model.serviceRunning ? "Stop Service" : "Start Service") {
                model.serviceRunning ? model.stopService() : model.startService()
            }
            let linked = model.state.ports.filter { model.status[$0.id]?.linked == true }.count
            Text("\(linked) of \(model.state.ports.count) ports connected")
            Divider()
            Button("Quit VirCom") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @CommandsBuilder private var commands: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Manage") {
            Button(model.serviceRunning ? "Stop Service" : "Start Service") {
                model.serviceRunning ? model.stopService() : model.startService()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Device Management") { openWindow(id: "devices") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Search Devices") { Task { await model.search() } }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Send Files to Device") { openWindow(id: "download") }
            Button("4G Config Tools") { openWindow(id: "4g") }
        }
        CommandMenu("Config") {
            Button("Export Settings…") { model.exportSettings() }
            Button("Import Settings…") { model.importSettings() }
        }
        CommandGroup(after: .toolbar) {
            Button("Monitor") { openWindow(id: "monitor") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Clear Information") { model.clearInfo() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
        }
    }
}
