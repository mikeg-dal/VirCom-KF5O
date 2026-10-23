public import Foundation

public struct DownloadProgress: Sendable, Equatable {
    public var sent: Int
    public var total: Int

    public init(sent: Int, total: Int) {
        self.sent = sent
        self.total = total
    }
}

/// Messages from VirCom's string table.
public enum DownloadMessage {
    public static let complete = "Sent. Don't power off the device while its LINK light is blinking."
    public static let flashWriteFailed = "The device couldn't write the files to its flash memory."
    public static let serialHandshakeFailed =
        "Sending failed. The device may have restarted. Close this window and search for it over the serial port again."
}

/// The packets of VirCom's network download protocols (`0x44edd0`). Every packet is 140 bytes and
/// starts `5A 4C 11`; unused bytes are zero.
public enum DownloadPacket {
    public static let size = 140
    static let header: [UInt8] = [0x5A, 0x4C, 0x11]

    /// 2003/7004 models: 128-byte chunks with a CRC.
    ///
    ///     3  offset (BE32)   7  length (BE16)   9  CRC (over bytes 3…139 with this field zero)
    ///     11 flag: 0 for web pages; 1 more / 0x81 last for code   12 data
    public static func sequenced(offset: Int, chunk: ArraySlice<UInt8>, flag: UInt8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: size)
        p.replaceSubrange(0..<3, with: header)
        put32(&p, 3, offset)
        put16(&p, 7, chunk.count)
        p[11] = flag
        p.replaceSubrange(12..<(12 + chunk.count), with: chunk)
        let crc = DownloadCRC.bytes(p[3..<(3 + 0x89)])
        p[9] = crc[0]
        p[10] = crc[1]
        return p
    }

    /// 2030/2032EX with more than 7 KB flash: 64-byte chunks.
    ///
    ///     3 offset (BE32)   7 length (BE16)   9 1 when this is the last chunk   10 data
    public static func windowed(offset: Int, chunk: ArraySlice<UInt8>, last: Bool) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: size)
        p.replaceSubrange(0..<3, with: header)
        put32(&p, 3, offset)
        put16(&p, 7, chunk.count)
        p[9] = last ? 1 : 0
        p.replaceSubrange(10..<(10 + chunk.count), with: chunk)
        return p
    }

    /// 2030/2032EX with 7 KB flash: a 16-bit flash address, 64-byte chunks.
    ///
    ///     3 address (BE16) = offset − 7 KB − 0x1000   5 length (BE16)   7 data
    public static func legacy(offset: Int, chunk: ArraySlice<UInt8>) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: size)
        p.replaceSubrange(0..<3, with: header)
        put16(&p, 3, (offset - 7 * 1024 - 0x1000) & 0xFFFF)
        put16(&p, 5, chunk.count)
        p.replaceSubrange(7..<(7 + chunk.count), with: chunk)
        return p
    }

    static func put16(_ p: inout [UInt8], _ i: Int, _ v: Int) {
        p[i] = UInt8(truncatingIfNeeded: v >> 8)
        p[i + 1] = UInt8(truncatingIfNeeded: v)
    }

    static func put32(_ p: inout [UInt8], _ i: Int, _ v: Int) {
        for k in 0..<4 { p[i + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) }
    }

    /// Image length rounded up to whole 4 KB sectors.
    public static func sectorRounded(_ n: Int) -> Int { n % 4096 == 0 ? n : (n / 4096 + 1) * 4096 }

    /// Device acknowledgement: at least 41 bytes, byte 2 = 0x12 (0x15 = negative).
    public static func replyCode(_ r: [UInt8]) -> UInt8? { r.count > 0x28 ? r[2] : nil }

    /// Newer 2003/7004 firmware names the acknowledged position: "code_w_with_seq" at 0x45 and the
    /// next offset (BE32) at 0x0F.
    public static func acknowledgedOffset(_ r: [UInt8]) -> Int? {
        let tag = Array("code_w_with_seq".utf8) + [0]
        guard r.count >= 0x45 + tag.count, Array(r[0x45..<(0x45 + tag.count)]) == tag else { return nil }
        return Int(r[15]) << 24 | Int(r[16]) << 16 | Int(r[17]) << 8 | Int(r[18])
    }
}

/// Downloads web pages or firmware over UDP to the device's management port (1092).
public struct NetworkDownloader: Sendable {
    public var host: String
    public var port: UInt16
    public var model: DownloadModel
    public var kind: DownloadKind
    public var flashKB: Int

    public init(host: String, port: UInt16 = ZLProtocol.managementPort, model: DownloadModel, kind: DownloadKind, flashKB: Int) {
        self.host = host
        self.port = port
        self.model = model
        self.kind = kind
        self.flashKB = flashKB
    }

    /// Sends `image` and returns the completion message. Cancel the task to stop.
    public func run(_ image: FlashImage, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> String {
        try DeviceWriteGuard.check("Network download")
        let me = self
        return try await Task.detached(priority: .userInitiated) {
            let socket = try UDPSocket(preferredPort: 0)
            defer { socket.close() }
            if me.model.supportsCodeDownload {
                try me.sequenced(image, socket, progress)
            } else if me.kind == .code {
                throw DownloadError("This device model can't receive firmware.")
            } else if me.flashKB > 7 {
                try me.windowed(image, socket, progress)
            } else {
                try me.legacy(image, socket, progress)
            }
            return DownloadMessage.complete
        }.value
    }

    private func padded(_ image: FlashImage, to total: Int) -> [UInt8] {
        var b = Array(image.bytes.prefix(total))
        if b.count < total { b += [UInt8](repeating: 0, count: total - b.count) }
        return b
    }

    private func sequenced(_ image: FlashImage, _ s: UDPSocket, _ progress: @Sendable (DownloadProgress) -> Void) throws {
        let total = DownloadPacket.sectorRounded(image.usedLength)
        let data = padded(image, to: total)
        var offset = 0
        var waitLoops = 100  // VirCom's adaptive receive window (in 1 ms polls)
        var failures = 0
        progress(.init(sent: 0, total: total))
        while offset < total {
            try Task.checkCancellation()
            let n = min(0x80, total - offset)
            let flag: UInt8 = kind == .webpage ? 0 : (offset + n < total ? 1 : 0x81)
            drain(s)
            try s.send(DownloadPacket.sequenced(offset: offset, chunk: data[offset..<(offset + n)], flag: flag), to: host, port: port)
            var loop = 0
            var advanced = false
            while loop < waitLoops {
                if let (r, _, _) = s.receive(timeout: .milliseconds(max(loop, 1))), DownloadPacket.replyCode(r) == 0x12 {
                    if let acked = DownloadPacket.acknowledgedOffset(r) {
                        if acked == offset + n {
                            waitLoops = Int((Double(loop + 1) * 1.5 + Double(waitLoops)) * 0.5)
                            advanced = true
                        }
                    } else {
                        advanced = true  // older firmware: any acknowledgement
                    }
                    break
                }
                if offset == 0, loop > 100 { loop = waitLoops; break }
                loop += 1
            }
            if advanced {
                failures = 0
                offset += n
                progress(.init(sent: offset, total: total))
            } else if loop >= waitLoops {
                failures += 1
                waitLoops = min(waitLoops * 2, 100)
                if (failures >= 3 && offset == 0) || failures >= 8 {
                    throw DownloadError(DownloadMessage.flashWriteFailed)
                }
            }
        }
        if kind == .code { pause(5) }
        pause(4)
    }

    private func windowed(_ image: FlashImage, _ s: UDPSocket, _ progress: @Sendable (DownloadProgress) -> Void) throws {
        let total = DownloadPacket.sectorRounded(image.usedLength)
        let data = padded(image, to: total)
        var offset = 0, acked = 0, nacks = 0
        var heardBack = false
        progress(.init(sent: 0, total: total))
        while true {
            try Task.checkCancellation()
            let n = min(0x40, total - offset)
            let last = offset + n >= total
            try s.send(DownloadPacket.windowed(offset: offset, chunk: data[offset..<(offset + n)], last: last), to: host, port: port)
            if last { break }
            // VirCom polls 8 times 1 ms until the device first answers, then up to 308 times.
            let window = heardBack ? 0x124 + 8 : 8
            var reply: UInt8?
            for _ in 0..<window {
                if let (r, _, _) = s.receive(timeout: .milliseconds(1)), let code = DownloadPacket.replyCode(r), code == 0x12 || code == 0x15 {
                    reply = code
                    break
                }
            }
            switch reply {
            case 0x12:
                nacks = 0
                heardBack = true
                offset += n
                acked = offset
            case 0x15:
                heardBack = true
                nacks += 1
                if nacks >= 8 { throw DownloadError(DownloadMessage.flashWriteFailed) }
                offset = acked
            default:
                offset += n  // no answer: carry on
            }
            progress(.init(sent: offset, total: total))
        }
        progress(.init(sent: total, total: total))
        try finalAcknowledgement(s)
    }

    private func legacy(_ image: FlashImage, _ s: UDPSocket, _ progress: @Sendable (DownloadProgress) -> Void) throws {
        let total = flashKB * 1024
        let data = padded(image, to: total)
        var offset = 0
        while offset < total {
            try Task.checkCancellation()
            let n = min(0x40, total - offset)
            let packet = DownloadPacket.legacy(offset: offset, chunk: data[offset..<(offset + n)])
            for _ in 0..<2 {  // each chunk is sent twice, 100 ms apart
                try s.send(packet, to: host, port: port)
                pause(0.1)
            }
            offset += n
            progress(.init(sent: offset, total: total))
        }
        try finalAcknowledgement(s)
    }

    private func finalAcknowledgement(_ s: UDPSocket) throws {
        pause(0.3)
        var ok = false
        while let (r, _, _) = s.receive(timeout: .milliseconds(1)) {
            if DownloadPacket.replyCode(r) == 0x12 { ok = true }
        }
        guard ok else { throw DownloadError(DownloadMessage.flashWriteFailed) }
        pause(4)
    }

    private func drain(_ s: UDPSocket) {
        while s.receive(timeout: .milliseconds(1)) != nil {}
    }
}

/// Downloads through the device's serial port (`0x44e680`, timer 5).
public struct SerialDownloader: Sendable {
    public var portPath: String
    public var baudRate: Int
    public var kind: DownloadKind

    public init(portPath: String, baudRate: Int = 115_200, kind: DownloadKind) {
        self.portPath = portPath
        self.baudRate = baudRate
        self.kind = kind
    }

    static let sync: [UInt8] = [0xED, 0xF2, 0xA3, 0x56, 0xCA, 0xDB, 0x91, 0x84, 0xB0, 0xD7]
    static let expectedReply: [UInt8] = sync + [0x0F, 0x00, 0x00, 0x41, 0xC3]

    /// The 22-byte start frame: sync, `93 0C 01`, kind (1 web, 2 code), length (BE32),
    /// CRC of the data, CRC of the 10 bytes before it.
    public static func startFrame(length: Int, data: some Sequence<UInt8>, kind: DownloadKind) -> [UInt8] {
        var body: [UInt8] = [0x93, 0x0C, 0x01, kind == .code ? 2 : 1]
        for k in 0..<4 { body.append(UInt8(truncatingIfNeeded: length >> (24 - 8 * k))) }
        body += DownloadCRC.bytes(data)
        body += DownloadCRC.bytes(body)
        return sync + body
    }

    public func run(_ image: FlashImage, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> String {
        let me = self
        return try await Task.detached(priority: .userInitiated) {
            let link = try SerialLink(path: me.portPath, settings: .init(baudRate: me.baudRate))
            let length = image.usedLength
            let data = Array(image.bytes.prefix(length))
            try link.write(Self.startFrame(length: length, data: data, kind: me.kind))
            pause(1)
            let reply = link.read(15, timeout: .seconds(2))
            guard reply == Self.expectedReply else { throw DownloadError(DownloadMessage.serialHandshakeFailed) }
            var offset = 0
            progress(.init(sent: 0, total: length))
            while offset < length {
                try Task.checkCancellation()
                let n = min(0x100, length - offset)
                try link.write(Array(data[offset..<(offset + n)]))
                offset += n
                progress(.init(sent: offset, total: length))
                pause(0.256)
            }
            pause(4)
            return DownloadMessage.complete
        }.value
    }
}

/// Blocking sleep for the download loops, which run on a detached task.
func pause(_ seconds: Double) {
    usleep(UInt32(seconds * 1_000_000))
}
