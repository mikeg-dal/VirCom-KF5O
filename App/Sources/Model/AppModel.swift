import AppKit
import UniformTypeIdentifiers
import VirComKit

/// Software settings (VirCom's "Software Setting" dialog).
struct SoftwareSettings: Codable, Equatable {
    var defaultListenPort: UInt16 = ZLProtocol.defaultDataPort
    var reconnectSeconds = 5
    var disableBroadcastSearch = false
    var autoRefreshDevices = false
    var refreshSeconds = 10
    var monitorEnabled = true
    var monitorBufferBytes = 65_536
    var monitorHex = true
    var monitorTimestamps = true
    var startServiceOnLaunch = true
    var startMinimized = false
    /// Local UDP port for management traffic (0 = any).
    var managementLocalPort: UInt16 = 0
}

/// A range of addresses searched by unicast ("Add Manually" in VirCom).
struct ManualRange: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var start: String
    var end: String
}

/// Everything VirCom persisted in its config file; also what Export/Import Setting writes.
struct SavedState: Codable, Equatable {
    var settings = SoftwareSettings()
    var ports: [VirtualPortConfig] = []
    var manualRanges: [ManualRange] = []
}

/// Live status of one virtual port.
struct PortStatus: Equatable {
    var ptyPath = ""
    var linked = false
    var counters = BridgeCounters()
    var lastMessage = ""
}

/// One line of the data monitor.
struct MonitorEntry: Identifiable {
    let id = UUID()
    let date: Date
    let direction: BridgeDirection
    let bytes: [UInt8]
}

@Observable
final class AppModel {
    var state: SavedState { didSet { save() } }
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var searching = false
    private(set) var serviceRunning = false
    private(set) var status: [UUID: PortStatus] = [:]
    private(set) var monitor: [UUID: [MonitorEntry]] = [:]
    private(set) var info: [String] = []
    var alert: AlertInfo?
    /// The download tool window's state.
    let downloads = DownloadToolModel()
    /// The 4G config tool window's state.
    let fourG = FourGToolModel()

    struct AlertInfo: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    @ObservationIgnored private var bridges: [UUID: VirtualPortBridge] = [:]
    @ObservationIgnored private var bridgeTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var counterTask: Task<Void, Never>?

    private static let key = "VirComState.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(SavedState.self, from: data) {
            state = s
        } else {
            state = SavedState()
        }
        log("Virtual Serial & Device Management started.")
        if state.settings.startServiceOnLaunch { startService() }
        updateAutoRefresh()
        Task { await search() }
    }

    /// UI-test mode (`-VirComBlockDeviceWrites YES -VirComSampleDevice YES`): the device list holds
    /// one made-up device and the network is never searched, so tests run the same everywhere.
    static let sampleMode = DeviceWriteGuard.blocked && UserDefaults.standard.bool(forKey: "VirComSampleDevice")

    static func sampleDevice() -> DiscoveredDevice {
        var p = DeviceParameters(raw: [UInt8](repeating: 0, count: ZLProtocol.parameterSize))
        p.applyFactoryDefaults()
        p.raw.replaceSubrange(0x15..<0x1D, with: Array("ZLSN2000".utf8))
        p.raw.replaceSubrange(0x1F..<0x25, with: [0x53, 0x41, 0x4D, 0x50, 0x4C, 0x45])
        p.raw[0x67] = 69
        p.raw[0x68] = 0xFF
        p.ip = IPv4(10, 0, 0, 200)
        p.name = "SAMPLE"
        return DiscoveredDevice(parameters: p, replyAddress: p.ip, replyPort: ZLProtocol.managementPort,
                                lastSeen: .now, manual: true)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func log(_ s: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        info.append("[\(stamp)] \(s)")
        if info.count > 2000 { info.removeFirst(info.count - 2000) }
    }

    func clearInfo() { info.removeAll() }

    var client: ManagementClient { ManagementClient(localPort: state.settings.managementLocalPort) }

    // MARK: - Devices

    func search() async {
        guard !searching else { return }
        if Self.sampleMode {
            devices = [Self.sampleDevice()]
            log("Sample mode: 1 made-up device, no network search.")
            return
        }
        searching = true
        defer { searching = false }
        var found: [DiscoveredDevice] = []
        do {
            if !state.settings.disableBroadcastSearch {
                found += try await client.search()
            }
            for r in state.manualRanges {
                found += try await client.searchRange(start: r.start, end: r.end)
            }
        } catch {
            log("Search failed: \(error.localizedDescription)")
        }
        var merged: [UInt32: DiscoveredDevice] = [:]
        for d in found { merged[d.id] = merged[d.id] ?? d }
        for d in devices where d.serialPort != nil && merged[d.id] == nil { merged[d.id] = d }
        devices = merged.values.sorted { $0.parameters.ip < $1.parameters.ip }
        log("Found \(devices.count) device(s).")
    }

    /// Adds a serial server found with "Search With Serial Port".
    /// Opens a device's web page in the browser. Some firmware sends nothing for "/" and only
    /// answers when the page is named, so try "/" first, then index.html and index.htm.
    /// Returns a message to show when none of them answer.
    func openWebPage(_ device: DiscoveredDevice) async -> String? {
        let p = device.parameters
        let base = "http://\(p.ip)" + (p.httpPort == 80 || p.httpPort == 0 ? "" : ":\(p.httpPort)")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for path in ["/", "/index.html", "/index.htm"] {
            guard let url = URL(string: base + path) else { continue }
            if let (data, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode < 400, !data.isEmpty {
                NSWorkspace.shared.open(url)
                return nil
            }
        }
        return "\(p.name.isEmpty ? p.deviceID : p.name) at \(base) didn't return a web page. "
            + "The device may be restarting, or its web page files may be missing. Use Send Files to Device to send them again."
    }

    func addSerialDevice(_ p: DeviceParameters, port: String, baud: Int) {
        var d = DiscoveredDevice(parameters: p, replyAddress: p.ip, replyPort: ZLProtocol.managementPort,
                                 lastSeen: .now, manual: false)
        d.serialPort = port
        d.serialBaud = baud
        devices.removeAll { $0.id == d.id }
        devices.append(d)
        log("Found device \(p.deviceID) with \(baud) bps on \(port).")
    }

    func addManualRange(start: String, end: String) async {
        do {
            let found = try await client.searchRange(start: start, end: end)
            state.manualRanges.append(ManualRange(start: start, end: end.isEmpty ? start : end))
            log("Range \(start) – \(end): found \(found.count) device(s).")
            await search()
        } catch {
            alert = AlertInfo(title: "Device Search IP Range", message: error.localizedDescription)
        }
    }

    func removeManualRange(_ r: ManualRange) {
        state.manualRanges.removeAll { $0.id == r.id }
    }

    func updateAutoRefresh() {
        refreshTask?.cancel()
        guard state.settings.autoRefreshDevices else { return }
        let seconds = max(state.settings.refreshSeconds, 2)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                await self?.search()
            }
        }
    }

    /// Writes parameters to a device. It restarts to apply them, so search again afterwards.
    func write(_ params: DeviceParameters, to device: DiscoveredDevice) async -> Bool {
        if let port = device.serialPort {
            do {
                let baud = device.serialBaud
                try await Task.detached { try SerialSearch.writeSerialServer(params, port: port, baud: baud) }.value
                log("Settings sent to \(device.parameters.deviceID) through \(port).")
                if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i].parameters = params }
                return true
            } catch {
                alert = AlertInfo(title: "Modify Setting", message: error.localizedDescription)
                return false
            }
        }
        do {
            try await client.write(params, unicastTo: device.manual ? device : nil)
            log("Settings sent to \(device.parameters.name) (\(device.parameters.deviceID)). Please wait for the device to restart.")
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await self?.search()
            }
            return true
        } catch {
            alert = AlertInfo(title: "Modify Setting", message: error.localizedDescription)
            return false
        }
    }

    func changeKey(_ params: DeviceParameters, old: String, new: String, device: DiscoveredDevice) async -> Bool {
        do {
            try await client.changeKey(params, old: old, new: new, device: device)
            log("Key changed on \(device.parameters.deviceID).")
            return true
        } catch {
            alert = AlertInfo(title: "Modify Device Key", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Save As Default / Load Default

    private static let defaultParametersKey = "VirComDefaultParameters.v1"

    var hasDefaultParameters: Bool { UserDefaults.standard.data(forKey: Self.defaultParametersKey) != nil }

    func saveDefaultParameters(_ p: DeviceParameters) {
        UserDefaults.standard.set(Data(p.raw), forKey: Self.defaultParametersKey)
        log("Saved \(p.deviceID)'s settings as the default.")
    }

    /// The saved template with the target device's identity (type, ID, firmware, capabilities) kept.
    func loadDefaultParameters(into current: DeviceParameters) -> DeviceParameters? {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultParametersKey), data.count == ZLProtocol.parameterSize else { return nil }
        var t = DeviceParameters(raw: [UInt8](data))
        for range in [0x15..<0x25, 0x64..<0x65, 0x67..<0x69, 0x70..<0x71] {
            t.raw.replaceSubrange(range, with: current.raw[range])
        }
        return t
    }

    func boundPort(for device: DiscoveredDevice) -> VirtualPortConfig? {
        state.ports.first { $0.boundDeviceID == device.parameters.deviceID }
    }

    // MARK: - Virtual ports

    func nextPortName() -> String {
        var n = 1
        while state.ports.contains(where: { $0.name == "COM\(n)" }) { n += 1 }
        return "COM\(n)"
    }

    func addPorts(_ template: VirtualPortConfig, count: Int, increase: BatchIncrease) {
        var cfg = template
        for i in 0..<max(count, 1) {
            if i > 0 {
                cfg.id = UUID()
                cfg.name = nextPortName()
                switch increase {
                case .ip:
                    if let ip = IPv4(cfg.host) { cfg.host = IPv4(value: ip.value + 1).description }
                case .port:
                    cfg.port &+= 1
                    cfg.listenPort &+= 1
                }
            }
            state.ports.append(cfg)
            log("Create \(cfg.name) ok!")
            if serviceRunning { startBridge(cfg) }
        }
    }

    func updatePort(_ cfg: VirtualPortConfig) {
        guard let i = state.ports.firstIndex(where: { $0.id == cfg.id }) else { return }
        state.ports[i] = cfg
        if serviceRunning {
            stopBridge(cfg.id)
            startBridge(cfg)
        }
    }

    func deletePorts(_ ids: Set<UUID>) {
        for id in ids { stopBridge(id) }
        state.ports.removeAll { ids.contains($0.id) }
        for id in ids { status[id] = nil; monitor[id] = nil }
    }

    func bind(device: DiscoveredDevice, to portID: UUID?) {
        for i in state.ports.indices where state.ports[i].boundDeviceID == device.parameters.deviceID {
            state.ports[i].boundDeviceID = nil
        }
        guard let portID, let i = state.ports.firstIndex(where: { $0.id == portID }) else { return }
        var cfg = state.ports[i]
        cfg.boundDeviceID = device.parameters.deviceID
        // Follow the device's work mode: a TCP-server device is connected to, a TCP-client device connects in.
        switch device.parameters.workMode {
        case .tcpClient:
            cfg.role = .listen
            cfg.listenPort = device.parameters.destinationPort
        default:
            cfg.role = .connect
            cfg.host = device.parameters.ip.description
            cfg.port = device.parameters.devicePort
        }
        updatePort(cfg)
    }

    func startService() {
        guard !serviceRunning else { return }
        serviceRunning = true
        log("Start service.")
        for cfg in state.ports where cfg.enabled { startBridge(cfg) }
        counterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.refreshCounters()
            }
        }
    }

    func stopService() {
        guard serviceRunning else { return }
        serviceRunning = false
        for id in bridges.keys { stopBridge(id) }
        counterTask?.cancel()
        log("Stop service.")
    }

    func connectNow(_ id: UUID) { bridges[id]?.connectNow() }

    private func startBridge(_ cfg: VirtualPortConfig) {
        let bridge = VirtualPortBridge(config: cfg, reconnectInterval: state.settings.reconnectSeconds)
        bridges[cfg.id] = bridge
        status[cfg.id] = PortStatus()
        bridgeTasks[cfg.id] = Task { [weak self] in
            for await e in bridge.events { self?.handle(e, port: cfg) }
        }
        do {
            try bridge.start()
        } catch {
            log("\(cfg.name): \(error.localizedDescription)")
            status[cfg.id]?.lastMessage = error.localizedDescription
        }
    }

    private func stopBridge(_ id: UUID) {
        bridges[id]?.stop()
        bridges[id] = nil
        bridgeTasks[id]?.cancel()
        bridgeTasks[id] = nil
        status[id]?.linked = false
    }

    private func handle(_ e: BridgeEvent, port: VirtualPortConfig) {
        switch e {
        case .ptyReady(let path):
            status[port.id]?.ptyPath = path
            log("\(port.name) is available at \(path)")
        case .linkUp(let s):
            status[port.id]?.linked = true
            status[port.id]?.lastMessage = s
            log("\(port.name): \(s)")
        case .linkDown(let err):
            status[port.id]?.linked = bridges[port.id]?.isLinked ?? false
            if let err { status[port.id]?.lastMessage = err; log("\(port.name): \(err)") }
        case .log(let s):
            status[port.id]?.lastMessage = s
            log("\(port.name): \(s)")
        case .data(let dir, let bytes):
            guard state.settings.monitorEnabled else { return }
            var list = monitor[port.id, default: []]
            list.append(MonitorEntry(date: .now, direction: dir, bytes: bytes))
            var total = list.reduce(0) { $0 + $1.bytes.count }
            while total > state.settings.monitorBufferBytes, !list.isEmpty {
                total -= list.removeFirst().bytes.count
            }
            monitor[port.id] = list
        }
    }

    private func refreshCounters() {
        for (id, b) in bridges {
            let c = b.counters
            if status[id]?.counters != c { status[id]?.counters = c }
        }
    }

    func clearMonitor(_ id: UUID) { monitor[id] = [] }

    // MARK: - Export / import

    func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VirCom-settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(state).write(to: url)
            log("Exported settings to \(url.lastPathComponent).")
        } catch {
            alert = AlertInfo(title: "Couldn't export settings", message: error.localizedDescription)
        }
    }

    func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
            let wasRunning = serviceRunning
            stopService()
            state = s
            if wasRunning { startService() }
            updateAutoRefresh()
            log("Imported settings from \(url.lastPathComponent).")
        } catch {
            alert = AlertInfo(title: "Couldn't import settings", message: error.localizedDescription)
        }
    }
}

enum BatchIncrease: String, CaseIterable, Identifiable {
    case ip, port
    var id: String { rawValue }
    var title: String { self == .ip ? "IP Increase" : "Port Increase" }
}

/// Local IPv4 addresses, for the "Local IP" button.
enum LocalAddresses {
    static func primary() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
