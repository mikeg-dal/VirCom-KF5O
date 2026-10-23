import SwiftUI
import VirComKit

/// VirCom's "Device Management" window: search, list and edit serial servers.
struct DeviceManagerView: View {
    @Bindable var model: AppModel
    @State private var selection: Set<DiscoveredDevice.ID> = []
    @State private var batchTips = false
    @State private var webPageError: String?
    @State private var showRange = false
    @State private var showSerial = false
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""

    private var rows: [DiscoveredDevice] {
        guard !filter.isEmpty else { return model.devices }
        // VirCom's search is case sensitive and matches name, IP, ID, etc.
        return model.devices.filter { d in
            let p = d.parameters
            return [p.name, p.ip.description, p.deviceID, p.deviceType, p.destinationHost].contains { $0.contains(filter) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            deviceTable
            Divider()
            sidePanel
        }
        .searchable(text: $filter, prompt: "Name, IP, ID…")
        .navigationTitle("Device Management")
        .navigationSubtitle("\(model.devices.count) device(s)")
        .frame(minWidth: 980, minHeight: 360)
        .sheet(isPresented: $batchTips) {
            BatchEditTipsView(count: selectedDevices.count) { edit in
                let ids = selectedDevices.sorted { $0.parameters.ip < $1.parameters.ip }.map(\.id)
                openWindow(id: "device-settings", value: DeviceEditRequest(deviceIDs: ids, batch: edit))
            }
        }
        .sheet(isPresented: $showRange) { RangeSearchView(model: model) }
        .alert("Can't open the web page", isPresented: Binding(get: { webPageError != nil }, set: { if !$0 { webPageError = nil } })) {
            Button("OK") { webPageError = nil }
        } message: { Text(webPageError ?? "") }
        .sheet(isPresented: $showSerial) { SerialSearchView(model: model) { openWindow(id: "4g") } }
    }

    private var deviceTable: some View {
            Table(rows, selection: $selection) {
                Group {
                    TableColumn("Type", value: \DiscoveredDevice.typeText).width(min: 70, ideal: 80)
                    TableColumn("Name", value: \DiscoveredDevice.nameText).width(min: 70, ideal: 90)
                    TableColumn("Dev IP", value: \DiscoveredDevice.ipText).width(min: 100, ideal: 110)
                    TableColumn("Dev Port", value: \DiscoveredDevice.portText).width(min: 55, ideal: 60)
                    TableColumn("Work Mode", value: \DiscoveredDevice.modeText).width(min: 70, ideal: 80)
                    TableColumn("Dest IP", value: \DiscoveredDevice.destinationText).width(min: 100, ideal: 120)
                }
                Group {
                    TableColumn("Dest Port", value: \DiscoveredDevice.destinationPortText).width(min: 55, ideal: 60)
                    TableColumn("Virtual Serial") { (d: DiscoveredDevice) in Text(boundName(d)) }
                        .width(min: 80, ideal: 90)
                    TableColumn("Dev ID") { (d: DiscoveredDevice) in
                        Text(d.parameters.deviceID).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 100, ideal: 110)
                    TableColumn("Serial", value: \DiscoveredDevice.serialText).width(min: 90, ideal: 100)
                    TableColumn("Found") { (d: DiscoveredDevice) in Text(found(d)) }.width(min: 60, ideal: 70)
                }
            }
            .contextMenu(forSelectionType: DiscoveredDevice.ID.self) { ids in
                if ids.count > 1 {
                    Button("Edit \(ids.count) Devices…") { edit(ids) }
                } else if let d = device(ids.first) {
                    Button("Edit Device…") { edit(ids) }
                    Button("Open Web Page") {
                        Task {
                            if let message = await model.openWebPage(d) { webPageError = message }
                        }
                    }
                }
            } primaryAction: { ids in
                edit(ids)
            }
            .overlay {
                if model.devices.isEmpty, !model.searching {
                    ContentUnavailableView("No Devices Found", systemImage: "antenna.radiowaves.left.and.right",
                                           description: Text("Click Auto Search. Devices must be on this Mac's network, or add their IP range with Add Manually."))
                }
            }
    }

    private var sidePanel: some View {
            VStack(spacing: 10) {
                Button { Task { await model.search() } } label: { Text("Auto Search").frame(maxWidth: .infinity) }
                    .keyboardShortcut("r", modifiers: .command)
                Button { showRange = true } label: { Text("Add Manually").frame(maxWidth: .infinity) }
                Button { showSerial = true } label: { Text("Search Serial…").frame(maxWidth: .infinity) }
                Button { edit(selection) } label: { Text(selection.count > 1 ? "Edit \(selection.count) Devices" : "Edit Device").frame(maxWidth: .infinity) }
                    .disabled(selection.isEmpty)
                    .keyboardShortcut(.return, modifiers: [])
                Divider()
                Toggle("Auto refresh", isOn: $model.state.settings.autoRefreshDevices)
                    .onChange(of: model.state.settings.autoRefreshDevices) { model.updateAutoRefresh() }
                if model.searching { ProgressView().controlSize(.small) }
                Spacer()
                if !model.state.manualRanges.isEmpty {
                    GroupBox("Manual ranges") {
                        ForEach(model.state.manualRanges) { r in
                            HStack {
                                Text(r.start == r.end ? r.start : "\(r.start)–\(r.end)").font(.caption)
                                Spacer()
                                Button { model.removeManualRange(r) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 150)
    }

    private var selectedDevices: [DiscoveredDevice] { model.devices.filter { selection.contains($0.id) } }

    private func edit(_ ids: Set<DiscoveredDevice.ID>) {
        if ids.count > 1 {
            selection = ids
            batchTips = true
        } else {
            if let d = device(ids.first) {
                openWindow(id: "device-settings", value: DeviceEditRequest(deviceIDs: [d.id], batch: nil))
            }
        }
    }

    private func device(_ id: DiscoveredDevice.ID?) -> DiscoveredDevice? {
        guard let id else { return nil }
        return model.devices.first { $0.id == id }
    }

    private func boundName(_ d: DiscoveredDevice) -> String {
        model.boundPort(for: d)?.name ?? String(localized: "Not bound")
    }

    private func found(_ d: DiscoveredDevice) -> String {
        if let port = d.serialPort { return "Serial \((port as NSString).lastPathComponent)" }
        if d.manual { return String(localized: "Manual") }
        if let local = LocalAddresses.primary().flatMap(IPv4.init),
           !local.sameSubnet(as: d.parameters.ip, mask: d.parameters.subnetMask) {
            return String(localized: "Other subnet")
        }
        return String(localized: "Subnet")
    }
}

/// "Device Search IP Range" dialog.
struct RangeSearchView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""

    var body: some View {
        Form {
            TextField("Search start IP or domain", text: $start)
            TextField("Search end IP or domain", text: $end)
            Text("Devices in the range are searched by unicast on management port \(ZLProtocol.managementPort), so they can be on another subnet or across a router. The range is remembered.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task {
                        await model.addManualRange(start: start, end: end)
                        dismiss()
                    }
                }
                .disabled(start.isEmpty)
            }
        }
    }
}

/// Cell text for the device table.
extension DiscoveredDevice {
    var typeText: String { parameters.deviceType }
    var nameText: String { parameters.name }
    var ipText: String { parameters.ip.description }
    var portText: String { String(parameters.devicePort) }
    var modeText: String { parameters.workMode.title }
    var destinationText: String {
        parameters.destinationHost.isEmpty ? parameters.destinationIP.description : parameters.destinationHost
    }
    var destinationPortText: String { String(parameters.destinationPort) }
    var serialText: String {
        let p = parameters
        return "\(p.baudRate),\(p.dataBits),\(p.parity.title.prefix(1)),\(p.twoStopBits ? 2 : 1)"
    }
}
