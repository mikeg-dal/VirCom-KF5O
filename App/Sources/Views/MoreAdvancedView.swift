import SwiftUI
import VirComKit

// The panes that were VirCom's "More Advanced Settings" dialog. They edit a `MoreAdvancedSettings`
// that Device Settings folds into the parameter block when you click Modify Setting.

struct WiFiPane: View {
    @Binding var s: MoreAdvancedSettings

    var body: some View {
        Form {
            Section {
                Picker("WiFi work mode", selection: $s.wifiMode) {
                    Text("AP").tag(MoreAdvancedSettings.WiFiMode.ap)
                    Text("Station").tag(MoreAdvancedSettings.WiFiMode.station)
                }
                TextField("AP/STA SSID", text: $s.ssid)
                Picker("Encrypt type", selection: $s.encryption) {
                    ForEach(MoreAdvancedSettings.encryptions, id: \.code) { Text($0.title).tag($0.code) }
                }
                SecureField("AP/STA key", text: $s.wifiKey)
            } footer: {
                Text("Only for WiFi models. WEP64 needs a 5-character key, WEP128 a 13-character key.")
            }
            Section("Access point") {
                Picker("AP mode channel", selection: $s.apChannel) {
                    ForEach(1...11, id: \.self) { Text(String($0)).tag($0) }
                }
                Toggle("DHCP server", isOn: $s.dhcpServer)
                Toggle("RJ45–WiFi relay", isOn: $s.wiredRelay)
            }
            .disabled(s.wifiMode == .station)
        }
        .formStyle(.grouped)
    }
}

struct RS485Pane: View {
    @Binding var s: MoreAdvancedSettings
    let baudIndex: UInt8
    let baudRate: Int

    private var minimum: (wait: Int, idle: Int) { MoreAdvancedSettings.minimumTimes(baudIndex: baudIndex) }

    var body: some View {
        Form {
            Section {
                Picker("Modbus gateway type", selection: Binding(get: { s.gatewayType }, set: setGateway)) {
                    ForEach(MoreAdvancedSettings.GatewayType.allCases.filter { $0 != .preconfigured }) { Text($0.title).tag($0) }
                }
            }
            Section("Multi-host") {
                Toggle("Enable RS485 multi-host", isOn: $s.multiHostEnabled)
                LabeledContent("Max wait for a query reply") {
                    HStack {
                        TextField("Max wait", value: $s.multiHostWaitMs, format: .number.grouping(.never))
                            .labelsHidden().frame(width: 80)
                        Text("ms")
                    }
                }
                .disabled(!s.multiHostEnabled)
            }
            Section {
                Toggle("Enable RS485 bus conflict detection", isOn: $s.conflictDetection)
                LabeledContent("Send only when the bus is idle for") {
                    HStack {
                        TextField("Idle", value: $s.busIdleMs, format: .number).labelsHidden().frame(width: 80)
                        Text("ms")
                    }
                }
                .disabled(!s.conflictDetection)
                Picker("Frame end type", selection: $s.frameEndFlowControl) {
                    Text("None").tag(false)
                    Text("Flow Control").tag(true)
                }
                TextField("End byte (hex)", text: $s.frameEndByte)
            } header: {
                Text("Bus")
            } footer: {
                Text("Advised minimums at \(String(baudRate)) bps: wait \(minimum.wait) ms, idle \(minimum.idle) ms.")
            }
        }
        .formStyle(.grouped)
    }

    private func setGateway(_ t: MoreAdvancedSettings.GatewayType) {
        s.gatewayType = t
        if s.multiHostEnabled, s.multiHostWaitMs < minimum.wait { s.multiHostWaitMs = minimum.wait }
        if s.conflictDetection, s.busIdleMs < minimum.idle { s.busIdleMs = minimum.idle }
    }
}

struct DestinationsPane: View {
    @Binding var s: MoreAdvancedSettings

    var body: some View {
        Form {
            Section {
                ForEach(0..<7, id: \.self) { i in
                    HStack {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                        TextField("Address \(i + 1)", text: $s.destinations[i].host, prompt: Text("IP address or DNS name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        TextField("Port \(i + 1)", text: Binding(
                            get: { s.destinations[i].port == 0 ? "" : String(s.destinations[i].port) },
                            set: { s.destinations[i].port = UInt16($0.filter(\.isNumber)) ?? 0 }
                        ), prompt: Text("Port"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            } header: {
                Text("Extra destinations")
            } footer: {
                Text("The device also sends to these. Names are stored when any entry isn't an IP address (all names together ≤ 32 bytes).")
            }
        }
        .formStyle(.grouped)
    }
}

struct ProxyVLANPane: View {
    @Binding var s: MoreAdvancedSettings

    var body: some View {
        Form {
            Section("Proxy") {
                Toggle("Use a proxy server", isOn: $s.proxyEnabled)
                if s.proxyEnabled {
                    TextField("Proxy server IP", text: Binding(get: { s.proxyIP.description }, set: { if let v = IPv4($0) { s.proxyIP = v } }))
                    TextField("Port", value: $s.proxyPort, format: .number.grouping(.never))
                    Toggle("Needs authentication", isOn: $s.proxyAuthentication)
                    TextField("Name", text: $s.proxyName)
                    SecureField("Key", text: $s.proxyKey)
                }
            }
            Section("VLAN") {
                Toggle("Enable VLAN", isOn: $s.vlanEnabled)
                if s.vlanEnabled {
                    TextField("VLAN ID", value: $s.vlanID, format: .number)
                    Picker("VLAN priority", selection: $s.vlanPriority) {
                        ForEach(0...7, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("Net media type", selection: $s.mediaTypeFDDI) {
                        Text("Ethernet").tag(false)
                        Text("FDDI/Token Ring").tag(true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FunctionsPane: View {
    @Binding var s: MoreAdvancedSettings
    let capabilities: DeviceCapabilities

    var body: some View {
        Form {
            Section("Options") {
                Toggle("Changing settings needs the key", isOn: $s.keyToModify)
                Toggle("Receive broadcast", isOn: $s.receiveBroadcast)
                Toggle("P2P", isOn: $s.p2p)
                Toggle("Send MAC when TCP connects", isOn: $s.sendMACOnConnect)
                Toggle("Detect network using ping", isOn: $s.pingDetect)
                Toggle("Keep the serial buffer when a link opens", isOn: $s.keepSerialBuffer)
                Toggle("Need key when TCP connects", isOn: $s.keyOnTCPConnect)
            }
            Section("What this device supports") {
                ForEach(DeviceCapabilities.all, id: \.1) { cap, name in
                    Label(name, systemImage: capabilities.contains(cap) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(capabilities.contains(cap) ? .primary : .secondary)
                }
                ForEach(["IO Port Control", "UDP Group", "Multi-Dest IP", "Proxy Function", "SNMP Function", "P2P Function"], id: \.self) { f in
                    Label(f, systemImage: s.supported.contains(f) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(s.supported.contains(f) ? .primary : .secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
