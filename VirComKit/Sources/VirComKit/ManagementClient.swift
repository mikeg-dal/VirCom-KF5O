public import Foundation
import Darwin

/// A device that answered a search.
public struct DiscoveredDevice: Sendable, Identifiable, Equatable {
    public var parameters: DeviceParameters
    /// Where the reply came from (used for unicast commands).
    public var replyAddress: IPv4
    public var replyPort: UInt16
    public var lastSeen: Date
    /// Found by a unicast range search rather than broadcast.
    public var manual: Bool
    /// Found with "Search With Serial Port": settings are read and written over this port.
    public var serialPort: String? = nil
    public var serialBaud = 0

    public init(parameters: DeviceParameters, replyAddress: IPv4, replyPort: UInt16, lastSeen: Date, manual: Bool) {
        self.parameters = parameters
        self.replyAddress = replyAddress
        self.replyPort = replyPort
        self.lastSeen = lastSeen
        self.manual = manual
    }

    public var id: UInt32 { parameters.deviceKey }
}

public struct ManagementError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Talks to devices on the management port. Each operation opens its own socket,
/// like VirCom did, so searches and writes never block each other.
public struct ManagementClient: Sendable {
    /// Local port to bind (VirCom used its configured port, falling back to any).
    public var localPort: UInt16
    /// Device management port (normally 1092).
    public var devicePort: UInt16
    public var broadcastAddress: String

    public init(localPort: UInt16 = 0, devicePort: UInt16 = ZLProtocol.managementPort,
                broadcastAddress: String = "255.255.255.255") {
        self.localPort = localPort
        self.devicePort = devicePort
        self.broadcastAddress = broadcastAddress
    }

    // MARK: - Public operations

    /// Broadcasts a search on every network interface and collects replies for `duration`.
    ///
    /// macOS won't route 255.255.255.255 from an unbound socket, so each socket is pinned to one
    /// interface (IP_BOUND_IF) and sends both the limited and the subnet broadcast. Devices still on
    /// a factory address from another subnet only answer the limited one.
    public func search(duration: Duration = .milliseconds(500)) async throws -> [DiscoveredDevice] {
        let local = localPort, port = devicePort, fallback = broadcastAddress
        return try await Task.detached(priority: .userInitiated) {
            let packet = ZLProtocol.packet(.search)
            var sockets: [UDPSocket] = []
            defer { sockets.forEach { $0.close() } }
            for iface in UDPSocket.broadcastInterfaces() {
                guard let s = try? UDPSocket(preferredPort: sockets.isEmpty ? local : 0, interfaceIndex: iface.index) else { continue }
                sockets.append(s)
                try? s.send(packet, to: "255.255.255.255", port: port)
                try? s.send(packet, to: iface.broadcast, port: port)
            }
            if sockets.isEmpty || fallback != "255.255.255.255" {
                let s = try UDPSocket(preferredPort: 0)
                sockets.append(s)
                try s.send(packet, to: fallback, port: port)
            }
            return UDPSocket.collectDevices(from: sockets, for: duration, manual: false)
        }.value
    }

    /// Sends a unicast search to every address from `start` to `end` (inclusive, max 4096 hosts),
    /// or to a single host name when `start` isn't an IP address.
    public func searchRange(start: String, end: String, duration: Duration = .milliseconds(800)) async throws -> [DiscoveredDevice] {
        let targets = try Self.expand(start: start, end: end)
        return try await run { socket in
            let packet = ZLProtocol.packet(.search)
            for t in targets {
                try? socket.send(packet, to: t, port: devicePort)
            }
            return socket.collectDevices(for: duration, manual: true)
        }
    }

    /// Writes parameters. The device applies them and restarts.
    /// Broadcast twice, exactly as VirCom does, so it works even across subnets.
    public func write(_ parameters: DeviceParameters, unicastTo device: DiscoveredDevice? = nil) async throws {
        try DeviceWriteGuard.check("Modify Setting")
        let packet = ZLProtocol.packet(.writeParameters, parameters: parameters.raw)
        if let device, device.manual {
            try await run { socket in
                for _ in 0..<2 { try socket.send(packet, to: device.replyAddress.description, port: device.replyPort) }
            }
        } else {
            try await broadcast(packet, times: 2)
        }
    }

    /// Sends `packet` as a limited and subnet broadcast on every interface (see `search`).
    private func broadcast(_ packet: [UInt8], times: Int) async throws {
        let port = devicePort, fallback = broadcastAddress
        try await Task.detached(priority: .userInitiated) {
            var sent = false
            for iface in UDPSocket.broadcastInterfaces() {
                guard let s = try? UDPSocket(preferredPort: 0, interfaceIndex: iface.index) else { continue }
                defer { s.close() }
                for _ in 0..<times {
                    if (try? s.send(packet, to: "255.255.255.255", port: port)) != nil { sent = true }
                    if (try? s.send(packet, to: iface.broadcast, port: port)) != nil { sent = true }
                }
            }
            if !sent || fallback != "255.255.255.255" {
                let s = try UDPSocket(preferredPort: 0)
                defer { s.close() }
                for _ in 0..<times { try s.send(packet, to: fallback, port: port) }
            }
        }.value
    }

    /// Changes the device's key (and writes the other parameters). Throws when the old key is wrong.
    public func changeKey(_ parameters: DeviceParameters, old: String, new: String, device: DiscoveredDevice) async throws {
        try DeviceWriteGuard.check("Modify Key")
        try await run { socket in
            let packet = ZLProtocol.packet(.writeParametersWithKey, parameters: parameters.withKeyChange(old: old, new: new).raw)
            try socket.send(packet, to: device.replyAddress.description, port: device.replyPort)
            let deadline = ContinuousClock.now + .seconds(1)
            while ContinuousClock.now < deadline {
                guard let (data, _, _) = socket.receive(timeout: .milliseconds(100)) else { continue }
                if ZLProtocol.parse(data) == .wrongKey { throw ManagementError("Old key is wrong!") }
            }
        }
    }

    // MARK: - Helpers

    static func expand(start: String, end: String) throws -> [String] {
        let s = start.trimmingCharacters(in: .whitespaces)
        let e = end.trimmingCharacters(in: .whitespaces)
        guard let a = IPv4(s) else {
            // A domain name: start and end must match.
            guard !s.isEmpty, s == e || e.isEmpty else {
                throw ManagementError("If it is a domain name, the start and end names must be the same.")
            }
            return [s]
        }
        let b = IPv4(e) ?? a
        guard a.value <= b.value else { throw ManagementError("The start IP must not be larger than the end IP.") }
        guard b.value - a.value < 4096 else { throw ManagementError("The range is too large (max 4096 addresses).") }
        return (a.value...b.value).map { IPv4(value: $0).description }
    }

    private func run<T: Sendable>(_ body: @Sendable @escaping (UDPSocket) throws -> T) async throws -> T {
        let local = localPort
        return try await Task.detached(priority: .userInitiated) {
            let socket = try UDPSocket(preferredPort: local)
            defer { socket.close() }
            return try body(socket)
        }.value
    }
}

/// Minimal blocking BSD UDP socket with broadcast enabled.
final class UDPSocket: @unchecked Sendable {
    let fd: Int32

    init(preferredPort: UInt16, interfaceIndex: UInt32? = nil) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ManagementError("Unable to create a UDP socket.") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        if var index = interfaceIndex {
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        if !bind(port: preferredPort), !bind(port: 0) {
            Darwin.close(fd)
            throw ManagementError("Unable to bind a UDP port.")
        }
    }

    private func bind(port: UInt16) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func close() { Darwin.close(fd) }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            throw ManagementError("The destination \(host) can't be resolved.")
        }
        defer { freeaddrinfo(res) }
        let n = bytes.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen) }
        if n < 0 { throw ManagementError("Send to \(host) failed: \(String(cString: strerror(errno)))") }
    }

    func receive(timeout: Duration) -> ([UInt8], IPv4, UInt16)? {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000)
        guard poll(&p, 1, max(ms, 1)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 512)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { buf in
            withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len) }
            }
        }
        guard n > 0 else { return nil }
        let ip = IPv4(value: UInt32(bigEndian: from.sin_addr.s_addr))
        return (Array(buffer[..<n]), ip, UInt16(bigEndian: from.sin_port))
    }

    func collectDevices(for duration: Duration, manual: Bool) -> [DiscoveredDevice] {
        Self.collectDevices(from: [self], for: duration, manual: manual)
    }

    /// Gathers replies arriving on any of `sockets` until `duration` has passed.
    static func collectDevices(from sockets: [UDPSocket], for duration: Duration, manual: Bool) -> [DiscoveredDevice] {
        var found: [UInt32: DiscoveredDevice] = [:]
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            var fds = sockets.map { pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0) }
            guard poll(&fds, nfds_t(fds.count), 50) > 0 else { continue }
            for (i, p) in fds.enumerated() where p.revents & Int16(POLLIN) != 0 {
                guard let (data, ip, port) = sockets[i].receive(timeout: .milliseconds(1)),
                      case .parameters(let params)? = ZLProtocol.parse(data) else { continue }
                found[params.deviceKey] = DiscoveredDevice(parameters: params, replyAddress: ip, replyPort: port,
                                                           lastSeen: .now, manual: manual)
            }
        }
        return found.values.sorted { $0.parameters.ip < $1.parameters.ip }
    }

    struct BroadcastInterface {
        var name: String
        var index: UInt32
        var broadcast: String
    }

    /// Up, non-loopback IPv4 interfaces that support broadcast.
    static func broadcastInterfaces() -> [BroadcastInterface] {
        var result: [BroadcastInterface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  let bsa = ptr.pointee.ifa_dstaddr else { continue }
            let bcast = bsa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                IPv4(value: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
            }
            let name = String(cString: ptr.pointee.ifa_name)
            result.append(BroadcastInterface(name: name, index: if_nametoindex(ptr.pointee.ifa_name), broadcast: bcast.description))
        }
        return result
    }
}
