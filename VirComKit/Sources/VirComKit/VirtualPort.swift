public import Foundation
public import Network
import Darwin
import Synchronization

/// How a virtual serial port reaches its device.
public enum VirtualPortRole: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The device is a TCP server: VirCom connects to it.
    case connect
    /// The device is a TCP client: VirCom listens and the device connects in.
    case listen
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .connect: "TCP Client (connect to device)"
        case .listen: "TCP Server (device connects in)"
        }
    }
}

/// A saved virtual serial port, like a row of VirCom's "Virtual Serial Port Management".
public struct VirtualPortConfig: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    /// User-facing name, like "COM5" on Windows.
    public var name: String
    public var role: VirtualPortRole = .connect
    public var host: String = "192.168.1.200"
    public var port: UInt16 = ZLProtocol.defaultDataPort
    public var listenPort: UInt16 = ZLProtocol.defaultDataPort
    /// Device this port is bound to (its ID), if any.
    public var boundDeviceID: String?
    /// Sent once after connecting (ASCII), when enabled.
    public var registerID: String = ""
    public var registerEnabled = false
    /// Sent once after connecting/registering (ASCII).
    public var loginKey: String = ""
    /// Hex bytes sent periodically while connected, e.g. "FE 01".
    public var heartbeatHex: String = ""
    public var heartbeatSeconds: Int = 0
    public var startConnectionNow = true
    public var enabled = true

    public init(name: String) { self.name = name }
}

public enum BridgeDirection: Sendable {
    /// From the device (network) to the virtual port.
    case fromDevice
    /// From an app using the virtual port to the device.
    case toDevice
}

public enum BridgeEvent: Sendable {
    case ptyReady(path: String)
    case linkUp(String)
    case linkDown(String?)
    case data(BridgeDirection, [UInt8])
    case log(String)
}

public struct BridgeCounters: Sendable, Equatable {
    /// Bytes written by apps to the virtual port.
    public var written = 0
    /// Bytes delivered to apps from the virtual port.
    public var read = 0
    /// Bytes sent to the device over TCP.
    public var sent = 0
    /// Bytes received from the device over TCP.
    public var received = 0

    public init() {}
}

/// Bridges a pseudo-terminal (the macOS stand-in for a Windows virtual COM port) to TCP.
public final class VirtualPortBridge: Sendable {
    public let config: VirtualPortConfig
    public let events: AsyncStream<BridgeEvent>
    private let continuation: AsyncStream<BridgeEvent>.Continuation
    private let queue: DispatchQueue

    private struct State {
        var master: Int32 = -1
        var slave: Int32 = -1
        var ptyPath = ""
        var ptySource: (any DispatchSourceRead)?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var listener: NWListener?
        var heartbeat: (any DispatchSourceTimer)?
        var reconnect: (any DispatchSourceTimer)?
        var running = false
        var counters = BridgeCounters()
    }
    private let state = Mutex(State())

    /// Seconds between reconnect attempts in connect mode.
    public let reconnectInterval: Int

    public init(config: VirtualPortConfig, reconnectInterval: Int = 5) {
        self.config = config
        self.reconnectInterval = max(reconnectInterval, 1)
        queue = DispatchQueue(label: "vircom.port.\(config.name)")
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(4096))
    }

    deinit { stop() }

    public var ptyPath: String { state.withLock { $0.ptyPath } }
    public var counters: BridgeCounters { state.withLock { $0.counters } }
    public var isLinked: Bool { state.withLock { !$0.connections.isEmpty } }

    public func start() throws {
        let path = try openPTY()
        state.withLock { $0.running = true }
        continuation.yield(.ptyReady(path: path))
        switch config.role {
        case .connect:
            if config.startConnectionNow { queue.async { self.connect() } }
        case .listen:
            try listen()
        }
    }

    public func stop() {
        let s = state.withLock { s -> State in
            let copy = s
            s.running = false
            s.connections.removeAll()
            s.listener = nil
            s.ptySource = nil
            s.heartbeat = nil
            s.reconnect = nil
            s.master = -1
            s.slave = -1
            return copy
        }
        s.heartbeat?.cancel()
        s.reconnect?.cancel()
        s.listener?.cancel()
        s.connections.values.forEach { $0.cancel() }
        s.ptySource?.cancel()
        if s.master >= 0 { Darwin.close(s.master) }
        if s.slave >= 0 { Darwin.close(s.slave) }
        if s.running { continuation.yield(.linkDown(nil)) }
    }

    /// Connects now (connect mode), e.g. when "start connection now" was off.
    public func connectNow() { queue.async { self.connect() } }

    // MARK: - PTY

    private func openPTY() throws -> String {
        var master: Int32 = 0, slave: Int32 = 0
        var name = [CChar](repeating: 0, count: 128)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else {
            throw ManagementError("Unable to create the virtual serial port: \(String(cString: strerror(errno)))")
        }
        // Raw mode so binary data passes through untouched.
        var t = termios()
        tcgetattr(slave, &t)
        cfmakeraw(&t)
        tcsetattr(slave, TCSANOW, &t)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        let path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.readPTY() }
        state.withLock {
            $0.master = master
            // Keep the slave open ourselves so the master never sees a hang-up
            // while no app has the port open.
            $0.slave = slave
            $0.ptyPath = path
            $0.ptySource = source
        }
        source.resume()
        return path
    }

    private func readPTY() {
        let fd = state.withLock { $0.master }
        guard fd >= 0 else { return }
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            let bytes = Array(buf[..<n])
            state.withLock { $0.counters.written += n }
            continuation.yield(.data(.toDevice, bytes))
            sendToDevice(bytes)
        }
    }

    private func writePTY(_ bytes: [UInt8]) {
        let fd = state.withLock { $0.master }
        guard fd >= 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n } else if errno == EAGAIN {
                // The app isn't reading; drop the rest rather than block the bridge.
                break
            } else { break }
        }
        state.withLock { $0.counters.read += offset }
    }

    // MARK: - Network

    private func sendToDevice(_ bytes: [UInt8]) {
        let conns = state.withLock { Array($0.connections.values) }
        guard !conns.isEmpty else { return }
        state.withLock { $0.counters.sent += bytes.count * conns.count }
        for c in conns { c.send(content: Data(bytes), completion: .idempotent) }
    }

    private func connect() {
        guard state.withLock({ $0.running && $0.connections.isEmpty }) else { return }
        guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(config.host), port: port, using: .tcp)
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.attach(conn, description: "Connected to \(self.config.host):\(self.config.port) ok.")
            case .failed(let e), .waiting(let e):
                conn.cancel()
                self.detach(conn, error: e.localizedDescription)
            case .cancelled:
                self.detach(conn, error: nil)
            default: break
            }
        }
        continuation.yield(.log("Connecting to \(config.host):\(config.port)..."))
        conn.start(queue: queue)
    }

    private func listen() throws {
        guard let port = NWEndpoint.Port(rawValue: config.listenPort) else { throw ManagementError("Invalid listen port.") }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            throw ManagementError("Can't listen on port \(config.listenPort). Another app is using it.")
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: self.attach(conn, description: "Accept connection from \(conn.endpoint).")
                case .failed(let e): self.detach(conn, error: e.localizedDescription)
                case .cancelled: self.detach(conn, error: nil)
                default: break
                }
            }
            conn.start(queue: self.queue)
        }
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.continuation.yield(.log("Listen at port \(self?.config.listenPort ?? 0) OK.")) }
            if case .failed(let e) = st { self?.continuation.yield(.log("Listen failed: \(e.localizedDescription)")) }
        }
        state.withLock { $0.listener = listener }
        listener.start(queue: queue)
    }

    private func attach(_ conn: NWConnection, description: String) {
        state.withLock { $0.connections[ObjectIdentifier(conn)] = conn }
        continuation.yield(.linkUp(description))
        // Register packet and login key go out first, as VirCom's TCP client settings do.
        var hello: [UInt8] = []
        if config.registerEnabled, !config.registerID.isEmpty { hello += Array(config.registerID.utf8) }
        if !config.loginKey.isEmpty { hello += Array(config.loginKey.utf8) }
        if !hello.isEmpty { sendToDevice(hello) }
        startHeartbeat()
        receive(on: conn)
    }

    private func detach(_ conn: NWConnection, error: String?) {
        let (removed, running, empty) = state.withLock { s in
            let r = s.connections.removeValue(forKey: ObjectIdentifier(conn)) != nil
            return (r, s.running, s.connections.isEmpty)
        }
        if removed || error != nil { continuation.yield(.linkDown(error)) }
        if empty { state.withLock { $0.heartbeat?.cancel(); $0.heartbeat = nil } }
        if running, config.role == .connect, empty { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(reconnectInterval))
        timer.setEventHandler { [weak self] in self?.connect() }
        state.withLock { $0.reconnect?.cancel(); $0.reconnect = timer }
        timer.resume()
    }

    private func startHeartbeat() {
        guard config.heartbeatSeconds > 0, let bytes = Self.hexBytes(config.heartbeatHex), !bytes.isEmpty else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(config.heartbeatSeconds), repeating: .seconds(config.heartbeatSeconds))
        timer.setEventHandler { [weak self] in self?.sendToDevice(bytes) }
        state.withLock { $0.heartbeat?.cancel(); $0.heartbeat = timer }
        timer.resume()
    }

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let bytes = [UInt8](data)
                self.state.withLock { $0.counters.received += bytes.count }
                self.continuation.yield(.data(.fromDevice, bytes))
                self.writePTY(bytes)
            }
            if done || error != nil { conn.cancel() } else { self.receive(on: conn) }
        }
    }

    /// Parses "FE 01 0A" style hex; nil if invalid.
    public static func hexBytes(_ s: String) -> [UInt8]? {
        let clean = s.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2), clean.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            out.append(UInt8(clean[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}
