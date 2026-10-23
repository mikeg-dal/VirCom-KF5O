import SwiftUI
import VirComKit

/// State of the "4G Config Tools" window.
@Observable
final class FourGToolModel {
    var port = SerialLink.availablePorts().first ?? ""
    var baudRate = 115_200
    var dataBits = 8
    var parity: SerialParity = .none
    var key = ""
    var command = ""
    var values: [String: String] = [:]
    private(set) var log = ""
    private(set) var configMode = false
    private(set) var loggedIn = false
    private(set) var busy = false
    var message: String?

    @ObservationIgnored private var session: FourGSession?
    @ObservationIgnored private var listener: Task<Void, Never>?

    var connected: Bool { session != nil }

    func append(_ s: String) {
        log += s.hasSuffix("\n") ? s : s + "\n"
        if log.count > 50_000 { log = String(log.suffix(40_000)) }
    }

    func clearLog() { log = "" }

    /// Runs `body` on a background task with the open session.
    private func run(_ title: String, _ body: @escaping @Sendable (FourGSession, @escaping @Sendable (String) -> Void) throws -> Void) {
        guard let session, !busy else { return }
        busy = true
        let logger: @Sendable (String) -> Void = { [weak self] s in Task { @MainActor in self?.append(s) } }
        Task.detached {
            do {
                try body(session, logger)
            } catch {
                await MainActor.run { self.message = "\(title): \(error.localizedDescription)" }
            }
            await MainActor.run { self.busy = false }
        }
    }

    func toggleConfigMode() {
        if session != nil { close(); return }
        do {
            session = try FourGSession(path: port, settings: .init(baudRate: baudRate, dataBits: dataBits, parity: parity))
        } catch {
            message = error.localizedDescription
            return
        }
        append("Entering config mode…")
        run("AT command mode") { s, log in
            let ok = try s.enterConfigMode(log: log)
            Task { @MainActor in
                self.configMode = ok
                if ok {
                    self.append("Entered config mode.")
                    self.readAll()
                } else {
                    self.message = "Couldn't enter AT command mode. Check the serial port and baud rate, then try again."
                    self.close()
                }
            }
        }
    }

    func close() {
        session = nil
        configMode = false
        loggedIn = false
    }

    func login() {
        let key = key
        run("Login") { s, _ in
            let ok = try s.login(key)
            Task { @MainActor in
                self.loggedIn = ok
                self.append(ok ? "Login OK" : "Login failed. Check the key.")
            }
        }
    }

    func readAll() {
        run("Get Parameter") { s, log in
            let v = try s.read(FourGCommand.info + FourGCommand.main + FourGCommand.advanced, log: log)
            Task { @MainActor in self.values.merge(v) { _, new in new } }
        }
    }

    func writeMain() { write(FourGCommand.main) }
    func writeAdvanced() { write(FourGCommand.advanced) }

    private func write(_ names: [String]) {
        guard loggedIn else { message = "Log in first."; return }
        let pairs = names.compactMap { n in values[n].map { (n, $0) } }
        run("Set parameters") { s, log in
            try s.write(pairs, log: log)
            Task { @MainActor in
                self.message = "Saved. The new parameters take effect after the module restarts."
            }
        }
    }

    func sendCommand() {
        guard loggedIn else { message = "Log in first."; return }
        let line = command
        run("Send") { s, log in
            try s.send(line)
            let reply = s.drain(timeout: .milliseconds(800))
            if !reply.isEmpty { log(reply) }
        }
    }
}

/// VirCom's "4G Config Tools" window.
struct FourGToolView: View {
    @Bindable var tool: FourGToolModel
    let openDownloadTool: () -> Void
    @State private var showAdvanced = false

    var body: some View {
        HSplitView {
            Form {
                Section("Step 1: connect (AT command mode, or send firmware or configuration)") {
                    Picker("Serial port", selection: $tool.port) {
                        SerialPortOptions()
                    }
                    Picker("Baud rate", selection: $tool.baudRate) {
                        ForEach(FourGCommand.baudRates.compactMap(Int.init), id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("Data bits", selection: $tool.dataBits) {
                        ForEach(5...8, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("Parity", selection: $tool.parity) {
                        ForEach(SerialParity.allCases) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Button(tool.connected ? "Close" : "AT Command Mode") { tool.toggleConfigMode() }
                            .disabled(tool.port.isEmpty || (tool.busy && !tool.connected))
                        Button("Send Firmware or Configuration…") { openDownloadTool() }
                            .help("Opens Send Files to Device, set up to send over this serial port.")
                    }
                }
                Section("Step 2: log in to change parameters") {
                    SecureField("Login key", text: $tool.key)
                    Button("Login") { tool.login() }.disabled(!tool.configMode || tool.busy)
                }
                Section("Step 3: main parameters") {
                    Picker("Baud rate", selection: binding("BAUD")) {
                        Text("—").tag("")
                        ForEach(FourGCommand.baudRates, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Destination IP or name", text: binding("PIPADD"))
                    TextField("Destination port", text: binding("PPORT"))
                    Picker("Protocol", selection: binding("PROTOCOL")) {
                        Text("—").tag("")
                        ForEach(FourGCommand.protocols, id: \.value) { Text($0.title).tag($0.value) }
                    }
                    HStack {
                        Button("Read Parameters") { tool.readAll() }
                        Button("Set Main Parameters") { tool.writeMain() }
                        Button("Advanced Parameters…") { showAdvanced = true }
                    }
                    .disabled(!tool.configMode || tool.busy)
                }
                Section("Status") {
                    LabeledContent("Config mode", value: tool.configMode ? "Entered" : "—")
                    LabeledContent("Login status", value: tool.loggedIn ? "Logged in" : "Not logged in")
                    if let id = tool.values["ID"] { LabeledContent("ID", value: id) }
                    if let v = tool.values["VER"] { LabeledContent("Version", value: v) }
                    if let s = tool.values["STAT"] { LabeledContent("State", value: s) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420)

            VStack(alignment: .leading) {
                Text("Information").font(.headline)
                ScrollView {
                    Text(tool.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .background(.background.secondary)
                HStack {
                    TextField("AT command", text: $tool.command).onSubmit { tool.sendCommand() }
                    Button("Send") { tool.sendCommand() }.disabled(!tool.configMode || tool.command.isEmpty)
                    Button("Clear") { tool.clearLog() }
                }
            }
            .padding()
            .frame(minWidth: 320)
        }
        .frame(minWidth: 820, minHeight: 620)
        .navigationTitle("4G Config Tools")
        .sheet(isPresented: $showAdvanced) { FourGAdvancedView(tool: tool) }
        .alert("4G Config Tools", isPresented: Binding(get: { tool.message != nil }, set: { if !$0 { tool.message = nil } })) {
            Button("OK") {}
        } message: { Text(tool.message ?? "") }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { tool.values[key] ?? "" }, set: { tool.values[key] = $0 })
    }
}

/// VirCom's "Advanced Parameters" for 4G modules.
struct FourGAdvancedView: View {
    @Bindable var tool: FourGToolModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Work parameters") {
                TextField("Work type (MODE)", text: binding("MODE"))
                TextField("DNS server IP", text: binding("PDNS"))
                TextField("Heartbeat interval", text: binding("HEARTIME"))
                TextField("Heartbeat content", text: binding("HEARTDAT"))
                Picker("Serial data bits", selection: binding("DATAB")) {
                    Text("—").tag("")
                    ForEach(FourGCommand.dataBits, id: \.self) { Text($0).tag($0) }
                }
                Picker("Serial parity", selection: binding("CHECKB")) {
                    Text("—").tag("")
                    ForEach(FourGCommand.parities, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Enable register packet", isOn: flag("EN_ENROL"))
                TextField("Register packet content", text: binding("ENROL"))
                TextField("APN", text: binding("APNN"))
                TextField("APN user name", text: binding("APN_USERNAME"))
                SecureField("APN key", text: binding("APN_PASSWORD"))
            }
            Section("MQTT parameters") {
                TextField("User name", text: binding("MQTT_USERNAME"))
                SecureField("Key", text: binding("MQTT_PASSWD"))
                TextField("Client ID", text: binding("MQTT_CLIENT"))
                TextField("Subscribe topic", text: binding("MQTT_SUBSCRIBE_TOPIC"))
                qos("Subscribe QoS", "MQTT_SUBSCRIBE_QOS")
                TextField("Publish topic", text: binding("MQTT_PUBLISH_TOPIC"))
                qos("Publish QoS", "MQTT_PUBLISH_QOS")
                TextField("Keep alive time", text: binding("MQTT_KEEPALIVE"))
                TextField("Last-will topic", text: binding("MQTT_WILL_TOPIC"))
                TextField("Last-will message", text: binding("MQTT_WILL_MESSAGE"))
            }
            Section("Remote device manage") {
                Toggle("Enable remote device manage", isOn: flag("Z_RMT_MAG"))
                TextField("Server IP/DNS", text: binding("Z_RMT_IP"))
                TextField("Server TCP port", text: binding("Z_RMT_PORT"))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Set") {
                    tool.writeAdvanced()
                    dismiss()
                }
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { tool.values[key] ?? "" }, set: { tool.values[key] = $0 })
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { tool.values[key] == "1" }, set: { tool.values[key] = $0 ? "1" : "0" })
    }

    private func qos(_ title: String, _ key: String) -> some View {
        Picker(title, selection: binding(key)) {
            Text("—").tag("")
            ForEach(["0", "1", "2"], id: \.self) { Text($0).tag($0) }
        }
    }
}
