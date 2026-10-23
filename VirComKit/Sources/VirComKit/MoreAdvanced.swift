public import Foundation

/// The type-length-value list at 0x73 (52 bytes, type 0 ends it). VirCom's `0x42dc60` (get) and
/// `0x42db40` (set: remove the old entry, append the new one).
public struct ParameterTLV {
    public static let offset = 0x73
    public static let size = 0x34

    public static func get(_ type: UInt8, in p: DeviceParameters) -> [UInt8]? {
        let area = Array(p.raw[offset..<(offset + size)])
        var i = 0
        while i + 1 < size, area[i] != 0 {
            let n = Int(area[i + 1])
            if area[i] == type {
                guard i + 2 + n <= size else { return nil }
                return Array(area[(i + 2)..<(i + 2 + n)])
            }
            i += 2 + n
        }
        return nil
    }

    /// Replaces (or with nil removes) an entry. Returns false when it doesn't fit.
    @discardableResult
    public static func set(_ type: UInt8, _ data: [UInt8]?, in p: inout DeviceParameters) -> Bool {
        var entries: [(UInt8, [UInt8])] = []
        var i = 0
        let area = Array(p.raw[offset..<(offset + size)])
        while i + 1 < size, area[i] != 0 {
            let n = Int(area[i + 1])
            guard i + 2 + n <= size else { break }
            if area[i] != type { entries.append((area[i], Array(area[(i + 2)..<(i + 2 + n)]))) }
            i += 2 + n
        }
        if let data { entries.append((type, data)) }
        var out: [UInt8] = []
        for (t, d) in entries { out += [t, UInt8(d.count)] + d }
        guard out.count <= size else { return false }
        out += [UInt8](repeating: 0, count: size - out.count)
        p.raw.replaceSubrange(offset..<(offset + size), with: out)
        return true
    }
}

/// VirCom's "More Advanced Settings" (`0x41d080` with the dialog `0x4149d0`).
///
/// | Where | Meaning |
/// |---|---|
/// | TLV 1 bit 1 | VLAN enabled |
/// | TLV 2 / 4 | WiFi SSID / key |
/// | TLV 3 | bits 0–3 AP channel, bit 6 DHCP server off, bit 7 RJ45–WiFi relay |
/// | TLV 5 | bits 0–5 encryption, bit 6 AP mode, bit 7 station mode |
/// | TLV 6 | VLAN, little-endian: bits 0–11 ID, bit 12 media type, bits 13–15 priority |
/// | TLV 7 | up to 7 × (IPv4, port BE) extra destinations |
/// | TLV 11 | up to 7 × (port BE, name, NUL) when a destination is a domain name |
/// | TLV 8 | proxy: IPv4, port, authentication flag, name[16], key[16] |
/// | 0x34 | RS485 frame end type (0 not used, 1 flow control) |
/// | 0x35 | frame end byte |
/// | 0x36 | RS485 bus idle time (ms) |
/// | 0x37 | RS485 conflict detection / Modbus gateway mode (0 off, 2, 3, 4) |
/// | 0x6E bits 2–7 | key to modify, receive broadcast, P2P, send MAC, ping, keep serial buffer |
/// | 0x70 | supported advanced functions (read only) |
/// | 0x71 | RS485 multi-host wait: 0 off, else ms / 32 + 1 |
/// | 0x72 bit 1 | key required when TCP connects |
public struct MoreAdvancedSettings: Equatable, Sendable {
    public enum WiFiMode: Int, CaseIterable, Sendable { case ap = 0, station = 1 }

    /// Encryption codes in the order VirCom lists them.
    public static let encryptions: [(code: UInt8, title: String)] = [
        (0, "No Encrypt"), (1, "WEP64"), (5, "WEP128"), (2, "TKIP"), (4, "AES"), (6, "Auto"),
    ]

    public enum GatewayType: Int, CaseIterable, Sendable, Identifiable {
        case autoQueryStorage = 0, multiHostNonStorage, clientAndSlave, simple, preconfigured
        public var id: Int { rawValue }
        public var title: String {
            ["Auto query storage type", "Multi-host non-storage type", "Device Client & Slave mode",
             "Simple Modbus TCP to RTU", "Pre-configurable Modbus GW"][rawValue]
        }
        /// Value kept at 0x37.
        var code: UInt8 { [3, 2, 4, 0, 0][rawValue] }
    }

    public struct Destination: Equatable, Sendable {
        public var host = ""
        public var port: UInt16 = 0
        public init(host: String = "", port: UInt16 = 0) { self.host = host; self.port = port }
    }

    // WiFi
    public var wifiMode: WiFiMode = .ap
    public var ssid = ""
    public var encryption: UInt8 = 0
    public var wifiKey = ""
    public var apChannel = 4
    public var dhcpServer = true
    public var wiredRelay = false
    // VLAN
    public var vlanEnabled = false
    public var vlanID = 200
    public var vlanPriority = 0
    public var mediaTypeFDDI = false
    // Multiple destinations
    public var destinations = [Destination](repeating: Destination(), count: 7)
    // Proxy
    public var proxyEnabled = false
    public var proxyIP = IPv4(0, 0, 0, 0)
    public var proxyPort: UInt16 = 0
    public var proxyAuthentication = false
    public var proxyName = ""
    public var proxyKey = ""
    // RS485
    public var multiHostEnabled = false
    public var multiHostWaitMs = 0
    public var conflictDetection = false
    public var busIdleMs = 0
    public var conflictMode: UInt8 = 3
    public var frameEndFlowControl = false
    public var frameEndByte = "00"
    // Functions
    public var keyToModify = false
    public var receiveBroadcast = false
    public var p2p = false
    public var sendMACOnConnect = false
    public var pingDetect = false
    public var keepSerialBuffer = false
    public var keyOnTCPConnect = false
    /// Read only.
    public var supported: [String] = []

    public init() {}

    public init(_ p: DeviceParameters) {
        let flags = ParameterTLV.get(1, in: p)?.first ?? 0
        vlanEnabled = flags & 2 != 0
        ssid = ParameterTLV.get(2, in: p).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
        wifiKey = ParameterTLV.get(4, in: p).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
        if let b = ParameterTLV.get(5, in: p)?.first {
            encryption = b & 0x3F
            wifiMode = b & 0x40 == 0 ? .station : .ap
        }
        let channelByte = ParameterTLV.get(3, in: p)?.first ?? 4
        let ch = channelByte & 0x0F
        if ch >= 1, ch <= 11 {
            apChannel = Int(ch)
            dhcpServer = channelByte & 0x40 == 0
            wiredRelay = channelByte & 0x80 != 0
        }
        if let v = ParameterTLV.get(6, in: p), v.count >= 2 {
            let w = Int(v[1]) << 8 | Int(v[0])
            vlanID = w & 0xFFF
            mediaTypeFDDI = (w >> 12) & 1 != 0
            vlanPriority = w >> 13
        }
        if let list = ParameterTLV.get(7, in: p) {
            for i in 0..<7 where i * 6 + 6 <= list.count {
                let e = list[(i * 6)..<(i * 6 + 6)].map { $0 }
                destinations[i] = Destination(host: "\(e[0]).\(e[1]).\(e[2]).\(e[3])", port: UInt16(e[4]) << 8 | UInt16(e[5]))
            }
        } else if let list = ParameterTLV.get(11, in: p) {
            var i = 0, k = 0
            while i + 2 < list.count, k < 7 {
                let port = UInt16(list[i]) << 8 | UInt16(list[i + 1])
                let name = list[(i + 2)...].prefix { $0 != 0 }
                destinations[k] = Destination(host: String(decoding: name, as: UTF8.self), port: port)
                i += 2 + name.count + 1
                k += 1
            }
        }
        if let px = ParameterTLV.get(8, in: p), px.count == 0x27 {
            proxyEnabled = true
            proxyIP = IPv4(px[0], px[1], px[2], px[3])
            proxyPort = UInt16(px[4]) << 8 | UInt16(px[5])
            proxyAuthentication = px[6] != 0
            proxyName = String(decoding: px[7..<23].prefix { $0 != 0 }, as: UTF8.self)
            proxyKey = String(decoding: px[23..<39].prefix { $0 != 0 }, as: UTF8.self)
        }
        multiHostEnabled = p.raw[0x71] != 0
        // Stored as ms / 32 + 1 (VirCom shows the byte × 32, which grows by 32 ms on every save).
        multiHostWaitMs = max(Int(p.raw[0x71]) - 1, 0) << 5
        frameEndFlowControl = p.raw[0x34] == 1
        frameEndByte = String(format: "%02X", p.raw[0x35])
        busIdleMs = Int(p.raw[0x36])
        conflictDetection = p.raw[0x37] != 0
        conflictMode = p.raw[0x37] == 0 ? 3 : p.raw[0x37]
        let f = p.raw[0x6E]
        keyToModify = f & 0x04 != 0
        receiveBroadcast = f & 0x08 != 0
        p2p = f & 0x10 != 0
        sendMACOnConnect = f & 0x20 != 0
        pingDetect = f & 0x40 != 0
        keepSerialBuffer = f & 0x80 != 0
        keyOnTCPConnect = p.raw[0x72] & 0x02 != 0
        let caps = p.raw[0x70]
        supported = [(0, "IO Port Control"), (1, "UDP Group"), (2, "Multi-Dest IP"), (3, "Proxy Function"),
                     (4, "SNMP Function"), (5, "P2P Function")]
            .filter { caps & (1 << $0.0) != 0 }.map(\.1)
    }

    /// The gateway type shown in the combo box.
    public var gatewayType: GatewayType {
        get {
            guard multiHostEnabled else { return .simple }
            switch conflictMode {
            case 2: return .multiHostNonStorage
            case 4: return .clientAndSlave
            default: return .autoQueryStorage
            }
        }
        set {
            switch newValue {
            case .simple, .preconfigured:
                multiHostEnabled = false
                conflictDetection = false
                conflictMode = 0
            default:
                conflictMode = newValue.code
                multiHostEnabled = true
                conflictDetection = true
            }
        }
    }

    /// Minimum RS485 timings VirCom advises for a baud index (`0x468ae4`).
    public static func minimumTimes(baudIndex: UInt8) -> (wait: Int, idle: Int) {
        let t = [50, 25, 14, 7, 4, 3, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1][Int(baudIndex) & 0xF]
        let idle = max(2 * t + 1, 20)
        return (t * 33 + 0x6E + idle, idle)
    }

    /// Problems VirCom refuses to save.
    public func validate() -> String? {
        if wifiMode == .ap, [2, 4, 6].contains(encryption) {
            return "Please select WEP128, WEP64 or No Encrypt in WiFi AP mode."
        }
        if encryption == 1, wifiKey.utf8.count != 5 { return "The wifi key length for this WEP encryption mode must be 5." }
        if encryption == 5, wifiKey.utf8.count != 13 { return "The wifi key length for this WEP encryption mode must be 13." }
        if wifiMode == .station, [2, 4, 6].contains(encryption), ssid.utf8.count + wifiKey.utf8.count > 0x1D {
            return "The SSID length + key length is \(ssid.utf8.count + wifiKey.utf8.count), which exceeds the max length of 29."
        }
        if multiHostEnabled, multiHostWaitMs < 32 { return "After enabling RS485 multi-host, the minimum wait time must be larger than 32 ms." }
        if multiHostWaitMs > 8191 { return "The RS485 query wait time must be 0–8191 ms." }
        if ScriptText.parseHex(frameEndByte).count != 1 || frameEndByte.count != 2 { return "Frame end byte must be 2 digits." }
        if conflictDetection, busIdleMs == 0 { return "RS485 bus waiting maximum time must not be 0." }
        if busIdleMs > 255 { return "The RS485 bus idle time must be 0–255 ms." }
        if !proxyName.isEmpty, proxyName.utf8.count > 16 || proxyKey.utf8.count > 16 { return "The proxy name and key are limited to 16 characters." }
        return nil
    }

    /// Writes the settings into a parameter block. Throws when the TLV list doesn't fit.
    public func apply(to p: inout DeviceParameters) throws {
        var flags = ParameterTLV.get(1, in: p)?.first ?? 0
        flags = vlanEnabled ? flags | 2 : flags & ~2
        ParameterTLV.set(1, flags == 0 ? nil : [flags], in: &p)
        ParameterTLV.set(2, ssid.isEmpty ? nil : Array(ssid.utf8), in: &p)
        let channelByte = UInt8(apChannel & 0x0F) | (dhcpServer ? 0 : 0x40) | (wiredRelay ? 0x80 : 0)
        ParameterTLV.set(3, channelByte == 4 ? nil : [channelByte], in: &p)
        let modeByte = (wifiMode == .station ? 0x80 : 0x40) | (encryption & 0x3F)
        ParameterTLV.set(5, modeByte == 0x40 ? nil : [modeByte], in: &p)
        ParameterTLV.set(4, wifiKey.isEmpty ? nil : Array(wifiKey.utf8), in: &p)
        if vlanEnabled {
            let w = (vlanPriority & 7) << 13 | (mediaTypeFDDI ? 1 << 12 : 0) | (vlanID & 0xFFF)
            ParameterTLV.set(6, [UInt8(w & 0xFF), UInt8(w >> 8)], in: &p)
        } else {
            ParameterTLV.set(6, nil, in: &p)
        }

        let used = destinations.filter { !$0.host.isEmpty }
        if used.contains(where: { IPv4($0.host) == nil }) {
            var list: [UInt8] = []
            for d in used {
                let entry = [UInt8(d.port >> 8), UInt8(d.port & 0xFF)] + Array(d.host.utf8) + [0]
                guard list.count + entry.count < 0x34 else { break }
                list += entry
            }
            guard ParameterTLV.set(11, list, in: &p) else {
                throw DownloadError("DNS name length exceeds the maximum. All the names together must not exceed 32 bytes.")
            }
            ParameterTLV.set(7, nil, in: &p)
        } else {
            ParameterTLV.set(11, nil, in: &p)
            var list: [UInt8] = []
            for d in used {
                list += IPv4(d.host)!.array + [UInt8(d.port >> 8), UInt8(d.port & 0xFF)]
            }
            guard ParameterTLV.set(7, list.isEmpty ? nil : list, in: &p) else {
                throw DownloadError("Too many destinations for the parameter area.")
            }
        }
        if proxyEnabled, proxyIP.value != 0 {
            var px = proxyIP.array + [UInt8(proxyPort >> 8), UInt8(proxyPort & 0xFF), proxyAuthentication ? 1 : 0]
            for s in [proxyName, proxyKey] {
                let b = Array(s.utf8.prefix(16))
                px += b + [UInt8](repeating: 0, count: 16 - b.count)
            }
            guard ParameterTLV.set(8, px, in: &p) else { throw DownloadError("The proxy settings don't fit in the parameter area.") }
        } else {
            ParameterTLV.set(8, nil, in: &p)
        }

        p.raw[0x71] = multiHostEnabled ? UInt8(clamping: (multiHostWaitMs >> 5) + 1) : 0
        p.raw[0x34] = frameEndFlowControl ? 1 : 0
        p.raw[0x35] = ScriptText.parseHex(frameEndByte).first ?? 0
        p.raw[0x36] = UInt8(clamping: busIdleMs)
        p.raw[0x37] = conflictDetection ? conflictMode : 0
        var f = p.raw[0x6E] & 0x03
        if keyToModify { f |= 0x04 }
        if receiveBroadcast { f |= 0x08 }
        if p2p { f |= 0x10 }
        if sendMACOnConnect { f |= 0x20 }
        if pingDetect { f |= 0x40 }
        if keepSerialBuffer { f |= 0x80 }
        p.raw[0x6E] = f
        p.raw[0x72] = keyOnTCPConnect ? p.raw[0x72] | 0x02 : p.raw[0x72] & ~0x02
    }
}

/// The "Register Pkt" field of Device Settings (`0x41af89`). When the option list ends at or before
/// 0x82, VirCom clears it and stores `content NUL port(BE)` at 0x82 (the content is hex text,
/// e.g. "01 02"). A second "parameter destination" may follow the same way.
public struct DeviceRegisterPacket: Equatable, Sendable {
    public static let offset = 0x82
    public var enabled = false
    /// Hex text as stored ("01 02 0A").
    public var content = ""
    public var port: UInt16 = 0

    public init() {}

    /// End of the option list (VirCom's `0x42dc30`): absolute offset after the terminator, or nil when full.
    static func optionListEnd(_ p: DeviceParameters) -> Int? {
        var i = 0
        while i < ParameterTLV.size {
            if p.raw[ParameterTLV.offset + i] == 0 { return ParameterTLV.offset + i + 1 }
            i += 2 + Int(p.raw[ParameterTLV.offset + i + 1])
        }
        return nil
    }

    public init(_ p: DeviceParameters) {
        guard let end = Self.optionListEnd(p), end <= Self.offset, p.raw[Self.offset] != 0 else { return }
        let text = p.raw[Self.offset..<0xA7].prefix { $0 != 0 }
        let after = Self.offset + text.count + 1
        enabled = true
        content = String(decoding: text, as: UTF8.self)
        if after + 1 < 0xA7 { port = UInt16(p.raw[after]) << 8 | UInt16(p.raw[after + 1]) }
    }

    /// `asciiText` converts typed text to hex first, like the ASCII checkbox.
    public func apply(to p: inout DeviceParameters, asciiText: Bool = false) throws {
        let text = asciiText ? ScriptText.hex(content).trimmingCharacters(in: .whitespaces) : content
        guard let end = Self.optionListEnd(p), end <= Self.offset else {
            if enabled { throw DownloadError("This device's option area is in use (More Advanced Settings), so a register packet can't be stored.") }
            return
        }
        if enabled, !text.isEmpty {
            let bytes = Array(text.utf8)
            guard bytes.count <= 0x21 else { throw DownloadError("The register packet must be 33 characters or fewer.") }
            var area = [UInt8](repeating: 0, count: 0xA7 - ParameterTLV.offset)
            let start = Self.offset - ParameterTLV.offset
            area.replaceSubrange(start..<(start + bytes.count), with: bytes)
            area[start + bytes.count + 1] = UInt8(port >> 8)
            area[start + bytes.count + 2] = UInt8(port & 0xFF)
            p.raw.replaceSubrange(ParameterTLV.offset..<0xA7, with: area)
        } else {
            p.raw[Self.offset] = 0
            p.raw[Self.offset + 3] = 0
        }
    }
}
