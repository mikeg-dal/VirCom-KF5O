import SwiftUI
import VirComKit

// MARK: - MQTT

/// "MQTT connect settings" with the advanced settings inline. Saves mqtt.txt.
struct MQTTConfigView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var c: MQTTConfig
    @State private var setDestination: Bool
    @State private var error: String?

    private var tool: DownloadToolModel { model.downloads }

    init(model: AppModel) {
        self.model = model
        let tool = model.downloads
        var cfg = tool.read(ConfigFileName.mqtt).map { MQTTConfig(fileText: String(decoding: $0, as: UTF8.self)) } ?? MQTTConfig()
        if let d = tool.device, d.parameters.workMode == .tcpClient {
            cfg.serverHost = d.parameters.destinationHost.isEmpty ? d.parameters.destinationIP.description : d.parameters.destinationHost
            cfg.serverPort = d.parameters.destinationPort
        }
        _c = State(initialValue: cfg)
        _setDestination = State(initialValue: tool.device != nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("MQTT server IP or domain", text: $c.serverHost)
                TextField("MQTT server port", value: $c.serverPort, format: .number.grouping(.never))
                if let d = tool.device {
                    Toggle("Set \(d.parameters.name.isEmpty ? d.parameters.deviceID : d.parameters.name) to TCP Client with this destination", isOn: $setDestination)
                } else {
                    Text("Set the device to TCP Client with this server as destination in Device Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Server")
                    Spacer()
                    Menu("Cloud preset") {
                        ForEach(MQTTConfig.Preset.allCases) { p in Button(p.title) { c.apply(p) } }
                    }
                    .fixedSize()
                }
            }
            Section("Connection") {
                TextField("User name", text: $c.userName)
                SecureField("Key", text: $c.password)
                TextField("MQTT ID (client ID)", text: $c.clientID)
                TextField("Subscription topic", text: $c.subscribeTopic)
                TextField("Publish topic", text: $c.publishTopic)
            }
            Section("Advanced") {
                Picker("Protocol version", selection: $c.version) {
                    ForEach(MQTTConfig.Version.allCases) { Text($0.title).tag($0) }
                }
                TextField("Keep alive (s)", text: $c.keepAlive)
                flag("Clean session", $c.cleanSession)
                qos("Subscribe QoS", $c.subscribeQoS)
                qos("Publish QoS", $c.publishQoS)
                flag("Retain published messages", $c.publishRetain)
                flag("Enable will", $c.willFlag)
                TextField("Last-will topic", text: $c.willTopic)
                TextField("Last-will message", text: $c.willMessage)
                qos("Will QoS", $c.willQoS)
                flag("Last-will retain", $c.willRetain)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete") {
                    tool.remove(ConfigFileName.mqtt)
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await save() } } }
        }
        .alert("MQTT", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func flag(_ title: String, _ value: Binding<String>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue == "1" }, set: { value.wrappedValue = $0 ? "1" : "0" }))
    }

    private func qos(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(["0", "1", "2"], id: \.self) { Text($0).tag($0) }
        }
    }

    private func save() async {
        do {
            try tool.write(ConfigFileName.mqtt, Array(c.fileText.utf8))
        } catch {
            self.error = error.localizedDescription
            return
        }
        if setDestination, let d = tool.device, !c.serverHost.isEmpty {
            var p = d.parameters
            p.workMode = .tcpClient
            p.destinationHost = c.destinationHost()
            if let ip = IPv4(p.destinationHost) { p.destinationIP = ip }
            p.destinationPort = c.serverPort
            _ = await model.write(p, to: d)
        }
        dismiss()
    }
}

// MARK: - Modbus gateway

/// "Configurable Modbus GateWay Settings": a table of Modbus RTU polls mapped to Modbus TCP registers.
struct ModbusGatewayView: View {
    let tool: DownloadToolModel
    @Environment(\.dismiss) private var dismiss
    @State private var commands: [ModbusGatewayCommand]
    @State private var selection: ModbusGatewayCommand.ID?
    @State private var editing: ModbusGatewayCommand?
    @State private var error: String?

    init(tool: DownloadToolModel) {
        self.tool = tool
        _commands = State(initialValue: tool.read(ConfigFileName.modbusGateway).map(ModbusGatewayScript.parseDesignFile) ?? [])
    }

    private static let functions = [1: "01 Read coils", 2: "02 Read discrete inputs", 3: "03 Read holding registers", 4: "04 Read input registers"]

    var body: some View {
        VStack(spacing: 0) {
            Table(numbered, selection: $selection) {
                TableColumn("No.") { (c: Numbered) in Text(String(c.number)) }.width(36)
                TableColumn("Slave") { (c: Numbered) in Text(String(c.cmd.slaveAddress)) }.width(44)
                TableColumn("Function") { (c: Numbered) in Text(Self.functions[c.cmd.function] ?? String(c.cmd.function)) }
                TableColumn("RTU address") { (c: Numbered) in Text(String(c.cmd.registerAddress)) }.width(80)
                TableColumn("Length") { (c: Numbered) in Text(String(c.cmd.length)) }.width(50)
                TableColumn("Interval (ms)") { (c: Numbered) in Text(String(c.cmd.queryInterval)) }.width(80)
                TableColumn("Timeout (ms)") { (c: Numbered) in Text(String(c.cmd.replyTimeout)) }.width(80)
                TableColumn("05/06") { (c: Numbered) in Text(c.cmd.supportsWrite ? "Yes" : "") }.width(44)
                TableColumn("TCP address") { (c: Numbered) in Text(String(c.cmd.tcpRegisterAddress)) }.width(80)
            }
            .contextMenu(forSelectionType: ModbusGatewayCommand.ID.self) { _ in } primaryAction: { ids in
                editing = commands.first { $0.id == ids.first }
            }
            Divider()
            HStack {
                Button("Add") { editing = ModbusGatewayCommand() }
                Button("Edit") { editing = commands.first { $0.id == selection } }.disabled(selection == nil)
                Button("Delete") { commands.removeAll { $0.id == selection } ; renumber() }.disabled(selection == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save and Exit") { save() }.keyboardShortcut(.defaultAction).disabled(commands.isEmpty)
            }
            .padding()
        }
        .frame(width: 900, height: 420)
        .sheet(item: $editing) { c in
            ModbusCommandEditor(command: c, number: (commands.firstIndex { $0.id == c.id } ?? commands.count) + 1) { saved in
                if let i = commands.firstIndex(where: { $0.id == saved.id }) { commands[i] = saved } else { commands.append(saved) }
                renumber()
            }
        }
        .alert("Modbus gateway", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
        .onAppear { renumber() }
    }

    struct Numbered: Identifiable {
        var number: Int
        var cmd: ModbusGatewayCommand
        var id: UUID { cmd.id }
    }

    private var numbered: [Numbered] { commands.enumerated().map { Numbered(number: $0.offset + 1, cmd: $0.element) } }

    private func renumber() { _ = ModbusGatewayScript.assignAddresses(&commands) }

    private func save() {
        do {
            try tool.write(ConfigFileName.script, Array(ModbusGatewayScript.script(commands).utf8))
            try tool.write(ConfigFileName.modbusGateway, ModbusGatewayScript.designFile(commands))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "Add ZLMB Modbus Command".
struct ModbusCommandEditor: View {
    @State var command: ModbusGatewayCommand
    let number: Int
    let onSave: (ModbusGatewayCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            LabeledContent("Command No.", value: String(number))
            TextField("Slave address", value: $command.slaveAddress, format: .number.grouping(.never))
            Picker("Modbus function", selection: $command.function) {
                ForEach(1...4, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            TextField("Register address", value: $command.registerAddress, format: .number.grouping(.never))
            TextField("Register length", value: $command.length, format: .number.grouping(.never))
            TextField("RTU query interval (ms, more than 10)", value: $command.queryInterval, format: .number.grouping(.never))
            TextField("RTU reply timeout (ms)", value: $command.replyTimeout, format: .number.grouping(.never))
            Toggle("Support 05/06 commands (writes)", isOn: $command.supportsWrite)
            LabeledContent("Modbus TCP register address", value: "assigned on save")
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") {
                    onSave(command)
                    dismiss()
                }
                .disabled(!(1...247).contains(command.slaveAddress) || command.length < 1 || command.queryInterval <= 10)
            }
        }
    }
}

// MARK: - Register packet

/// "Register packet and heart beat packet settings". Writes httpd.txt (firmware 1.589 or later).
struct RegisterPacketView: View {
    let tool: DownloadToolModel
    @Environment(\.dismiss) private var dismiss
    @State private var c = RegisterPacketConfig()
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Long register and heartbeat packets are stored in the web page folder. The device firmware must be 1.589 or later (2003 model). Hexadecimal is entered with spaces, such as 01 02.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Register packet") {
                TextField("Content", text: $c.registerPacket)
                Toggle("ASCII", isOn: $c.registerIsASCII)
            }
            Section("Heartbeat packet") {
                TextField("Content", text: $c.heartbeatPacket)
                Toggle("ASCII", isOn: $c.heartbeatIsASCII)
                TextField("Interval (s)", value: $c.heartbeatInterval, format: .number.grouping(.never))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("OK") { save() } }
        }
        .alert("Register packet", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func save() {
        do {
            if let script = try c.script(existingScript: tool.existingScript()) {
                try tool.write(ConfigFileName.script, Array(script.utf8))
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - State transfer

/// "State Transfer Design": one page per state. Writes st.hex.
struct StateTransferView: View {
    let tool: DownloadToolModel
    @Environment(\.dismiss) private var dismiss
    @State private var states = [TransferState(number: 0)]
    @State private var selection = 0

    var body: some View {
        HSplitView {
            List(selection: Binding(get: { selection }, set: { selection = $0 ?? 0 })) {
                ForEach(states.indices, id: \.self) { i in Text("State \(i)").tag(i) }
            }
            .frame(minWidth: 120, maxWidth: 160)
            if states.indices.contains(selection) {
                StateEditor(state: $states[selection], number: selection)
            }
        }
        .frame(width: 720, height: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel Design") { dismiss() } }
            ToolbarItem(placement: .destructiveAction) {
                Button("Delete Design") {
                    tool.remove(ConfigFileName.stateTransfer)
                    dismiss()
                }
            }
            ToolbarItem {
                Button("Design Next State") {
                    states.append(TransferState(number: states.count))
                    selection = states.count - 1
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Complete Design") {
                    try? tool.write(ConfigFileName.stateTransfer, StateTransferFile.encode(states))
                    dismiss()
                }
            }
        }
    }
}

private struct StateEditor: View {
    @Binding var state: TransferState
    let number: Int

    var body: some View {
        Form {
            Section("Action of state \(number)") {
                Picker("Action", selection: $state.sendsCommand) {
                    Text("No action, just wait").tag(false)
                    Text("Send the following command").tag(true)
                }
                .pickerStyle(.radioGroup)
                if state.sendsCommand {
                    TextField("Command", text: $state.command, axis: .vertical).lineLimit(2...4)
                    Toggle("HEX", isOn: $state.commandIsHex)
                }
            }
            Section("State transfer") {
                Toggle("After a delay", isOn: $state.delayEnabled)
                if state.delayEnabled {
                    TextField("Delay (ms)", value: $state.delayMs, format: .number.grouping(.never))
                    TextField("Then go to state", value: $state.delayTarget, format: .number)
                }
                Toggle("When no data is sent or received", isOn: $state.idleEnabled)
                if state.idleEnabled {
                    TextField("For (ms)", value: $state.idleMs, format: .number.grouping(.never))
                    TextField("Then go to state", value: $state.idleTarget, format: .number)
                }
                Toggle("When any data is sent or received", isOn: $state.dataEnabled)
                if state.dataEnabled {
                    TextField("Go to state", value: $state.dataTarget, format: .number)
                }
            }
        }
        .formStyle(.grouped)
    }
}
