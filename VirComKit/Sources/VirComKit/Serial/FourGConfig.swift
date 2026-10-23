public import Foundation
import CoreFoundation

/// VirCom's "4G Config Tools": text commands over the module's serial port.
///
/// - Enter configuration mode: send `REQUEST CFG MODE` three times every 2 s until the module
///   answers `CFG MODE\r` (up to 16 s).
/// - Log in: `ZL+LOGIN=<key>\r\n` → `+LOGIN:OK`.
/// - Read: `ZL+<NAME>?\r\n` → `+<NAME>:<value>\r\n`.  Write: `ZL+<NAME>=<value>\r\n`.
/// - Text is GBK (the protocol names include Chinese).
public enum FourGCommand {
    /// Basic parameters (`0x432800` / `0x432a00`).
    public static let main = ["BAUD", "PIPADD", "PPORT", "PROTOCOL"]
    /// Read-only information.
    public static let info = ["STAT", "ID", "VER"]
    /// "Advanced Parameters" (`0x432da0` / `0x433350`).
    public static let advanced = [
        "MODE", "HEARTIME", "HEARTDAT", "PDNS", "DATAB", "CHECKB", "EN_ENROL", "ENROL",
        "APNN", "APN_USERNAME", "APN_PASSWORD",
        "MQTT_USERNAME", "MQTT_PASSWD", "MQTT_CLIENT", "MQTT_SUBSCRIBE_TOPIC", "MQTT_SUBSCRIBE_QOS",
        "MQTT_PUBLISH_TOPIC", "MQTT_PUBLISH_QOS", "MQTT_KEEPALIVE", "MQTT_WILL_TOPIC", "MQTT_WILL_MESSAGE",
        "Z_RMT_MAG", "Z_RMT_IP", "Z_RMT_PORT",
    ]

    public static let baudRates = ["1200", "2400", "4800", "7200", "9600", "14400", "19200", "28800",
                                   "38400", "57600", "76800", "115200", "230400", "460800"]
    /// Protocol values as the module spells them, with English titles.
    public static let protocols: [(value: String, title: String)] = [
        ("TCP", "TCP"), ("UDP", "UDP"), ("双向透传", "Two-way transparent"),
        ("modbus协议转化", "Modbus protocol conversion"), ("MQTT", "MQTT"),
    ]
    public static let parities = ["N", "O", "E", "M", "S"]
    public static let dataBits = ["5", "6", "7", "8"]

    static let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    public static func encode(_ s: String) -> [UInt8] { Array(s.data(using: gbk) ?? Data(s.utf8)) }
    public static func decode(_ b: [UInt8]) -> String { String(data: Data(b), encoding: gbk) ?? String(decoding: b, as: UTF8.self) }

    public static func query(_ name: String) -> [UInt8] { encode("ZL+\(name)?\r\n") }
    public static func set(_ name: String, _ value: String) -> [UInt8] { encode("ZL+\(name)=\(value)\r\n") }
    public static func login(_ key: String) -> [UInt8] { encode("ZL+LOGIN=\(key)\r\n") }
    public static let requestConfigMode = Array("REQUEST CFG MODE".utf8)

    /// `+NAME:value` lines. The module reports MODE as ZL_MODE.
    public static func parse(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("+"), let colon = line.firstIndex(of: ":") else { return nil }
            var key = String(line[line.index(after: line.startIndex)..<colon])
            if key == "ZL_MODE" { key = "MODE" }
            return (key, String(line[line.index(after: colon)...]))
        }
    }
}

/// A serial session with a 4G module. Methods block; call them from a background task.
public final class FourGSession: @unchecked Sendable {
    public let link: SerialLink
    private var pending = ""

    public init(path: String, settings: SerialLinkSettings) throws {
        link = try SerialLink(path: path, settings: settings)
    }

    /// Everything the module sent since the last call, decoded.
    public func drain(timeout: Duration = .milliseconds(50)) -> String {
        FourGCommand.decode(link.readAvailable(timeout: timeout, idle: .milliseconds(30)))
    }

    /// Asks the module into configuration mode. `log` receives the module's output.
    public func enterConfigMode(log: (String) -> Void) throws -> Bool {
        var buffer = ""
        for i in 0..<80 {
            try Task.checkCancellation()
            if i % 10 == 0 {
                for _ in 0..<3 { try link.write(FourGCommand.requestConfigMode) }
            }
            let got = drain(timeout: .milliseconds(200))
            if !got.isEmpty { log(got); buffer += got }
            if buffer.contains("CFG MODE") { return true }
        }
        return false
    }

    public func login(_ key: String) throws -> Bool {
        try link.write(FourGCommand.login(key))
        let reply = drain(timeout: .seconds(2))
        return FourGCommand.parse(reply).contains { $0.0 == "LOGIN" && $0.1.hasPrefix("OK") }
    }

    /// Reads the named parameters. Missing replies are left out.
    public func read(_ names: [String], log: (String) -> Void) throws -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            try Task.checkCancellation()
            try link.write(FourGCommand.query(name))
            let reply = drain(timeout: .milliseconds(600))
            if !reply.isEmpty { log(reply) }
            for (k, v) in FourGCommand.parse(reply) { values[k] = v }
        }
        return values
    }

    /// Writes parameters one by one, like VirCom (with a short pause after each).
    public func write(_ values: [(String, String)], log: (String) -> Void) throws {
        for (name, value) in values {
            try Task.checkCancellation()
            try link.write(FourGCommand.set(name, value))
            let reply = drain(timeout: .milliseconds(300))
            if !reply.isEmpty { log(reply) }
        }
    }

    public func send(_ line: String) throws {
        try link.write(FourGCommand.encode(line + "\r\n"))
    }
}
