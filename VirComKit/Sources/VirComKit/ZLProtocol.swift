import Foundation

/// The ZLAN/Waveshare UDP management protocol. See docs/PROTOCOL.md.
public enum ZLProtocol {
    public static let managementPort: UInt16 = 1092
    public static let defaultDataPort: UInt16 = 4196
    public static let magic: [UInt8] = [0x5A, 0x4C]
    public static let packetSize = 170
    public static let parameterSize = 167
    static let minimumReply = 41

    public enum Command: UInt8, Sendable {
        case search = 0x00
        case reply = 0x01
        case writeParameters = 0x02
        case writeParametersWithKey = 0x0B
        case wrongKey = 0x0C
    }

    public static func packet(_ command: Command, parameters: [UInt8] = []) -> [UInt8] {
        var p = magic + [command.rawValue]
        p += parameters.prefix(parameterSize)
        p += [UInt8](repeating: 0, count: packetSize - p.count)
        return p
    }

    public enum Reply: Sendable, Equatable {
        case parameters(DeviceParameters)
        case wrongKey
    }

    /// Parses a datagram from a device; nil for anything that isn't a valid reply.
    public static func parse(_ datagram: [UInt8]) -> Reply? {
        guard datagram.count >= 3, Array(datagram[0..<2]) == magic else { return nil }
        if datagram[2] == Command.wrongKey.rawValue { return .wrongKey }
        guard datagram.count >= minimumReply, datagram[2] == Command.reply.rawValue else { return nil }
        var block = Array(datagram[3..<min(datagram.count, packetSize)])
        block += [UInt8](repeating: 0, count: parameterSize - block.count)
        return .parameters(DeviceParameters(raw: block))
    }
}

/// An IPv4 address in network byte order.
public struct IPv4: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    public var bytes: (UInt8, UInt8, UInt8, UInt8)

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) { bytes = (a, b, c, d) }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: [UInt8] = []
        for p in parts {
            guard let n = UInt8(p) else { return nil }
            v.append(n)
        }
        bytes = (v[0], v[1], v[2], v[3])
    }

    public init(value: UInt32) {
        bytes = (UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    public var value: UInt32 {
        UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)
    }

    public var array: [UInt8] { [bytes.0, bytes.1, bytes.2, bytes.3] }
    public var description: String { "\(bytes.0).\(bytes.1).\(bytes.2).\(bytes.3)" }

    public static func == (l: IPv4, r: IPv4) -> Bool { l.value == r.value }
    public func hash(into h: inout Hasher) { h.combine(value) }
    public static func < (l: IPv4, r: IPv4) -> Bool { l.value < r.value }

    public init(from decoder: any Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let ip = IPv4(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad IPv4 \(s)"))
        }
        self = ip
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    /// True if both addresses are in the same subnet under `mask`.
    public func sameSubnet(as other: IPv4, mask: IPv4) -> Bool {
        value & mask.value == other.value & mask.value
    }
}

public enum WorkMode: UInt8, CaseIterable, Sendable, Codable, Identifiable {
    case tcpServer = 0, tcpClient = 1, udp = 2, udpGroup = 3
    public var id: UInt8 { rawValue }
    public var title: String {
        switch self {
        case .tcpServer: "TCP Server"
        case .tcpClient: "TCP Client"
        case .udp: "UDP"
        case .udpGroup: "UDP Group"
        }
    }
}

public enum DeviceParity: UInt8, CaseIterable, Sendable, Identifiable {
    case none = 0, odd = 1, even = 2, mark = 3, space = 4
    public var id: UInt8 { rawValue }
    public var title: String { ["None", "Odd", "Even", "Mark", "Space"][Int(rawValue)] }
}

public enum DeviceFlowControl: UInt8, CaseIterable, Sendable, Identifiable {
    case none = 0, ctsRts = 1, dsrDtr = 2, xonXoff = 3
    public var id: UInt8 { rawValue }
    public var title: String { ["None", "CTS/RTS", "DSR/DTR", "XON/XOFF"][Int(rawValue)] }
}

public enum TransferProtocol: UInt8, CaseIterable, Sendable, Identifiable {
    case none = 0, modbusTCP = 1, realCOM = 2
    public var id: UInt8 { rawValue }
    public var title: String { ["None", "Modbus TCP Protocol", "REAL_COM Protocol"][Int(rawValue)] }
}

public struct DeviceCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let webDownload = DeviceCapabilities(rawValue: 1 << 0)
    public static let dns = DeviceCapabilities(rawValue: 1 << 1)
    public static let realCOM = DeviceCapabilities(rawValue: 1 << 2)
    public static let modbusTCP = DeviceCapabilities(rawValue: 1 << 3)
    public static let serialCommands = DeviceCapabilities(rawValue: 1 << 4)
    public static let dhcp = DeviceCapabilities(rawValue: 1 << 5)
    public static let storageExtension = DeviceCapabilities(rawValue: 1 << 6)
    public static let multiTCP = DeviceCapabilities(rawValue: 1 << 7)

    public static let all: [(DeviceCapabilities, String)] = [
        (.webDownload, "Web Download"), (.dns, "DNS System"), (.realCOM, "REAL_COM Protocol"),
        (.modbusTCP, "Modbus TCP To RTU"), (.serialCommands, "Serial Command"), (.dhcp, "DHCP Support"),
        (.storageExtension, "Storage Extend"), (.multiTCP, "Multi-TCP Connection"),
    ]
}

/// The 167-byte parameter block. Only documented fields have accessors;
/// every other byte is preserved exactly as the device sent it.
public struct DeviceParameters: Sendable, Equatable {
    public var raw: [UInt8]

    public init(raw: [UInt8]) {
        precondition(raw.count == ZLProtocol.parameterSize)
        self.raw = raw
    }

    /// Baud rates by stored index (index 10 is 76800 on most models, 921600 on newer ones).
    public static let baudRates: [Int] = [1200, 2400, 4800, 7200, 9600, 14400, 19200, 28800, 38400,
                                          57600, 76800, 115_200, 230_400, 460_800, 300, 600]
    /// The order the settings dialog lists baud rates in (as stored indices).
    public static let baudDisplayOrder: [UInt8] = [14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]

    // MARK: accessors

    private func ip(_ o: Int) -> IPv4 { IPv4(raw[o], raw[o + 1], raw[o + 2], raw[o + 3]) }
    private mutating func setIP(_ o: Int, _ v: IPv4) { raw.replaceSubrange(o..<(o + 4), with: v.array) }
    private func u16(_ o: Int) -> UInt16 { UInt16(raw[o]) << 8 | UInt16(raw[o + 1]) }
    private mutating func setU16(_ o: Int, _ v: UInt16) { raw[o] = UInt8(v >> 8); raw[o + 1] = UInt8(v & 0xFF) }

    private func string(_ o: Int, _ n: Int) -> String {
        let bytes = raw[o..<(o + n)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Writes a NUL-terminated string field, truncated to leave room for the terminator.
    private mutating func setString(_ o: Int, _ n: Int, _ s: String) {
        var b = Array(s.utf8.prefix(n - 1))
        b += [UInt8](repeating: 0, count: n - b.count)
        raw.replaceSubrange(o..<(o + n), with: b)
    }

    public var ip: IPv4 { get { ip(0x00) } set { setIP(0x00, newValue) } }
    public var subnetMask: IPv4 { get { ip(0x04) } set { setIP(0x04, newValue) } }
    public var gateway: IPv4 { get { ip(0x08) } set { setIP(0x08, newValue) } }
    public var destinationIP: IPv4 { get { ip(0x0C) } set { setIP(0x0C, newValue) } }
    public var devicePort: UInt16 { get { u16(0x10) } set { setU16(0x10, newValue) } }
    public var destinationPort: UInt16 { get { u16(0x12) } set { setU16(0x12, newValue) } }

    public var workMode: WorkMode {
        get { WorkMode(rawValue: min(raw[0x14], 3)) ?? .tcpServer }
        set { raw[0x14] = newValue.rawValue }
    }

    public var deviceType: String { string(0x15, 10) }

    public var deviceIDBytes: [UInt8] { Array(raw[0x1F..<0x25]) }
    /// Shown as SSCOM/VirCom do: two bytes then four bytes, uppercase hex.
    public var deviceID: String { deviceIDBytes.map { String(format: "%02X", $0) }.joined() }
    /// The 4 bytes VirCom uses to tell devices apart.
    public var deviceKey: UInt32 { raw[0x21..<0x25].reduce(0) { $0 << 8 | UInt32($1) } }

    public var baudIndex: UInt8 {
        get { min(raw[0x25], 15) }
        set { raw[0x25] = newValue & 0x0F }
    }
    public var baudRate: Int { Self.baudRates[Int(baudIndex)] }

    public var name: String { get { string(0x26, 10) } set { setString(0x26, 10, newValue) } }

    public var parity: DeviceParity {
        get { DeviceParity(rawValue: min(raw[0x30], 4)) ?? .none }
        set { raw[0x30] = newValue.rawValue }
    }

    /// Max gap between bytes of one packet, in ms.
    public var packetInterval: UInt8 { get { raw[0x31] } set { raw[0x31] = newValue } }
    public var maxFrameLength: UInt16 { get { u16(0x32) } set { setU16(0x32, newValue) } }

    public var dhcp: Bool { get { raw[0x38] == 1 } set { raw[0x38] = newValue ? 1 : 0 } }

    public var flowControl: DeviceFlowControl {
        get { DeviceFlowControl(rawValue: min(raw[0x39], 3)) ?? .none }
        set { raw[0x39] = newValue.rawValue }
    }

    /// False = static destination, true = dynamic.
    public var dynamicDestination: Bool { get { raw[0x3A] == 1 } set { raw[0x3A] = newValue ? 1 : 0 } }

    public var dataBits: Int {
        get { 8 - Int(min(raw[0x3B], 3)) }
        set { raw[0x3B] = UInt8(clamping: 8 - min(max(newValue, 5), 8)) }
    }

    public var transferProtocol: TransferProtocol {
        get { TransferProtocol(rawValue: min(raw[0x3C], 2)) ?? .none }
        set { raw[0x3C] = newValue.rawValue }
    }

    public var dnsServer: IPv4 { get { ip(0x3E) } set { setIP(0x3E, newValue) } }
    public var destinationHost: String { get { string(0x42, 30) } set { setString(0x42, 30, newValue) } }
    public var reconnectSeconds: UInt8 { get { raw[0x60] } set { raw[0x60] = newValue } }
    public var keepAliveSeconds: UInt8 { get { raw[0x61] } set { raw[0x61] = newValue } }
    public var httpPort: UInt16 { get { u16(0x62) } set { setU16(0x62, newValue) } }
    public var portNumber: Int { Int(raw[0x64] & 0x3F) }
    public var firmwareVersion: String { "V1.\(Int(raw[0x67]) + 383)" }
    public var capabilities: DeviceCapabilities { DeviceCapabilities(rawValue: raw[0x68]) }
    public var udpGroupIP: IPv4 { get { ip(0x69) } set { setIP(0x69, newValue) } }

    public var restartWhenNoData: Bool {
        get { raw[0x6E] & 0x01 != 0 }
        set { raw[0x6E] = newValue ? raw[0x6E] | 0x01 : raw[0x6E] & ~0x01 }
    }
    public var sendParametersPeriodically: Bool {
        get { raw[0x6E] & 0x02 != 0 }
        set { raw[0x6E] = newValue ? raw[0x6E] | 0x02 : raw[0x6E] & ~0x02 }
    }
    public var parameterSendMinutes: UInt8 { get { raw[0x6F] } set { raw[0x6F] = newValue } }

    public var twoStopBits: Bool {
        get { raw[0x72] & 0x01 != 0 }
        set { raw[0x72] = newValue ? raw[0x72] | 0x01 : raw[0x72] & ~0x01 }
    }

    /// Fills the user-editable fields with VirCom's "Get Default" values.
    /// Identity fields (device ID, type, firmware, capabilities) are kept.
    public mutating func applyFactoryDefaults() {
        workMode = .tcpServer
        dhcp = false
        flowControl = .none
        dynamicDestination = true
        twoStopBits = false
        parity = .none
        dataBits = 8
        transferProtocol = .none
        baudIndex = 11 // 115200
        dnsServer = IPv4(8, 8, 4, 4)
        ip = IPv4(192, 168, 1, 200)
        subnetMask = IPv4(255, 255, 255, 0)
        gateway = IPv4(192, 168, 1, 1)
        udpGroupIP = IPv4(230, 90, 76, 1)
        reconnectSeconds = 12
        keepAliveSeconds = 60
        httpPort = 80
        restartWhenNoData = false
        sendParametersPeriodically = false
        parameterSendMinutes = 5
        devicePort = ZLProtocol.defaultDataPort
        destinationPort = ZLProtocol.defaultDataPort
        packetInterval = 3
        maxFrameLength = 1300
        raw[0x71] = 0
        raw.replaceSubrange(0x73..<0xA7, with: [UInt8](repeating: 0, count: 0xA7 - 0x73))
        raw.replaceSubrange(0x34..<0x38, with: [0, 0, 0, 0])
        raw[0x6E] &= 0x03
    }

    /// Copy used for a key change: old key in the name field, new key in the type field (command 0x0B).
    public func withKeyChange(old: String, new: String) -> DeviceParameters {
        var p = self
        p.setString(0x26, 10, old)
        p.setString(0x15, 10, new)
        return p
    }

    public static var blank: DeviceParameters { DeviceParameters(raw: [UInt8](repeating: 0, count: ZLProtocol.parameterSize)) }
}

/// VirCom's "Multi device editing tips" (`0x4253d0`): the first device's new settings are applied to
/// every selected device, with these per-device adjustments (devices in IP order).
public struct BatchEdit: Sendable, Hashable, Codable {
    public enum IPPolicy: Int, CaseIterable, Sendable, Codable {
        /// Shift each device's last IP byte by the change made to the first device.
        case keepDifference
        /// First device's new address, then +1 per device.
        case increment
        /// Same address for all (useful with DHCP).
        case same
    }
    public enum PortPolicy: Int, CaseIterable, Sendable, Codable {
        case increment, same
    }

    public var ipPolicy: IPPolicy = .keepDifference
    public var portPolicy: PortPolicy = .same
    public var numberNames = true

    public init() {}

    /// Identity bytes kept from each device: type and ID, port number, firmware, capabilities.
    static let identity: [Range<Int>] = [0x15..<0x25, 0x64..<0x65, 0x67..<0x69, 0x70..<0x71]

    /// New parameter blocks for `devices` (first = the edited one, as it was) given its edited settings.
    public func apply(edited: DeviceParameters, original first: DeviceParameters, to devices: [DeviceParameters]) -> [DeviceParameters] {
        let sorted = devices.sorted { $0.ip < $1.ip }
        let delta = Int(edited.ip.bytes.3) - Int(first.ip.bytes.3)
        return sorted.enumerated().map { i, d in
            var q = edited
            for r in Self.identity { q.raw.replaceSubrange(r, with: d.raw[r]) }
            let b = edited.ip.bytes
            switch ipPolicy {
            case .keepDifference:
                q.ip = IPv4(b.0, b.1, b.2, UInt8(truncatingIfNeeded: Int(d.ip.bytes.3) + delta))
            case .increment:
                q.ip = IPv4(b.0, b.1, b.2, UInt8(truncatingIfNeeded: Int(b.3) + i))
            case .same:
                break
            }
            if portPolicy == .increment { q.destinationPort = edited.destinationPort &+ UInt16(i) }
            if numberNames {
                let suffix = String(i + 1)
                q.name = String(edited.name.prefix(9 - suffix.count)) + suffix
            }
            return q
        }
    }
}
