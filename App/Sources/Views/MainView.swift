import SwiftUI
import VirComKit

/// VirCom's main window: the virtual serial ports and the information log.
struct MainView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<UUID> = []
    @State private var editing: VirtualPortConfig?
    @State private var adding = false

    var body: some View {
        VSplitView {
            portTable
                .frame(minHeight: 200)
            infoLog
                .frame(minHeight: 100, idealHeight: 160)
        }
        .toolbar { toolbar }
        .navigationTitle("VirCom")
        .navigationSubtitle(model.serviceRunning ? "Service running" : "Service stopped")
        .sheet(isPresented: $adding) {
            PortEditorView(model: model, config: VirtualPortConfig(name: model.nextPortName()), isNew: true)
        }
        .sheet(item: $editing) { cfg in
            PortEditorView(model: model, config: cfg, isNew: false)
        }
        .alert(item: $model.alert) { a in Alert(title: Text(a.title), message: Text(a.message)) }
        .frame(minWidth: 860, minHeight: 480)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.serviceRunning ? model.stopService() : model.startService()
            } label: {
                Label(model.serviceRunning ? "Stop Service" : "Start Service",
                      systemImage: model.serviceRunning ? "stop.circle" : "play.circle")
            }
            Button { openWindow(id: "devices") } label: { Label("Device Management", systemImage: "network") }
            Button { adding = true } label: { Label("Add Virtual Port", systemImage: "plus") }
            Button { openWindow(id: "monitor") } label: { Label("Monitor", systemImage: "waveform.path.ecg") }
            Button { model.clearInfo() } label: { Label("Clear Information", systemImage: "trash") }
        }
    }

    private var portTable: some View {
        Table(model.state.ports, selection: $selection) {
            TableColumn("Com Name") { p in
                HStack {
                    Circle().fill(color(for: p)).frame(width: 8, height: 8)
                    Text(p.name)
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Virtual Port Path") { p in
                Text(model.status[p.id]?.ptyPath ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .width(min: 110, ideal: 130)
            TableColumn("Mode") { p in Text(p.role == .connect ? "TCP Client" : "TCP Server") }
                .width(min: 70, ideal: 80)
            TableColumn("Device") { p in
                Text(p.role == .connect ? "\(p.host):\(String(p.port))" : "listen :\(String(p.listenPort))")
            }
            .width(min: 120, ideal: 150)
            TableColumn("Bind ID") { p in Text(p.boundDeviceID ?? String(localized: "Not bound")) }
                .width(min: 90, ideal: 110)
            TableColumn("Status") { p in
                Text(statusText(p)).foregroundStyle(model.status[p.id]?.linked == true ? .green : .secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Sent / Received") { p in
                let c = model.status[p.id]?.counters ?? .init()
                Text("\(c.sent) / \(c.received)").monospacedDigit()
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first, let cfg = model.state.ports.first(where: { $0.id == id }) {
                Button("Edit…") { editing = cfg }
                if let path = model.status[id]?.ptyPath, !path.isEmpty {
                    Button("Copy Port Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
                if cfg.role == .connect { Button("Connect Now") { model.connectNow(id) } }
                Divider()
            }
            Button("Delete", role: .destructive) { model.deletePorts(ids) }
                .disabled(ids.isEmpty)
        } primaryAction: { ids in
            if let id = ids.first { editing = model.state.ports.first { $0.id == id } }
        }
        .overlay {
            if model.state.ports.isEmpty {
                ContentUnavailableView {
                    Label("No Virtual Serial Ports", systemImage: "cable.connector")
                } description: {
                    Text("Add a virtual serial port, or bind one to a device in Device Management.")
                } actions: {
                    Button("Add Virtual Port") { adding = true }
                }
            }
        }
    }

    private var infoLog: some View {
        GroupBox("Information") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.info.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onChange(of: model.info.count) { proxy.scrollTo(model.info.count - 1, anchor: .bottom) }
            }
        }
        .padding(8)
    }

    private func color(for p: VirtualPortConfig) -> Color {
        guard model.serviceRunning else { return .secondary.opacity(0.4) }
        return model.status[p.id]?.linked == true ? .green : .orange
    }

    private func statusText(_ p: VirtualPortConfig) -> String {
        guard model.serviceRunning else { return String(localized: "Stopped") }
        guard let s = model.status[p.id] else { return "" }
        return s.linked ? String(localized: "Established") : String(localized: "Not Established")
    }
}
