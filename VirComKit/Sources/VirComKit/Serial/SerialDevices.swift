public import Foundation

/// Frames VirCom sends to devices on a serial port. They start with the same 10-byte sync as the
/// serial download (`ED F2 A3 56 CA DB 91 84 B0 D7`).
public enum SerialFrame {
    public static let sync: [UInt8] = [0xED, 0xF2, 0xA3, 0x56, 0xCA, 0xDB, 0x91, 0x84, 0xB0, 0xD7]

    /// Serial server: read the first 0x73 parameter bytes.
    public static let readParameters = sync + [0x00, 0x00, 0x73]
    /// LoRa / 4G: identify (`92 00 02` + CRC).
    public static let identify = sync + [0x92, 0x00, 0x02, 0x51, 0xEC]
    /// LoRa: read the radio settings (`92 11 09` + CRC).
    public static let loraRead = sync + [0x92, 0x11, 0x09, 0x1C, 0x7B]

    /// Serial server: write the first 0x73 parameter bytes (`03 00 73` + data), 128 bytes in all.
    public static func writeParameters(_ p: DeviceParameters) -> [UInt8] {
        sync + [0x03, 0x00, 0x73] + Array(p.raw.prefix(0x73))
    }

    /// Serial server: write one byte (`01 offset 01 value`).
    public static func writeByte(offset: UInt8, value: UInt8) -> [UInt8] {
        sync + [0x01, offset, 0x01, value]
    }

    /// Sanity checks VirCom applies to a serial reply (`0x403420`).
    public static func plausible(_ p: DeviceParameters) -> Bool {
        p.raw[0x14] <= 3 && p.raw[0x25] <= 0xF && p.raw[0x30] <= 4 && Int(p.maxFrameLength) <= 0x514 &&
            p.raw[0x38] <= 1 && p.raw[0x39] <= 3 && p.raw[0x3A] <= 1 && p.raw[0x3B] <= 3 && p.raw[0x6F] > 4
    }
}

/// ZLAN9700/9743 LoRa settings (`0x403490`). Reply: 10 bytes + CRC; write: `93 11 0A` + the same 10 bytes + CRC.
public struct LoRaSettings: Equatable, Sendable {
    public static let bandwidths = ["7.8kHz", "10.4kHz", "15.6kHz", "20.8kHz", "31.25kHz", "41.7kHz", "62.5kHz", "125kHz", "250kHz", "500kHz"]
    public static let baudRates = [1200, 2400, 4800, 7200, 9600, 14400, 19200, 28800, 38400, 57600, 76800, 115_200, 230_400, 460_800]
    public static let parities = ["None", "Odd", "Even", "Mark", "Space"]

    /// Spreading factor 6–12.
    public var spreadingFactor = 9
    public var firmware: UInt8 = 0
    public var bandwidth = 7
    /// Coding rate 1–4.
    public var codingRate = 1
    /// MHz, 410–525.
    public var frequency = 433
    public var baudIndex = 4
    public var parity = 0
    var reserved: [UInt8] = [0, 0]

    public init() {}

    public init?(reply r: [UInt8]) {
        guard r.count >= 12, DownloadCRC.bytes(r[0..<10]) == Array(r[10..<12]) else { return nil }
        spreadingFactor = min(max(Int(r[0]), 6), 12)
        firmware = r[1]
        bandwidth = min(Int(r[2]), Self.bandwidths.count - 1)
        codingRate = r[3] == 0 ? 1 : min(Int(r[3]), 4)
        frequency = min(max(Int(r[4]) << 8 | Int(r[5]), 410), 525)
        baudIndex = min(Int(r[6]), 13)
        parity = min(Int(r[7]), 4)
        reserved = [r[8], r[9]]
    }

    public var data: [UInt8] {
        [UInt8(spreadingFactor), 0, UInt8(bandwidth), UInt8(codingRate), UInt8(frequency >> 8), UInt8(frequency & 0xFF),
         UInt8(baudIndex), UInt8(parity), 0, 0]
    }

    public var writeFrame: [UInt8] {
        let body: [UInt8] = [0x93, 0x11, 0x0A] + data
        return SerialFrame.sync + body + DownloadCRC.bytes(body)
    }
}

/// ZLAN9500 Zigbee settings (`0x404700`): read `23 A0` → 15 bytes starting `A2`; write 16 bytes starting `23 FE`.
public struct ZigbeeSettings: Equatable, Sendable {
    public static let netTypes: [(code: UInt8, title: String)] = [(1, "Net type"), (2, "Start type"), (7, "Equal type")]
    public static let nodeTypes: [(code: UInt8, title: String)] = [(1, "Center Node"), (3, "Router"), (4, "Terminal")]
    public static let sendModes = ["Broadcast", "Master-Slave", "Point-to-Point"]
    public static let baudRates = [1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200]
    public static let parities = ["None", "Even", "Odd", "Mark", "Space"]
    public static let dataBits: [(code: UInt8, title: String)] = [(1, "8"), (3, "9")]
    public static let addressFormats = ["ASCII", "HEX"]
    public static let sourceOutputs = ["No Output", "ASCII Output", "HEX Output"]
    /// The probe runs at 38400 bps.
    public static let probeBaud = 38400
    public static let read: [UInt8] = [0x23, 0xA0]

    public var nodeAddress = 0
    public var netID = 0
    public var netType: UInt8 = 7
    public var nodeType: UInt8 = 3
    /// Index into `sendModes`.
    public var sendMode = 0
    public var baudIndex = 5
    public var parity = 0
    public var dataBitsCode: UInt8 = 1
    /// Index into `addressFormats`.
    public var addressFormat = 1
    public var channel = 0
    /// Index into `sourceOutputs`.
    public var sourceOutput = 0

    public init() {}

    public init?(reply r: [UInt8]) {
        guard r.count == 15, r[0] == 0xA2 else { return nil }
        nodeAddress = Int(r[1]) << 8 | Int(r[2])
        netID = Int(r[3])
        netType = r[4]
        nodeType = r[5]
        sendMode = max(Int(r[6]) - 1, 0)
        baudIndex = max(Int(r[7]) - 1, 0)
        parity = max(Int(r[8]) - 1, 0)
        dataBitsCode = r[9]
        addressFormat = max(Int(r[10]) - 1, 0)
        channel = Int(r[12])
        sourceOutput = max(Int(r[14]) - 1, 0)
    }

    public var writeFrame: [UInt8] {
        [0x23, 0xFE, UInt8(nodeAddress >> 8 & 0xFF), UInt8(nodeAddress & 0xFF), UInt8(netID & 0xFF), netType, nodeType,
         UInt8(sendMode + 1), UInt8(baudIndex + 1), UInt8(parity + 1), dataBitsCode, UInt8(addressFormat + 1),
         0x0A, UInt8(channel & 0xFF), 0, UInt8(sourceOutput + 1)]
    }
}

/// What "Search With Serial Port" found.
public enum SerialSearchResult: Sendable {
    case serialServer(DeviceParameters, baud: Int)
    case lora(LoRaSettings, baud: Int)
    case zigbee(ZigbeeSettings)
    case fourG(baud: Int)
}

/// "Search With Serial Port" (`0x404d50`, `0x405180`).
public struct SerialSearch: Sendable {
    public static let baudRates = [1200, 2400, 4800, 7200, 9600, 14400, 19200, 28800, 38400, 57600, 76800, 115_200, 230_400, 460_800]
    /// Reply wait per baud rate (ms), from VirCom's table.
    static let waits = [2288, 1146, 574, 384, 290, 260, 240, 200, 200, 160, 140, 140, 100, 100]

    public var port: String
    /// nil searches every rate, fastest first.
    public var baudRate: Int?
    public var dataBits = 8
    public var parity: SerialParity = .none

    public init(port: String, baudRate: Int?, dataBits: Int = 8, parity: SerialParity = .none) {
        self.port = port
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
    }

    public func run(progress: @escaping @Sendable (String) -> Void) async throws -> SerialSearchResult? {
        let me = self
        return try await Task.detached(priority: .userInitiated) { try me.search(progress) }.value
    }

    private func search(_ progress: (String) -> Void) throws -> SerialSearchResult? {
        progress("Checking for a ZLAN9500 Zigbee module…")
        if let z = try? zigbee() { return .zigbee(z) }
        let rates = baudRate.map { [$0] } ?? Self.baudRates.reversed()
        for rate in rates {
            try Task.checkCancellation()
            progress("Searching at \(rate) bps…")
            let wait = Duration.milliseconds(Self.waits[Self.baudRates.firstIndex(of: rate) ?? 4])
            let user = try SerialLink(path: port, settings: .init(baudRate: rate, dataBits: dataBits, parity: parity))
            user.flushInput()
            try user.write(SerialFrame.identify)
            let reply = user.read(64, timeout: wait + .milliseconds(200))
            if let kind = Self.radioKind(reply) {
                switch kind {
                case .fourG:
                    return .fourG(baud: rate)
                case .lora:
                    user.flushInput()
                    try user.write(SerialFrame.loraRead)
                    usleep(500_000)
                    if let s = LoRaSettings(reply: user.read(12, timeout: .seconds(1))) { return .lora(s, baud: rate) }
                }
            }
            // Serial servers listen with mark parity; two stop bits look the same on the wire.
            let mark = try SerialLink(path: port, settings: .init(baudRate: rate, dataBits: 8, parity: .none, twoStopBits: true))
            mark.flushInput()
            try mark.write(SerialFrame.readParameters)
            let block = mark.read(0x73, timeout: wait + .milliseconds(300))
            if block.count == 0x73 {
                let p = DeviceParameters(raw: block + [UInt8](repeating: 0, count: ZLProtocol.parameterSize - 0x73))
                if SerialFrame.plausible(p) { return .serialServer(p, baud: rate) }
            }
        }
        return nil
    }

    enum RadioKind { case lora, fourG }

    /// Identify replies contain `97 00 6F 80`, `17 00 6F 00` (LoRa) or `83 05 A0 83`, `03 05 20 03` (4G).
    static func radioKind(_ r: [UInt8]) -> RadioKind? {
        guard r.count >= 4 else { return nil }
        for i in 0...(r.count - 4) {
            let s = Array(r[i..<(i + 4)])
            if s == [0x97, 0, 0x6F, 0x80] || s == [0x17, 0, 0x6F, 0] { return .lora }
            if s == [0x83, 5, 0xA0, 0x83] || s == [0x03, 5, 0x20, 0x03] { return .fourG }
        }
        return nil
    }

    func zigbee() throws -> ZigbeeSettings? {
        let link = try SerialLink(path: port, settings: .init(baudRate: ZigbeeSettings.probeBaud))
        link.flushInput()
        try link.write(ZigbeeSettings.read)
        usleep(200_000)
        return ZigbeeSettings(reply: link.read(16, timeout: .milliseconds(300)))
    }

    // MARK: Writes

    public static func writeZigbee(_ s: ZigbeeSettings, port: String) throws {
        let link = try SerialLink(path: port, settings: .init(baudRate: ZigbeeSettings.probeBaud))
        try link.write(s.writeFrame)
    }

    /// Returns true when the module echoes the new settings.
    public static func writeLoRa(_ s: LoRaSettings, port: String, baud: Int, dataBits: Int = 8, parity: SerialParity = .none) throws -> Bool {
        let link = try SerialLink(path: port, settings: .init(baudRate: baud, dataBits: dataBits, parity: parity))
        link.flushInput()
        try link.write(s.writeFrame)
        usleep(1_000_000)
        let r = link.read(12, timeout: .seconds(1))
        guard let back = LoRaSettings(reply: r) else { return false }
        return Array(back.data.prefix(8)) == Array(s.data.prefix(8))
    }

    /// Writes a serial server's parameters (`0x402a70`): data bits forced to 8 and the packet
    /// interval raised to the baud-rate minimum first, as VirCom does.
    public static func writeSerialServer(_ p: DeviceParameters, port: String, baud: Int) throws {
        let link = try SerialLink(path: port, settings: .init(baudRate: baud, dataBits: 8, parity: .none, twoStopBits: true))
        if p.raw[0x3B] != 0 {
            try link.write(SerialFrame.writeByte(offset: 0x3B, value: 0))
            usleep(500_000)
        }
        let t = [50, 25, 14, 7, 4, 3, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1][Int(p.baudIndex) & 0xF]
        let minimum = UInt8(max(t, 3))
        if p.packetInterval < minimum {
            for _ in 0..<2 {
                try link.write(SerialFrame.writeByte(offset: 0x31, value: minimum))
                usleep(500_000)
            }
        }
        try link.write(SerialFrame.writeParameters(p))
    }
}
