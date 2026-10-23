import SwiftUI
import VirComKit

/// VirCom's "Device Settings" (and "More Advanced Settings") for one serial server, as one window:
/// a sidebar of sections, actions in the toolbar, and one Modify Setting that sends everything.
struct DeviceSettingsView: View {
    let model: AppModel
    let device: DiscoveredDevice
    /// Other selected devices when editing several at once.
    var batch: BatchGroup? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    enum Pane: String, CaseIterable, Identifiable {
        case device = "Device", network = "Network", serial = "Serial", options = "Options"
        case wifi = "WiFi", rs485 = "RS485", destinations = "Destinations", proxy = "Proxy & VLAN", functions = "Functions"
        case raw = "Raw Bytes"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .device: "info.circle"
            case .network: "network"
            case .serial: "cable.connector"
            case .options: "gearshape"
            case .wifi: "wifi"
            case .rs485: "point.3.connected.trianglepath.dotted"
            case .destinations: "arrow.triangle.branch"
            case .proxy: "shield.lefthalf.filled"
            case .functions: "switch.2"
            case .raw: "number"
            }
        }
        static let groups: [(String, [Pane])] = [
            ("Device", [.device, .network, .serial, .options]),
            ("Advanced", [.wifi, .rs485, .destinations, .proxy, .functions]),
            ("Diagnostics", [.raw]),
        ]
    }

    @State private var pane: Pane? = .device
    @State private var p: DeviceParameters
    @State private var adv: MoreAdvancedSettings
    @State private var ipText: String
    @State private var maskText: String
    @State private var gatewayText: String
    @State private var dnsText: String
    @State private var groupText: String
    @State private var boundPort: UUID?
    @State private var register: DeviceRegisterPacket
    @State private var registerASCII = false
    @State private var showKey = false
    @State private var showQR = false
    @State private var confirmRestart = false
    @State private var warning: String?
    @State private var error: String?
    @State private var webPageError: String?
    @State private var busy = false

    init(model: AppModel, device: DiscoveredDevice, batch: BatchGroup? = nil) {
        self.model = model
        self.device = device
        self.batch = batch
        let p = device.parameters
        _p = State(initialValue: p)
        _adv = State(initialValue: MoreAdvancedSettings(p))
        _ipText = State(initialValue: p.ip.description)
        _maskText = State(initialValue: p.subnetMask.description)
        _gatewayText = State(initialValue: p.gateway.description)
        _dnsText = State(initialValue: p.dnsServer.description)
        _groupText = State(initialValue: p.udpGroupIP.description)
        _boundPort = State(initialValue: model.boundPort(for: device)?.id)
        _register = State(initialValue: DeviceRegisterPacket(p))
    }

    private var caps: DeviceCapabilities { p.capabilities }
    private var title: String {
        if let batch { return "Device Settings — \(batch.devices.count) devices" }
        let port = p.portNumber > 0 ? " PORT\(p.portNumber)" : ""
        return "Device Settings — \(p.name.isEmpty ? p.deviceID : p.name)\(port)"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.groups, id: \.0) { group, panes in
                    Section(group) {
                        ForEach(panes) { pane in
                            Label(pane.rawValue, systemImage: pane.symbol)
                                .tag(pane)
                                .accessibilityIdentifier("pane.\(pane.rawValue)")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .frame(minWidth: 820, minHeight: 560)
        .navigationTitle(title)
        .toolbar { toolbar }
        .sheet(isPresented: $showKey) { KeyChangeView(model: model, device: device, parameters: (try? collected()) ?? p) }
        .sheet(isPresented: $showQR) { QRCodeView(text: p.deviceID) }
        .alert("Can't apply settings", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
        .alert("Can't open the web page", isPresented: Binding(get: { webPageError != nil }, set: { if !$0 { webPageError = nil } })) {
            Button("OK") { webPageError = nil }
        } message: { Text(webPageError ?? "") }
        .confirmationDialog(warning ?? "", isPresented: Binding(get: { warning != nil }, set: { if !$0 { warning = nil } })) {
            Button("Send Anyway") { Task { await send() } }
            Button("Change It", role: .cancel) {}
        }
        .confirmationDialog("Restart the device?", isPresented: $confirmRestart) {
            Button("Restart") { Task { await apply() } }
        } message: {
            Text("The current settings are sent to the device, which restarts to apply them.")
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { showKey = true } label: { Label("Modify Key", systemImage: "key") }
                .help("Change the device's key")
                .accessibilityIdentifier("toolbar.modifyKey")
            Button {
                Task {
                    if let message = await model.openWebPage(device) { webPageError = message }
                }
            } label: { Label("Web Page", systemImage: "safari") }
                .help("Open the device's web page")
                .accessibilityIdentifier("toolbar.webPage")
            Button {
                model.downloads.target(device)
                openWindow(id: "download")
            } label: { Label("Send Files", systemImage: "square.and.arrow.up.on.square") }
                .help("Send web pages, configuration or firmware to this device")
                .accessibilityIdentifier("toolbar.sendFiles")
            Menu {
                Button("Get Factory Defaults") {
                    p.applyFactoryDefaults()
                    syncFromParameters()
                }
                Divider()
                Button("Save As My Default") { if let q = try? collected() { model.saveDefaultParameters(q) } }
                Button("Load My Default") {
                    if let t = model.loadDefaultParameters(into: p) {
                        p = t
                        syncFromParameters()
                    }
                }
                .disabled(!model.hasDefaultParameters)
            } label: { Label("Defaults", systemImage: "arrow.counterclockwise") }
                .help("Factory defaults, or your own saved default")
                .accessibilityIdentifier("toolbar.defaults")
        }
    }

    private var bottomBar: some View {
        HStack {
            if let batch {
                Label("Applies to \(batch.devices.count) devices", systemImage: "square.stack.3d.up")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Restart Device") { confirmRestart = true }
                .accessibilityIdentifier("restartDevice")
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancel")
            Button("Modify Setting") { Task { await apply() } }
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
                .accessibilityIdentifier("modifySetting")
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var detail: some View {
        switch pane ?? .device {
        case .device: devicePane
        case .network: networkPane
        case .serial: serialPane
        case .options: optionsPane
        case .wifi: WiFiPane(s: $adv)
        case .rs485: RS485Pane(s: $adv, baudIndex: p.baudIndex, baudRate: p.baudRate)
        case .destinations: DestinationsPane(s: $adv)
        case .proxy: ProxyVLANPane(s: $adv)
        case .functions: FunctionsPane(s: $adv, capabilities: caps)
        case .raw: rawPane
        }
    }

    // MARK: Panes

    private var devicePane: some View {
        Form {
            Section("Device information") {
                LabeledContent("Type", value: p.deviceType)
                TextField("Name", text: Binding(get: { p.name }, set: { p.name = String($0.prefix(9)) }))
                LabeledContent("ID") {
                    HStack {
                        Text(p.deviceID).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button { showQR = true } label: { Image(systemName: "qrcode") }
                            .buttonStyle(.borderless)
                            .help("Show the device ID as a QR code")
                            .accessibilityLabel("Show QR Code")
                            .accessibilityIdentifier("showQRCode")
                    }
                }
                LabeledContent("Firmware", value: p.firmwareVersion)
            }
            Section {
                Picker("Virtual serial port", selection: $boundPort) {
                    Text("Not bound").tag(UUID?.none)
                    ForEach(model.state.ports) { Text($0.name).tag(Optional($0.id)) }
                }
            } footer: {
                Text("Binding a VirCom virtual port keeps it pointed at this device when its address or port changes.")
            }
        }
        .formStyle(.grouped)
    }

    private var networkPane: some View {
        Form {
            Section("Address") {
                Picker("IP mode", selection: $p.dhcp) {
                    Text("Static").tag(false)
                    Text("DHCP").tag(true)
                }
                TextField("IP address", text: $ipText).disabled(p.dhcp).accessibilityIdentifier("field.ip")
                TextField("Net mask", text: $maskText).disabled(p.dhcp)
                TextField("Gateway", text: $gatewayText).disabled(p.dhcp)
                TextField("DNS server", text: $dnsText)
            }
            Section {
                Picker("Work mode", selection: $p.workMode) {
                    ForEach(WorkMode.allCases) { Text($0.title).tag($0) }
                }
                TextField("Port", value: $p.devicePort, format: .number.grouping(.never))
                LabeledContent("Destination") {
                    HStack {
                        TextField("Destination", text: $p.destinationHost, prompt: Text("IP address or domain"))
                            .labelsHidden()
                        Button("This Mac") { if let ip = LocalAddresses.primary() { p.destinationHost = ip } }
                            .help("Use this Mac's IP address")
                    }
                }
                .disabled(p.workMode == .tcpServer)
                TextField("Destination port", value: $p.destinationPort, format: .number.grouping(.never))
                    .disabled(p.workMode == .tcpServer)
                Picker("Destination mode", selection: $p.dynamicDestination) {
                    Text("Static").tag(false)
                    Text("Dynamic").tag(true)
                }
                TextField("UDP group IP", text: $groupText)
                    .disabled(p.workMode != .udpGroup)
            } header: {
                Text("Connection")
            } footer: {
                Text(p.workMode == .tcpServer
                     ? "TCP Server: the device waits for computers to connect to its port."
                     : "Static destination mode is only useful for some UDP set-ups; otherwise use Dynamic.")
            }
        }
        .formStyle(.grouped)
    }

    private var serialPane: some View {
        Form {
            Section("Serial port") {
                Picker("Baud rate", selection: $p.baudIndex) {
                    ForEach(DeviceParameters.baudDisplayOrder, id: \.self) { i in
                        Text(i == 10 ? "76800/921600" : String(DeviceParameters.baudRates[Int(i)])).tag(i)
                    }
                }
                Picker("Data bits", selection: $p.dataBits) {
                    ForEach([8, 7, 6, 5], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Parity", selection: $p.parity) {
                    ForEach(DeviceParity.allCases) { Text($0.title).tag($0) }
                }
                Picker("Stop bits", selection: $p.twoStopBits) {
                    Text("1").tag(false)
                    Text("2").tag(true)
                }
                Picker("Flow control", selection: $p.flowControl) {
                    ForEach(DeviceFlowControl.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                LabeledContent("Max frame length") {
                    HStack {
                        TextField("Max frame length", value: $p.maxFrameLength, format: .number.grouping(.never)).labelsHidden().frame(width: 80)
                        Text("bytes")
                    }
                }
                LabeledContent("Max interval") {
                    HStack {
                        TextField("Max interval", value: $p.packetInterval, format: .number).labelsHidden().frame(width: 80)
                        Text("ms")
                    }
                }
            } header: {
                Text("Framing rule")
            } footer: {
                Text("Serial data is sent to the network when a frame reaches this length or the line is quiet this long. A smaller interval is better.")
            }
        }
        .formStyle(.grouped)
    }

    private var optionsPane: some View {
        Form {
            Section("Protocol") {
                Picker("Transfer protocol", selection: $p.transferProtocol) {
                    ForEach(TransferProtocol.allCases) { Text($0.title).tag($0) }
                }
                TextField("HTTP port", value: $p.httpPort, format: .number.grouping(.never))
            }
            Section("Connection keeping") {
                LabeledContent("Keep alive time") {
                    HStack {
                        TextField("Keep alive", value: $p.keepAliveSeconds, format: .number).labelsHidden().frame(width: 60)
                        Text("s")
                    }
                }
                LabeledContent("Reconnect time") {
                    HStack {
                        TextField("Reconnect", value: $p.reconnectSeconds, format: .number).labelsHidden().frame(width: 60)
                        Text("s")
                    }
                }
                Toggle("Restart when there's no data for \(Int(p.keepAliveSeconds) * 5) s", isOn: $p.restartWhenNoData)
                Toggle("Send parameters periodically", isOn: $p.sendParametersPeriodically)
                if p.sendParametersPeriodically {
                    LabeledContent("Every") {
                        HStack {
                            TextField("Minutes", value: $p.parameterSendMinutes, format: .number).labelsHidden().frame(width: 60)
                            Text("min")
                        }
                    }
                }
            }
            Section {
                Toggle("Send a register packet", isOn: $register.enabled)
                if register.enabled {
                    TextField("Packet", text: $register.content, prompt: Text("hex, e.g. 01 02"))
                    Toggle("Packet is ASCII text", isOn: $registerASCII)
                }
            } header: {
                Text("Register packet")
            } footer: {
                Text("Sent when the device connects, so a server can tell devices apart.")
            }
        }
        .formStyle(.grouped)
    }

    private var rawPane: some View {
        let q = (try? collected()) ?? p
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Parameter block as it will be sent (167 bytes)").font(.headline)
                Text(stride(from: 0, to: q.raw.count, by: 16).map { off in
                    String(format: "%02X: ", off) + q.raw[off..<min(off + 16, q.raw.count)].map { String(format: "%02X", $0) }.joined(separator: " ")
                }.joined(separator: "\n"))
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private func syncFromParameters() {
        ipText = p.ip.description; maskText = p.subnetMask.description
        gatewayText = p.gateway.description; dnsText = p.dnsServer.description
        groupText = p.udpGroupIP.description
        register = DeviceRegisterPacket(p)
        adv = MoreAdvancedSettings(p)
    }

    // MARK: Apply

    /// All panes folded into one parameter block.
    private func collected() throws -> DeviceParameters {
        var q = p
        if let v = IPv4(ipText) { q.ip = v }
        if let v = IPv4(maskText) { q.subnetMask = v }
        if let v = IPv4(gatewayText) { q.gateway = v }
        if let v = IPv4(dnsText) { q.dnsServer = v }
        if let v = IPv4(groupText) { q.udpGroupIP = v }
        // Devices without DNS support need the destination as an IP address.
        if let v = IPv4(q.destinationHost) { q.destinationIP = v }
        try adv.apply(to: &q)
        try register.apply(to: &q, asciiText: registerASCII)
        return q
    }

    /// The first problem and the pane it's on.
    private func validate() -> (Pane, String)? {
        for (label, text) in [("IP address", ipText), ("net mask", maskText), ("gateway", gatewayText), ("DNS server", dnsText)]
        where IPv4(text) == nil {
            return (.network, "The \(label) isn't a valid IP address.")
        }
        if IPv4(groupText) == nil { return (.network, "The UDP group IP isn't a valid IP address.") }
        if let ip = IPv4(ipText), ip.bytes.0 == 127 || ip.bytes.0 == 0 {
            return (.network, "The IP address isn't valid for a device.")
        }
        if p.devicePort == p.httpPort { return (.network, "The port can't be the same as the device's HTTP port.") }
        if p.dhcp, !caps.contains(.dhcp) { return (.network, "This device doesn't support DHCP.") }
        if p.workMode != .tcpServer, p.destinationHost.isEmpty { return (.network, "Enter a destination.") }
        if p.workMode != .tcpServer, IPv4(p.destinationHost) == nil, !caps.contains(.dns) {
            return (.network, "This device has no DNS support, so the destination must be an IP address.")
        }
        if p.transferProtocol == .realCOM, !caps.contains(.realCOM) { return (.options, "This device doesn't support REAL_COM.") }
        if p.transferProtocol == .modbusTCP, !caps.contains(.modbusTCP) {
            return (.options, "This device doesn't support Modbus TCP to RTU.")
        }
        if let e = adv.validate() {
            let pane: Pane = e.contains("WiFi") || e.contains("WEP") || e.contains("SSID") ? .wifi
                : e.contains("proxy") ? .proxy : .rs485
            return (pane, e)
        }
        do { _ = try collected() } catch { return (.options, error.localizedDescription) }
        return nil
    }

    private func apply() async {
        if let (where_, message) = validate() {
            pane = where_
            error = message
            return
        }
        let minimum = MoreAdvancedSettings.minimumTimes(baudIndex: p.baudIndex)
        if adv.multiHostEnabled, adv.multiHostWaitMs < minimum.wait {
            pane = .rs485
            warning = "At this baud rate the RS485 reply wait should be at least \(minimum.wait) ms."
            return
        }
        if adv.conflictDetection, adv.busIdleMs < minimum.idle {
            pane = .rs485
            warning = "At this baud rate the RS485 bus idle time should be at least \(minimum.idle) ms."
            return
        }
        await send()
    }

    private func send() async {
        guard let q = try? collected() else { return }
        busy = true
        defer { busy = false }
        if let batch {
            let all = batch.devices
            let params = batch.edit.apply(edited: q, original: device.parameters, to: all.map(\.parameters))
            var ok = true
            for r in params {
                guard let d = all.first(where: { $0.parameters.deviceKey == r.deviceKey }) else { continue }
                ok = await model.write(r, to: d) && ok
            }
            if ok { dismiss() }
            return
        }
        if await model.write(q, to: device) {
            // Keep the virtual-port binding in step with the new settings.
            if boundPort != nil || model.boundPort(for: device) != nil {
                var updated = device
                updated.parameters = q
                model.bind(device: updated, to: boundPort)
            }
            dismiss()
        }
    }
}

/// "Modify Device Key" dialog.
struct KeyChangeView: View {
    let model: AppModel
    let device: DiscoveredDevice
    let parameters: DeviceParameters
    @Environment(\.dismiss) private var dismiss
    @State private var old = ""
    @State private var new = ""
    @State private var retype = ""
    @State private var mismatch = false

    var body: some View {
        Form {
            Text("The default key of ZLSNxxx0/ZLSNxxx2 is 123456. By default ZLSNxxx3/ZLSNxxx4 have no key.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Old key", text: $old)
            SecureField("New key", text: $new)
            SecureField("Retype new key", text: $retype)
            if mismatch { Text("The new keys don't match.").foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") {
                    guard new == retype else { mismatch = true; return }
                    Task {
                        if await model.changeKey(parameters, old: old, new: new, device: device) { dismiss() }
                    }
                }
                .disabled(new.count > 9 || old.count > 9)
            }
        }
    }
}

/// Devices edited together and how their settings differ.
struct BatchGroup {
    var devices: [DiscoveredDevice]
    var edit: BatchEdit
}

/// VirCom's "Multi device editing tips".
struct BatchEditTipsView: View {
    let count: Int
    let onNext: (BatchEdit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var edit = BatchEdit()

    var body: some View {
        Form {
            Text("You're editing \(count) devices. In the next dialog change the first device's settings; Modify Setting applies them to every selected device, adjusted as chosen here (devices in IP order).")
                .fixedSize(horizontal: false, vertical: true)
            Picker("1. Last byte of each device's IP", selection: $edit.ipPolicy) {
                Text("Shift by the change made to the first device").tag(BatchEdit.IPPolicy.keepDifference)
                Text("Increase by one per device").tag(BatchEdit.IPPolicy.increment)
                Text("Same IP for all").tag(BatchEdit.IPPolicy.same)
            }
            .pickerStyle(.radioGroup)
            Picker("2. Destination port", selection: $edit.portPolicy) {
                Text("Increase by one per device").tag(BatchEdit.PortPolicy.increment)
                Text("Same port for all").tag(BatchEdit.PortPolicy.same)
            }
            .pickerStyle(.radioGroup)
            Toggle("3. Add a sequence number to the device name", isOn: $edit.numberNames)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Next Step") {
                    dismiss()
                    onNext(edit)
                }
            }
        }
    }
}

/// Opens Device Settings in its own window: the device (and any others edited with it) by ID.
struct DeviceEditRequest: Codable, Hashable {
    var deviceIDs: [UInt32]
    var batch: BatchEdit?
}

/// Window content for a `DeviceEditRequest`.
struct DeviceSettingsWindow: View {
    let model: AppModel
    let request: DeviceEditRequest?

    var body: some View {
        let devices = (request?.deviceIDs ?? []).compactMap { id in model.devices.first { $0.id == id } }
        if let first = devices.first {
            DeviceSettingsView(model: model, device: first,
                               batch: devices.count > 1 ? BatchGroup(devices: devices, edit: request?.batch ?? BatchEdit()) : nil)
                .id(request)
        } else {
            ContentUnavailableView("Device Not Found", systemImage: "network.slash",
                                   description: Text("Search again in Device Management."))
                .frame(minWidth: 400, minHeight: 240)
        }
    }
}
