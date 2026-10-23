public import Foundation
import CommonCrypto

/// Files VirCom's download tool writes into the web page directory. They are packed into the
/// device's flash along with the pages.
public enum ConfigFileName {
    public static let script = "httpd.txt"   // programmable protocol script
    public static let mqtt = "mqtt.txt"
    public static let json = "json"           // JSON designer (PC side)
    public static let json2 = "json2"
    public static let jsonToSerial = "jsonw"
    public static let modbusGateway = "MB"     // Modbus gateway designer (PC side)
    public static let stateTransfer = "st.hex"
    public static let ntp = "ntp.txt"
    public static let filler = "z"
}

// MARK: - MQTT (mqtt.txt)

/// VirCom's "MQTT connect settings" and "MQTT Advanced Settings" (`0x416ca0`, `0x417080`).
public struct MQTTConfig: Codable, Sendable, Equatable {
    public enum Version: String, CaseIterable, Codable, Sendable, Identifiable {
        case v311 = "4", v31 = "3"
        public var id: String { rawValue }
        public var title: String { self == .v311 ? "3.1.1" : "3.1" }
    }

    /// Where the device connects. VirCom writes these into the device settings (destination,
    /// TCP Client mode), not into mqtt.txt.
    public var serverHost = ""
    public var serverPort: UInt16 = 1883

    public var version: Version = .v311
    public var clientID = "zlanid"
    public var userName = "btjzew4/zlanname"
    public var password = ""
    public var keepAlive = "60"
    public var cleanSession = "1"
    public var willFlag = "0"
    public var willTopic = ""
    public var willMessage = ""
    public var willRetain = "0"
    public var willQoS = "0"
    public var subscribeTopic = "zlansub"
    public var subscribeQoS = "1"
    public var publishTopic = "zlansub"
    public var publishQoS = "1"
    public var publishRetain = "0"

    public init() {}

    /// Ready-made settings for the cloud platforms VirCom knows (`0x450140`).
    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        case aliyun, baidu, onenet
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .aliyun: "Alibaba Cloud IoT"
            case .baidu: "Baidu IoT"
            case .onenet: "China Mobile OneNET"
            }
        }
    }

    public mutating func apply(_ preset: Preset) {
        switch preset {
        case .aliyun:
            serverHost = "ProductKey.iot-as-mqtt.cn-shanghai.aliyuncs.com"
            serverPort = 1883
            userName = "DeviceName&ProductKey"
            clientID = "AnyNumbers|securemode=3,signmethod=hmacsha1|"
            subscribeTopic = "/ProductKey/DeviceName/user/get"
            publishTopic = "/ProductKey/DeviceName/user/update"
        case .baidu:
            serverHost = "ProductKey.mqtt.iot.gz.baidubce.com"
            serverPort = 1883
            userName = "ProjectName/DeviceName"
            clientID = "IDName"
            subscribeTopic = "SubName"
            publishTopic = "PubName"
        case .onenet:
            serverHost = "183.230.40.39"
            serverPort = 6002
            userName = "ProductID"
            clientID = "DeviceID"
            subscribeTopic = "AnySub"
            publishTopic = "$dp"
        }
    }

    /// The `[MQTT]` INI section in the order VirCom writes it.
    public var fileText: String {
        let pairs: [(String, String)] = [
            ("VER", version.rawValue), ("CLIENT_ID", clientID), ("USERNAME", userName), ("PASSWD", password),
            ("KEEPALIVE", keepAlive), ("CLEAN_SESSION", cleanSession), ("WILL_FLAG", willFlag),
            ("WILL_TOPIC", willTopic), ("WILL_MESSAGE", willMessage), ("WILL_RETAIN", willRetain),
            ("WILL_QOS", willQoS), ("SUBSCRIBE_TOPIC", subscribeTopic), ("SUBSCRIBE_QOS", subscribeQoS),
            ("PUBLISH_TOPIC", publishTopic), ("PUBLISH_QOS", publishQoS), ("PUBLISH_RETAIN", publishRetain),
        ]
        return "[MQTT]\r\n" + pairs.map { "\($0.0)=\($0.1)\r\n" }.joined()
    }

    /// Reads an existing mqtt.txt (missing keys keep their defaults). Server settings aren't in the file.
    public init(fileText: String) {
        self.init()
        let ini = INI.parse(fileText)["MQTT"] ?? [:]
        func v(_ k: String, _ d: String) -> String { ini[k] ?? d }
        version = Version(rawValue: v("VER", "4")) ?? .v311
        clientID = v("CLIENT_ID", "")
        userName = v("USERNAME", "")
        password = v("PASSWD", "")
        keepAlive = v("KEEPALIVE", "60")
        cleanSession = v("CLEAN_SESSION", "1")
        willFlag = v("WILL_FLAG", "0")
        willTopic = v("WILL_TOPIC", "")
        willMessage = v("WILL_MESSAGE", "")
        willRetain = v("WILL_RETAIN", "0")
        willQoS = v("WILL_QOS", "0")
        subscribeTopic = v("SUBSCRIBE_TOPIC", "")
        subscribeQoS = v("SUBSCRIBE_QOS", "1")
        publishTopic = v("PUBLISH_TOPIC", "")
        publishQoS = v("PUBLISH_QOS", "1")
        publishRetain = v("PUBLISH_RETAIN", "0")
    }

    /// The destination VirCom stores: domains longer than 29 characters are replaced by their IP.
    public func destinationHost() -> String {
        guard serverHost.count > 29 else { return serverHost }
        return NameResolver.ipv4(serverHost) ?? String(serverHost.prefix(29))
    }
}

enum INI {
    static func parse(_ text: String) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast())
            } else if let eq = line.firstIndex(of: "=") {
                out[section, default: [:]][String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return out
    }
}

enum NameResolver {
    static func ipv4(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            IPv4(value: UInt32(bigEndian: $0.pointee.sin_addr.s_addr)).description
        }
    }
}

// MARK: - Script helpers

public enum ScriptText {
    /// VirCom's ASCII-to-hex conversion (`0x42da90`): "XX " per byte, trailing space kept.
    public static func hex(_ text: String) -> String {
        Array(text.utf8).map { String(format: "%02X ", $0) }.joined()
    }

    /// VirCom's hex parser (`0x44d5f0`): pairs of hex digits, a lone digit as one byte, other
    /// characters skipped.
    public static func parseHex(_ text: String) -> [UInt8] {
        let chars = Array(text.utf8)
        func isHex(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c) }
        var out: [UInt8] = []
        var i = 0
        while i < chars.count {
            if isHex(chars[i]) {
                if i + 1 < chars.count, isHex(chars[i + 1]) {
                    out.append(UInt8(String(bytes: chars[i...(i + 1)], encoding: .ascii)!, radix: 16)!)
                    i += 2
                } else {
                    out.append(UInt8(String(bytes: [chars[i]], encoding: .ascii)!, radix: 16)!)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return out
    }
}

// MARK: - Register and heartbeat packets (httpd.txt)

/// "Register packet and heart beat packet settings" (`0x41ed70`). Needs firmware 1.589 or later.
public struct RegisterPacketConfig: Codable, Sendable, Equatable {
    public var registerPacket = ""
    public var registerIsASCII = false
    public var heartbeatPacket = ""
    public var heartbeatIsASCII = false
    /// Seconds.
    public var heartbeatInterval = 0

    public init() {}

    /// The script to write, or nil when there's nothing to write. `existingScript` is the current
    /// httpd.txt (kept when only a register packet is set, as VirCom does).
    public func script(existingScript: String?) throws -> String? {
        func payload(_ s: String, _ ascii: Bool) -> String { ascii ? ScriptText.hex(s) : s }
        if !heartbeatPacket.isEmpty {
            guard heartbeatInterval != 0 else { throw DownloadError("Heartbeat interval cannot be 0!") }
            let t = heartbeatInterval * 1000
            var s = "N2S: N[0...len]\r\nS2N: S[0...len]\r\n"
            s += String(format: "I2N: = %02X %02X ADD[1] 00 00\r\n", t >> 16, (t >> 8) & 0xFF)
            s += "T2N: \(payload(heartbeatPacket, heartbeatIsASCII)) = 00 01\r\n"
            if !registerPacket.isEmpty { s += "REG: \(payload(registerPacket, registerIsASCII))\r\n" }
            return s
        }
        guard !registerPacket.isEmpty else { return nil }
        var s: String
        if let existing = existingScript, !existing.contains("ADD[1] 00 00") {
            s = existing
            if !existing.contains("N2S: N[0...len]") { s += "\r\nN2S: N[0...len]" }
            if !existing.contains("S2N: S[0...len]") { s += "\r\nS2N: S[0...len]" }
        } else {
            s = "\r\nN2S: N[0...len]\r\nS2N: S[0...len]"
        }
        return s + "\r\nREG: \(payload(registerPacket, registerIsASCII))"
    }
}

// MARK: - Configurable Modbus gateway (httpd.txt + MB)

/// One row of "Configurable Modbus GateWay Settings" ("Add ZLMB Modbus Command").
public struct ModbusGatewayCommand: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var slaveAddress = 1
    /// 1 coils, 2 discrete inputs, 3 holding registers, 4 input registers.
    public var function = 3
    public var registerAddress = 0
    public var length = 1
    /// ms, more than 10.
    public var queryInterval = 100
    /// ms.
    public var replyTimeout = 200
    public var supportsWrite = false
    /// Assigned automatically: the command's start in the Modbus TCP map.
    public var tcpRegisterAddress = 0

    public init() {}

    /// Registers the command occupies in the map: coils are packed 16 to a register.
    var words: Int {
        switch function {
        case 1, 2:
            var bytes = (length - 1) / 8 + 1
            if bytes & 1 != 0 { bytes += 1 }
            return bytes / 2
        default:
            return length
        }
    }

    var writeFunction: Int { function == 1 || function == 2 ? 5 : 6 }
}

public enum ModbusGatewayScript {
    /// Recomputes the Modbus TCP addresses (`0x413a90`): coil commands start on a 16-bit boundary.
    public static func assignAddresses(_ commands: inout [ModbusGatewayCommand]) -> Int {
        var total = 0
        for i in commands.indices {
            commands[i].tcpRegisterAddress = commands[i].function <= 2 ? total << 4 : total
            total += commands[i].words
        }
        return total
    }

    /// The httpd.txt script (`0x413af0`).
    public static func script(_ input: [ModbusGatewayCommand]) -> String {
        var commands = input
        let n = commands.count
        guard n > 0 else { return "" }
        let total = assignAddresses(&commands)
        var s = "S2M:M[0...idx-1] S[3...len-2] = S[0] IRANGE8[260] S[2...len-2] CRC[0...1]\r\n"
        s += String(format: "N2N: N[0...1] 00 00 00 ADDIM[779] N[6...7] ADDIM[11] MI16[%d...med] = N[0...1] 00 00 00 06 N[6] IRANGE8[260] N[8...11]\r\n", 9 * n + 0x1F49)
        for c in commands where c.supportsWrite {
            let first = c.tcpRegisterAddress >> 8
            let last = (c.tcpRegisterAddress + c.length - 1) >> 8
            guard first <= last else { continue }
            var high = 0xFF  // VirCom leaves this unset until the last page; the whole page is meant.
            for page in first...last {
                let low = page == first ? c.tcpRegisterAddress & 0xFF : 0
                if page == last { high = (c.tcpRegisterAddress + c.length - 1) & 0xFF }
                let range = low << 8 | high
                s += String(format: "N2N: N[0...len] = N[0...6] %02X %02X IRANGE8[%d] N[10...len]\r\n", c.writeFunction, page, range)
                var diff = c.registerAddress - c.tcpRegisterAddress
                if diff < 0 { diff += 0x10000 }
                s += String(format: "NTS: %02X N[7] ADDI16[%d] ADDI16[%d] N[10...len] CRC[0...1] = N[0...6] %02X %02X IRANGE8[%d] N[10...len]\r\n",
                            c.slaveAddress, diff, diff, c.writeFunction, page, range)
            }
        }
        s += "T2M: M[0...8] "
        var index = 9 * n + 9
        for c in commands {
            s += String(format: "%02X %02X %02X %02X %02X %02X %02X %02X %02X ",
                        (index >> 8) & 0xFF, index & 0xFF, c.slaveAddress, c.function,
                        (c.registerAddress >> 8) & 0xFF, c.registerAddress & 0xFF,
                        (c.length >> 8) & 0xFF, c.length & 0xFF, 2 * c.words - 1)
            index += 2 * c.words
        }
        s += "= 00 11\r\n"
        s += "T2M: M[0...3] 00 09 = 00 11\r\n"
        s += "T2M: M[0...1] M[9] M[10] = 00 11\r\n"
        s += "I2M: 00 = 00 11 CMP[40] 00 02\r\n"
        s += "T2M: M[0...1] M[id2] M[id2+1] = 00 11\r\n"
        s += "T2S: M[id2+2...id2+7] CRC[0...1] = 00 11\r\n"
        let interval = commands.map(\.queryInterval).max() ?? 0
        let timeout = commands.map(\.replyTimeout).max() ?? 0
        s += String(format: "I2M: M[%d] = %02X %02X STATE[1] 00 0C\r\n", 9 * n + 2 * total + 10, (interval >> 8) & 0xFF, interval & 0xFF)
        s += "T2S: M[id2+2...id2+7] CRC[0...1] = 00 11\r\n"
        s += String(format: "I2M: 00 = %02X %02X STATE[1] 00 0C\r\n", (timeout >> 8) & 0xFF, timeout & 0xFF)
        s += "T2M: M[0...5] 00 M[id2+8] = 00 11\r\n"
        s += "T2M: M[0...idx-1] ZERO[0...id3] = 00 11\r\n"
        s += "T2M: 00 09 = 00 11\r\n"
        s += "I2M: ADD16[4] = 00 11 01 00 03\r\n"
        return s
    }

    /// The "MB" file VirCom keeps to reload the table: "V0001\0" and one 40-byte record per command
    /// (little-endian: next, number, slave, function, address, length, interval, timeout, write, TCP address).
    public static func designFile(_ input: [ModbusGatewayCommand]) -> [UInt8] {
        var commands = input
        _ = assignAddresses(&commands)
        var out = Array("V0001".utf8) + [0]
        for (i, c) in commands.enumerated() {
            let fields = [i + 1 < commands.count ? 1 : 0, i + 1, c.slaveAddress, c.function, c.registerAddress, c.length,
                          c.queryInterval, c.replyTimeout, c.supportsWrite ? 1 : 0, c.tcpRegisterAddress]
            for f in fields { withUnsafeBytes(of: Int32(truncatingIfNeeded: f).littleEndian) { out += $0 } }
        }
        return out
    }

    public static func parseDesignFile(_ bytes: [UInt8]) -> [ModbusGatewayCommand] {
        guard bytes.count >= 6, Array(bytes[0..<5]) == Array("V0001".utf8) else { return [] }
        var out: [ModbusGatewayCommand] = []
        var p = 6
        while p + 40 <= bytes.count {
            func f(_ k: Int) -> Int {
                Int(Int32(littleEndian: bytes[(p + 4 * k)..<(p + 4 * k + 4)].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
            }
            var c = ModbusGatewayCommand()
            c.slaveAddress = f(2); c.function = f(3); c.registerAddress = f(4); c.length = f(5)
            c.queryInterval = f(6); c.replyTimeout = f(7); c.supportsWrite = f(8) != 0; c.tcpRegisterAddress = f(9)
            out.append(c)
            p += 40
        }
        return out
    }
}

// MARK: - State transfer (st.hex)

/// One dialog of "State Transfer Design" (`0x44f860`).
public struct TransferState: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    /// Send `command` when entering the state (otherwise just wait).
    public var sendsCommand = true
    public var command = "12 ab"
    public var commandIsHex = true
    public var delayEnabled = false
    public var delayMs = 100
    public var delayTarget = 0
    public var idleEnabled = false
    public var idleMs = 100
    public var idleTarget = 0
    public var dataEnabled = false
    public var dataTarget = 0

    public init(number: Int = 0) {
        delayTarget = number + 1
        idleTarget = number + 1
        dataTarget = number + 1
    }
}

public enum StateTransferFile {
    /// Big-endian: count, then per state: number, delay ms (0 if off), delay target, idle ms (0 if off),
    /// idle target, data flag (1 byte), data target, command length and bytes (length 0 to just wait).
    public static func encode(_ states: [TransferState]) -> [UInt8] {
        var out: [UInt8] = []
        func u16(_ v: Int) { out += [UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        u16(states.count)
        for (i, s) in states.enumerated() {
            u16(i)
            u16(s.delayEnabled ? s.delayMs : 0)
            u16(s.delayTarget)
            u16(s.idleEnabled ? s.idleMs : 0)
            u16(s.idleTarget)
            out.append(s.dataEnabled ? 1 : 0)
            u16(s.dataTarget)
            if s.sendsCommand {
                let bytes = s.commandIsHex ? ScriptText.parseHex(s.command) : Array(s.command.utf8)
                u16(bytes.count)
                out += bytes
            } else {
                u16(0)
            }
        }
        return out
    }
}

// MARK: - Directory operations

public enum ConfigDirectory {
    /// Bind ID (`0x450b40`): an empty "ID<device id>.txt" marks the directory for one device.
    public static func bind(_ dir: URL, deviceID: String) throws {
        for f in idFiles(dir) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("ID\(deviceID).txt").path, contents: Data())
    }

    /// The device ID a directory is bound to, if any.
    public static func boundID(_ dir: URL) -> String? {
        idFiles(dir).first.map { String($0.dropFirst(2).dropLast(4)) }
    }

    /// Download check (`0x4509c0`): a bound directory may only go to that device.
    public static func checkBinding(_ dir: URL, deviceID: String) throws {
        if let bound = boundID(dir), bound != deviceID {
            throw DownloadError("Wrong device. This folder was designed for the device with ID: \(bound), but you're sending it to \(deviceID). Remove ID\(bound).txt from the web page folder to unbind it.")
        }
    }

    static func idFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("ID") && $0.hasSuffix(".txt") && $0.count >= 6 }
    }

    /// "Clear all" (`0x450530`): removes the configuration files and writes the 256-byte filler "z".
    public static func clearAll(_ dir: URL) {
        for name in [ConfigFileName.script, ConfigFileName.mqtt, ConfigFileName.json, ConfigFileName.modbusGateway, ConfigFileName.jsonToSerial] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent(ConfigFileName.filler).path, contents: Data(count: 0x100))
    }
}

// MARK: - httpd.txt encryption ("E" / "D")

/// AES-128-ECB with VirCom's fixed key (`0x44d870`, `0x44da50`). The file becomes
/// `00 00 type(BE16) length(BE32)` and the encrypted, zero-padded data.
public enum ScriptEncryption {
    static let key = Array("2327628244835630".utf8)
    /// VirCom asks for this password before decrypting.
    public static let decryptPassword = "zlan22"

    public static func encrypt(_ plain: [UInt8], type: UInt16 = 2) throws -> [UInt8] {
        guard let first = plain.first, first != 0 else { throw DownloadError("The file is empty or already encrypted.") }
        var padded = plain
        if padded.count % 16 != 0 { padded += [UInt8](repeating: 0, count: 16 - padded.count % 16) }
        let n = plain.count
        let header: [UInt8] = [0, 0, UInt8(type >> 8), UInt8(type & 0xFF),
                               UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                               UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
        return header + (try crypt(padded, operation: CCOperation(kCCEncrypt)))
    }

    public static func decrypt(_ file: [UInt8]) throws -> [UInt8] {
        guard file.count >= 8, file[0] == 0 else { throw DownloadError("The file is not encrypted.") }
        let type = Int(file[2]) << 8 | Int(file[3])
        let n = Int(file[4]) << 24 | Int(file[5]) << 16 | Int(file[6]) << 8 | Int(file[7])
        guard type != 0, type < 3, n + 8 <= file.count, file.count < n + 0x18, (file.count - 8) % 16 == 0 else {
            throw DownloadError("The file is not encrypted.")
        }
        return Array(try crypt(Array(file[8...]), operation: CCOperation(kCCDecrypt)).prefix(n))
    }

    public static func isEncrypted(_ file: [UInt8]) -> Bool { (try? decrypt(file)) != nil }

    static func crypt(_ data: [UInt8], operation: CCOperation) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw DownloadError("Encryption failed (\(status)).") }
        return Array(out.prefix(moved))
    }
}

// MARK: - Clear web login key

public enum WebLoginKey {
    /// "Clear web key" (`0x44fca0`): posts an empty key to the device's web server on port 80.
    public static func clear(host: String) async throws {
        try DeviceWriteGuard.check("Clear web login key")
        try await Task.detached {
            let request = Array("POST /ok.html HTTP/1.1\r\nContent-Length: 15\r\n\r\nnwk=&rtp=&post=1".utf8)
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw DownloadError("Unable to create a socket.") }
            defer { close(fd) }
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "80", &hints, &res) == 0, let info = res else { throw DownloadError("Can't resolve \(host).") }
            defer { freeaddrinfo(res) }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
                throw DownloadError("Can't connect to \(host):80.")
            }
            pause(0.1)
            _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            pause(0.1)
        }.value
    }
}
