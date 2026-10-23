import Darwin
import Foundation
import Network
import Testing
@testable import VirComKit

/// A canned device parameter block shaped like a ZLSN2000 reply.
func sampleParameters() -> DeviceParameters {
    var p = DeviceParameters.blank
    p.applyFactoryDefaults()
    p.raw.replaceSubrange(0x15..<0x1F, with: Array("ZLSN2000".utf8) + [0, 0])
    p.raw.replaceSubrange(0x1F..<0x25, with: [0x12, 0x34, 0xAB, 0xCD, 0xEF, 0x01])
    p.name = "Line1"
    p.raw[0x67] = 206
    p.raw[0x68] = 0b0010_1110
    return p
}

@Suite struct ProtocolTests {
    @Test func packetLayout() {
        let pkt = ZLProtocol.packet(.search)
        #expect(pkt.count == 170)
        #expect(Array(pkt.prefix(3)) == [0x5A, 0x4C, 0x00])
        let w = ZLProtocol.packet(.writeParameters, parameters: sampleParameters().raw)
        #expect(w[2] == 0x02)
        #expect(Array(w[3...]) == sampleParameters().raw)
    }

    @Test func parseReply() throws {
        let p = sampleParameters()
        let reply = [0x5A, 0x4C, 0x01] + p.raw
        guard case .parameters(let parsed)? = ZLProtocol.parse(reply) else { Issue.record("no parse"); return }
        #expect(parsed == p)
        #expect(parsed.deviceID == "1234ABCDEF01")
        #expect(parsed.deviceKey == 0xABCD_EF01)
        #expect(parsed.deviceType == "ZLSN2000")
        #expect(parsed.firmwareVersion == "V1.589")
        #expect(parsed.capabilities.contains(.dhcp))
        #expect(!parsed.capabilities.contains(.webDownload))
        #expect(ZLProtocol.parse([0x5A, 0x4C, 0x01, 1, 2]) == nil)       // too short
        #expect(ZLProtocol.parse([0x5A, 0x4D, 0x01] + p.raw) == nil)     // bad magic
        #expect(ZLProtocol.parse([0x5A, 0x4C, 0x0C]) == .wrongKey)
    }

    @Test func shortReplyIsPadded() {
        let raw = [0x5A, 0x4C, 0x01] + [UInt8](repeating: 7, count: 60)
        guard case .parameters(let p)? = ZLProtocol.parse(raw) else { Issue.record("no parse"); return }
        #expect(p.raw.count == 167)
        #expect(p.raw[59] == 7 && p.raw[60] == 0)
    }

    @Test func fieldsRoundTrip() {
        var p = sampleParameters()
        let before = p.raw
        p.ip = IPv4(10, 0, 0, 7)
        p.devicePort = 502
        p.workMode = .udpGroup
        p.baudIndex = 4
        p.parity = .even
        p.dataBits = 7
        p.twoStopBits = true
        p.flowControl = .ctsRts
        p.transferProtocol = .modbusTCP
        p.destinationHost = "example.com"
        #expect(Array(p.raw[0..<4]) == [10, 0, 0, 7])
        #expect(Array(p.raw[0x10..<0x12]) == [0x01, 0xF6])
        #expect(p.raw[0x14] == 3 && p.raw[0x25] == 4 && p.raw[0x30] == 2 && p.raw[0x3B] == 1)
        #expect(p.raw[0x72] & 1 == 1 && p.raw[0x39] == 1 && p.raw[0x3C] == 1)
        #expect(p.baudRate == 9600)
        #expect(p.destinationHost == "example.com")
        // Untouched bytes are preserved.
        #expect(p.raw[0x15..<0x25] == before[0x15..<0x25])
        #expect(p.raw[0x67] == before[0x67])
    }

    @Test func factoryDefaults() {
        var p = DeviceParameters.blank
        p.applyFactoryDefaults()
        #expect(p.ip.description == "192.168.1.200")
        #expect(p.gateway.description == "192.168.1.1")
        #expect(p.dnsServer.description == "8.8.4.4")
        #expect(p.devicePort == 4196 && p.baudRate == 115_200 && p.dataBits == 8)
        #expect(p.dynamicDestination && p.maxFrameLength == 1300 && p.packetInterval == 3)
    }

    @Test func keyChangeLayout() {
        let p = sampleParameters().withKeyChange(old: "123456", new: "abc")
        #expect(Array(p.raw[0x26..<0x2D]) == Array("123456".utf8) + [0])
        #expect(Array(p.raw[0x15..<0x19]) == Array("abc".utf8) + [0])
    }

    @Test func rangeExpansion() throws {
        #expect(try ManagementClient.expand(start: "10.0.0.254", end: "10.0.1.1") ==
                ["10.0.0.254", "10.0.0.255", "10.0.1.0", "10.0.1.1"])
        #expect(try ManagementClient.expand(start: "dev.example.com", end: "") == ["dev.example.com"])
        #expect(throws: ManagementError.self) { try ManagementClient.expand(start: "10.0.0.5", end: "10.0.0.1") }
    }
}

/// A fake device answering on a loopback UDP port.
final class FakeDevice: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    var params = sampleParameters()
    var received: [[UInt8]] = []
    let lock = NSLock()

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, 16) } }
        var len = socklen_t(16)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd
        port = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread { [self] in serve() }
    }

    func serve() {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            var from = sockaddr_in()
            var len = socklen_t(16)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, b.baseAddress, b.count, 0, $0, &len) } }
            }
            guard n > 0 else { return }
            let pkt = Array(buf[..<n])
            lock.withLock { received.append(pkt) }
            var reply: [UInt8]
            switch pkt[2] {
            case 0x00: reply = [0x5A, 0x4C, 0x01] + params.raw
            case 0x0B: reply = [0x5A, 0x4C, 0x0C]
            default: continue
            }
            _ = reply.withUnsafeBytes { r in
                withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, r.baseAddress, r.count, 0, $0, len) } }
            }
        }
    }

    deinit { close(fd) }
}

@Suite(.serialized) struct ClientTests {
    @Test func rangeSearchFindsDevice() async throws {
        let dev = try FakeDevice()
        let client = ManagementClient(devicePort: dev.port)
        let found = try await client.searchRange(start: "127.0.0.1", end: "127.0.0.1", duration: .milliseconds(300))
        #expect(found.count == 1)
        #expect(found.first?.parameters.deviceID == "1234ABCDEF01")
        #expect(found.first?.manual == true)
    }

    @Test func writeIsUnicastForManualDevices() async throws {
        let dev = try FakeDevice()
        let client = ManagementClient(devicePort: dev.port)
        let found = try await client.searchRange(start: "127.0.0.1", end: "127.0.0.1", duration: .milliseconds(300))
        var p = try #require(found.first).parameters
        p.name = "Renamed"
        try await client.write(p, unicastTo: found.first)
        try await Task.sleep(for: .milliseconds(100))
        let writes = dev.lock.withLock { dev.received.filter { $0[2] == 0x02 } }
        #expect(writes.count == 2) // sent twice, like VirCom
        #expect(DeviceParameters(raw: Array(writes[0][3...])).name == "Renamed")
    }

    @Test func wrongKeyIsReported() async throws {
        let dev = try FakeDevice()
        let client = ManagementClient(devicePort: dev.port)
        let found = try await client.searchRange(start: "127.0.0.1", end: "127.0.0.1", duration: .milliseconds(300))
        let d = try #require(found.first)
        await #expect(throws: ManagementError.self) {
            try await client.changeKey(d.parameters, old: "bad", new: "new", device: d)
        }
    }
}

@Suite(.serialized) struct BridgeTests {
    /// Device = local TCP echo server that uppercases; app = writes to the pty and reads back.
    @Test func ptyBridgesToTCP() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { c in
            c.start(queue: .global())
            UppercaseEcho(c).loop()
        }
        let ready = AsyncStream<UInt16> { cont in
            listener.stateUpdateHandler = { if case .ready = $0 { cont.yield(listener.port!.rawValue); cont.finish() } }
            listener.start(queue: .global())
        }
        var port: UInt16 = 0
        for await p in ready { port = p }

        var cfg = VirtualPortConfig(name: "COM9")
        cfg.host = "127.0.0.1"
        cfg.port = port
        let bridge = VirtualPortBridge(config: cfg)
        try bridge.start()
        for _ in 0..<100 where !bridge.isLinked { try await Task.sleep(for: .milliseconds(20)) }
        #expect(bridge.isLinked)

        // An "app" opens the virtual port like a serial device.
        let fd = open(bridge.ptyPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        try #require(fd >= 0)
        defer { close(fd) }
        var t = termios(); tcgetattr(fd, &t); cfmakeraw(&t); tcsetattr(fd, TCSANOW, &t)
        _ = write(fd, "hello", 5)
        var buf = [UInt8](repeating: 0, count: 16)
        var got = 0
        for _ in 0..<100 where got < 5 {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, 16 - got) }
            if n > 0 { got += n } else { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(String(decoding: buf[..<got], as: UTF8.self) == "HELLO")
        #expect(bridge.counters.written == 5 && bridge.counters.received == 5)
        bridge.stop()
        listener.cancel()
    }
}

/// Echoes everything it receives in uppercase.
final class UppercaseEcho: Sendable {
    let c: NWConnection
    init(_ c: NWConnection) { self.c = c }
    func loop() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1024) { d, _, done, _ in
            if let d { self.c.send(content: Data(String(decoding: d, as: UTF8.self).uppercased().utf8), completion: .idempotent) }
            if !done { self.loop() }
        }
    }
}

/// A reply captured (read-only) from a real Waveshare serial server.
@Suite struct RealDeviceVectorTests {
    static let hex = """
    c0 a8 01 fe ff ff ff 00 c0 a8 01 01 c0 a8 01 0a 10 64 23 f0 01 38 38 38 38 38 38 38 38 38 38 28
    7f 86 87 67 6a 04 57 53 44 45 56 30 30 30 31 00 00 03 05 14 00 00 00 00 00 00 01 00 00 00 08 08
    04 04 31 39 32 2e 31 36 38 2e 31 2e 31 30 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
    0c 3c 00 50 00 01 00 45 be e6 5a 4c 01 00 01 05 06 00 00 09 04 00 00 00 00 0a 04 00 00 00 00 00
    """
    static var block: [UInt8] {
        var b = hex.split(whereSeparator: \.isWhitespace).map { UInt8($0, radix: 16)! }
        b += [UInt8](repeating: 0, count: 167 - b.count)
        return b
    }

    @Test func decodesEveryField() throws {
        guard case .parameters(let p)? = ZLProtocol.parse([0x5A, 0x4C, 0x01] + Self.block) else {
            Issue.record("no parse"); return
        }
        #expect(p.ip.description == "192.168.1.254")
        #expect(p.subnetMask.description == "255.255.255.0")
        #expect(p.gateway.description == "192.168.1.1")
        #expect(p.destinationIP.description == "192.168.1.10")
        #expect(p.devicePort == 4196 && p.destinationPort == 9200)
        #expect(p.workMode == .tcpClient)
        #expect(p.deviceType == "8888888888")
        #expect(p.deviceID == "287F8687676A")
        #expect(p.baudRate == 9600 && p.dataBits == 8 && p.parity == .none && !p.twoStopBits)
        #expect(p.name == "WSDEV0001")
        #expect(p.packetInterval == 3 && p.maxFrameLength == 1300)
        #expect(!p.dhcp && p.dynamicDestination && p.flowControl == .none && p.transferProtocol == .none)
        #expect(p.dnsServer.description == "8.8.4.4" && p.destinationHost == "192.168.1.10")
        #expect(p.reconnectSeconds == 12 && p.keepAliveSeconds == 60 && p.httpPort == 80)
        #expect(p.firmwareVersion == "V1.452")
        #expect(p.udpGroupIP.description == "230.90.76.1")
        #expect(p.restartWhenNoData)
        // Re-encoding without edits must reproduce the device's bytes exactly.
        var q = p
        q.name = p.name
        q.baudIndex = p.baudIndex
        #expect(q.raw == Self.block)
    }
}
