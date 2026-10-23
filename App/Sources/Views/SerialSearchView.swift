import SwiftUI
import VirComKit

/// VirCom's "Search With Serial Port": finds serial servers, ZLAN9500/9700 radios and 4G modules.
struct SerialSearchView: View {
    let model: AppModel
    let openFourG: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var port = SerialLink.availablePorts().first ?? ""
    @State private var baud: Int? = nil
    @State private var dataBits = 8
    @State private var parity: SerialParity = .none
    @State private var status = ""
    @State private var task: Task<Void, Never>?
    @State private var lora: LoRaSettings?
    @State private var loraBaud = 9600
    @State private var zigbee: ZigbeeSettings?

    var body: some View {
        Form {
            Picker("Serial port", selection: $port) {
                SerialPortOptions()
            }
            Picker("Baud rate", selection: $baud) {
                Text("Auto (try every rate)").tag(Int?.none)
                ForEach(SerialSearch.baudRates, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            Picker("Data bits", selection: $dataBits) {
                ForEach(5...8, id: \.self) { Text(String($0)).tag($0) }
            }
            Picker("Parity", selection: $parity) {
                ForEach(SerialParity.allCases) { Text($0.title).tag($0) }
            }
            if !status.isEmpty {
                HStack {
                    if task != nil { ProgressView().controlSize(.small) }
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    task?.cancel()
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Search") { search() }.disabled(port.isEmpty || task != nil)
            }
        }
        .sheet(item: Binding(get: { lora.map(LoRaBox.init) }, set: { lora = $0?.value })) { box in
            LoRaSettingsView(settings: box.value, port: port, baud: loraBaud, dataBits: dataBits, parity: parity) { status = $0 }
        }
        .sheet(item: Binding(get: { zigbee.map(ZigbeeBox.init) }, set: { zigbee = $0?.value })) { box in
            ZigbeeSettingsView(settings: box.value, port: port) { status = $0 }
        }
    }

    private func search() {
        let search = SerialSearch(port: port, baudRate: baud, dataBits: dataBits, parity: parity)
        let port = port
        task = Task {
            defer { task = nil }
            do {
                let result = try await search.run { s in Task { @MainActor in status = s } }
                switch result {
                case .serialServer(let p, let baud):
                    model.addSerialDevice(p, port: port, baud: baud)
                    status = "Found device with \(baud) bps. It's listed in Device Management."
                case .lora(let s, let baud):
                    status = "Found a ZLAN9700 LoRa module at \(baud) bps."
                    loraBaud = baud
                    lora = s
                case .zigbee(let s):
                    status = "Found a ZLAN9500 Zigbee module."
                    zigbee = s
                case .fourG(let baud):
                    status = "Found a 4G module at \(baud) bps."
                    model.fourG.port = port
                    model.fourG.baudRate = baud
                    openFourG()
                case nil:
                    status = "Can't find device through serial port."
                }
            } catch is CancellationError {
                status = ""
            } catch {
                status = error.localizedDescription
            }
        }
    }

    struct LoRaBox: Identifiable { let value: LoRaSettings; var id: Int { 0 } }
    struct ZigbeeBox: Identifiable { let value: ZigbeeSettings; var id: Int { 1 } }
}

/// "ZLAN9700/9743 Settings".
struct LoRaSettingsView: View {
    @State var settings: LoRaSettings
    let port: String
    let baud: Int
    let dataBits: Int
    let parity: SerialParity
    let report: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    var body: some View {
        Form {
            Section("LoRa Parameters") {
                LabeledContent("Firmware version", value: "V1.\(settings.firmware)")
                Stepper("Spread spectrum factor: \(settings.spreadingFactor)", value: $settings.spreadingFactor, in: 6...12)
                Text("6–12 (8, 9, 10 preferred); larger is slower.").font(.caption).foregroundStyle(.secondary)
                Picker("Bandwidth", selection: $settings.bandwidth) {
                    ForEach(LoRaSettings.bandwidths.indices, id: \.self) { Text(LoRaSettings.bandwidths[$0]).tag($0) }
                }
                Text("125K or 250K preferred.").font(.caption).foregroundStyle(.secondary)
                Stepper("Coding rate (CR): \(settings.codingRate)", value: $settings.codingRate, in: 1...4)
                LabeledContent("Frequency (MHz)") {
                    TextField("", value: $settings.frequency, format: .number.grouping(.never)).frame(width: 80)
                }
                Text("410–525 MHz. Use different frequencies for different networks.").font(.caption).foregroundStyle(.secondary)
                Picker("Baud rate", selection: $settings.baudIndex) {
                    ForEach(LoRaSettings.baudRates.indices, id: \.self) { Text(String(LoRaSettings.baudRates[$0])).tag($0) }
                }
                Picker("Parity", selection: $settings.parity) {
                    ForEach(LoRaSettings.parities.indices, id: \.self) { Text(LoRaSettings.parities[$0]).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem {
                Button("Defaults") { settings = LoRaSettings() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Write to Module") { modify() }
                    .disabled(busy || !(410...525).contains(settings.frequency))
            }
        }
    }

    private func modify() {
        busy = true
        let s = settings, port = port, baud = baud, bits = dataBits, parity = parity
        Task {
            let ok = (try? await Task.detached { try SerialSearch.writeLoRa(s, port: port, baud: baud, dataBits: bits, parity: parity) }.value) ?? false
            busy = false
            report(ok ? "LoRa settings written." : "The module couldn't save the LoRa settings.")
            dismiss()
        }
    }
}

/// "ZLAN9500 Settings".
struct ZigbeeSettingsView: View {
    @State var settings: ZigbeeSettings
    let port: String
    let report: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Zigbee Parameters") {
                LabeledContent("Node address") {
                    TextField("", value: $settings.nodeAddress, format: .number.grouping(.never)).frame(width: 80)
                }
                Text("0–65535; the central node is 0, broadcast is 65535.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Net ID") {
                    TextField("", value: $settings.netID, format: .number).frame(width: 80)
                }
                Text("0–255, the same in one network.").font(.caption).foregroundStyle(.secondary)
                Picker("Net type", selection: $settings.netType) {
                    ForEach(ZigbeeSettings.netTypes, id: \.code) { Text($0.title).tag($0.code) }
                }
                Picker("Node type", selection: $settings.nodeType) {
                    ForEach(ZigbeeSettings.nodeTypes, id: \.code) { Text($0.title).tag($0.code) }
                }
                Picker("Send mode", selection: $settings.sendMode) {
                    ForEach(ZigbeeSettings.sendModes.indices, id: \.self) { Text(ZigbeeSettings.sendModes[$0]).tag($0) }
                }
                Picker("Channel", selection: $settings.channel) {
                    ForEach(0...15, id: \.self) { Text(String($0)).tag($0) }
                }
                Picker("Source address output", selection: $settings.sourceOutput) {
                    ForEach(ZigbeeSettings.sourceOutputs.indices, id: \.self) { Text(ZigbeeSettings.sourceOutputs[$0]).tag($0) }
                }
                Picker("Address format", selection: $settings.addressFormat) {
                    ForEach(ZigbeeSettings.addressFormats.indices, id: \.self) { Text(ZigbeeSettings.addressFormats[$0]).tag($0) }
                }
            }
            Section("Serial Parameters") {
                Picker("Baud rate", selection: $settings.baudIndex) {
                    ForEach(ZigbeeSettings.baudRates.indices, id: \.self) { Text(String(ZigbeeSettings.baudRates[$0])).tag($0) }
                }
                Picker("Data bits", selection: $settings.dataBitsCode) {
                    ForEach(ZigbeeSettings.dataBits, id: \.code) { Text($0.title).tag($0.code) }
                }
                Picker("Parity", selection: $settings.parity) {
                    ForEach(ZigbeeSettings.parities.indices, id: \.self) { Text(ZigbeeSettings.parities[$0]).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem { Button("Defaults") { settings = ZigbeeSettings() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Write to Module") {
                    let s = settings, port = port
                    Task {
                        do {
                            try await Task.detached { try SerialSearch.writeZigbee(s, port: port) }.value
                            report("Zigbee settings written.")
                        } catch {
                            report(error.localizedDescription)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}
