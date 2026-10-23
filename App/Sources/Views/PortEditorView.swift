import SwiftUI
import VirComKit

/// "Add Virtual Serial Port" / edit dialog.
struct PortEditorView: View {
    let model: AppModel
    @State var config: VirtualPortConfig
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var batchCount = 1
    @State private var increase: BatchIncrease = .ip

    var body: some View {
        Form {
            Section {
                TextField("Port name", text: $config.name)
                Picker("VirCom work mode", selection: $config.role) {
                    ForEach(VirtualPortRole.allCases) { Text($0.title).tag($0) }
                }
                if config.role == .listen {
                    TextField("TCP server mode listen port", value: $config.listenPort, format: .number.grouping(.never))
                }
                Picker("Bind device", selection: $config.boundDeviceID) {
                    Text("Not bound").tag(String?.none)
                    ForEach(model.devices) { d in
                        Text("\(d.parameters.name) — \(d.parameters.ip.description) (\(d.parameters.deviceID))")
                            .tag(Optional(d.parameters.deviceID))
                    }
                }
                .onChange(of: config.boundDeviceID) { fillFromDevice() }
            }

            if config.role == .connect {
                Section("TCP Client Mode Settings") {
                    Toggle("Start connection now", isOn: $config.startConnectionNow)
                    TextField("Destination IP or domain", text: $config.host)
                    TextField("Destination port", value: $config.port, format: .number.grouping(.never))
                }
            }

            Section("Register, Login and Heartbeat") {
                Toggle("Send register ID", isOn: $config.registerEnabled)
                TextField("Register ID", text: $config.registerID).disabled(!config.registerEnabled)
                TextField("Login key", text: $config.loginKey)
                TextField("Heartbeat packet (hex)", text: $config.heartbeatHex, prompt: Text("e.g. 01 02 03"))
                LabeledContent("Heartbeat interval") {
                    HStack {
                        TextField("", value: $config.heartbeatSeconds, format: .number).frame(width: 60)
                        Text("s (0 = off)")
                    }
                }
            }

            if isNew {
                Section("Batch Create") {
                    Stepper("Number of ports: \(batchCount)", value: $batchCount, in: 1...64)
                    Picker("Batch increase mode", selection: $increase) {
                        ForEach(BatchIncrease.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(batchCount == 1)
                }
            }

            Section {
                Text("On macOS a virtual serial port is a pseudo-terminal. Apps open the /dev/ttys… path shown in the main window, just as they would open a USB serial adapter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .navigationTitle(isNew ? "Add Virtual Serial Port" : "Edit \(config.name)")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") {
                    if isNew { model.addPorts(config, count: batchCount, increase: increase) } else { model.updatePort(config) }
                    dismiss()
                }
                .disabled(config.name.isEmpty || !heartbeatValid)
            }
        }
    }

    private var heartbeatValid: Bool {
        config.heartbeatHex.isEmpty || VirtualPortBridge.hexBytes(config.heartbeatHex) != nil
    }

    private func fillFromDevice() {
        guard let id = config.boundDeviceID, let d = model.devices.first(where: { $0.parameters.deviceID == id }) else { return }
        if d.parameters.workMode == .tcpClient {
            config.role = .listen
            config.listenPort = d.parameters.destinationPort
        } else {
            config.role = .connect
            config.host = d.parameters.ip.description
            config.port = d.parameters.devicePort
        }
    }
}

/// VirCom's "Data Monitor".
struct MonitorView: View {
    @Bindable var model: AppModel
    @State private var portID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Port", selection: $portID) {
                    Text("Select a port").tag(UUID?.none)
                    ForEach(model.state.ports) { Text($0.name).tag(Optional($0.id)) }
                }
                .frame(width: 220)
                Toggle("HEX", isOn: $model.state.settings.monitorHex)
                Toggle("Time", isOn: $model.state.settings.monitorTimestamps)
                Spacer()
                if let id = portID {
                    let c = model.status[id]?.counters ?? .init()
                    Text("Written \(c.written)  Read \(c.read)  Sent \(c.sent)  Received \(c.received)")
                        .monospacedDigit().font(.caption)
                    Button("Clear") { model.clearMonitor(id) }
                }
            }
            if !model.state.settings.monitorEnabled {
                Text("The data monitor is off. Turn it on in Settings.").foregroundStyle(.orange)
            }
            HSplitView {
                pane(title: "Current Received Data", direction: .fromDevice)
                pane(title: "Current Send Data", direction: .toDevice)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 420)
        .onAppear { portID = portID ?? model.state.ports.first?.id }
    }

    private func pane(title: LocalizedStringKey, direction: BridgeDirection) -> some View {
        GroupBox(title) {
            ScrollView {
                Text(render(direction))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func render(_ dir: BridgeDirection) -> String {
        guard let id = portID else { return "Please select a line in the list before starting the monitor." }
        let entries = (model.monitor[id] ?? []).filter { $0.direction == dir }.suffix(500)
        let s = model.state.settings
        return entries.map { e in
            let body = s.monitorHex
                ? e.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
                : String(decoding: e.bytes, as: UTF8.self)
            return s.monitorTimestamps ? "[\(e.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))] \(body)" : body
        }.joined(separator: "\n")
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("VirCom") {
                TextField("Default listen port", value: $model.state.settings.defaultListenPort, format: .number.grouping(.never))
                Stepper("Reconnect to device every \(model.state.settings.reconnectSeconds) s",
                        value: $model.state.settings.reconnectSeconds, in: 1...300)
                Toggle("Start service when VirCom opens", isOn: $model.state.settings.startServiceOnLaunch)
                Toggle("Start hidden in the menu bar", isOn: $model.state.settings.startMinimized)
            }
            Section("Device Search") {
                Toggle("Disable device search through broadcast", isOn: $model.state.settings.disableBroadcastSearch)
                Toggle("Refresh the device list automatically", isOn: $model.state.settings.autoRefreshDevices)
                    .onChange(of: model.state.settings.autoRefreshDevices) { model.updateAutoRefresh() }
                Stepper("Every \(model.state.settings.refreshSeconds) s", value: $model.state.settings.refreshSeconds, in: 2...600)
                    .disabled(!model.state.settings.autoRefreshDevices)
                TextField("Local management UDP port (0 = any)", value: $model.state.settings.managementLocalPort,
                          format: .number.grouping(.never))
            }
            Section("Data Monitor") {
                Toggle("Enable (needs more memory)", isOn: $model.state.settings.monitorEnabled)
                TextField("Monitor buffer (bytes)", value: $model.state.settings.monitorBufferBytes, format: .number)
                Toggle("Hex display mode", isOn: $model.state.settings.monitorHex)
                Toggle("Display receive/send time", isOn: $model.state.settings.monitorTimestamps)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
    }
}
