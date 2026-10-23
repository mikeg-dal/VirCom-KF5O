public import Foundation
import Darwin

public enum SerialParity: Int, CaseIterable, Codable, Sendable, Identifiable {
    case none = 0, odd = 1, even = 2
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .none: "None"
        case .odd: "Odd"
        case .even: "Even"
        }
    }
}

public struct SerialLinkSettings: Codable, Sendable, Equatable {
    public var baudRate: Int
    public var dataBits: Int
    public var parity: SerialParity
    public var twoStopBits: Bool

    public init(baudRate: Int = 115_200, dataBits: Int = 8, parity: SerialParity = .none, twoStopBits: Bool = false) {
        self.baudRate = baudRate
        self.dataBits = dataBits
        self.parity = parity
        self.twoStopBits = twoStopBits
    }
}

/// A small blocking serial port for the download, serial-search and 4G tools. Call it from a
/// background task; every read takes a timeout.
public final class SerialLink: @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let lock = NSLock()

    /// `/dev/cu.*` devices, sorted. Bluetooth and debug consoles are left out.
    public static func availablePorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && $0 != "cu.debug-console" }
            .sorted()
            .map { "/dev/" + $0 }
    }

    public init(path: String, settings: SerialLinkSettings) throws {
        self.path = path
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw DownloadError("Unable to open \(path): \(String(cString: strerror(errno)))") }
        self.fd = fd
        do {
            try Self.configure(fd, settings)
        } catch {
            Darwin.close(fd)
            throw error
        }
        tcflush(fd, TCIOFLUSH)
    }

    deinit { Darwin.close(fd) }

    private static func configure(_ fd: Int32, _ s: SerialLinkSettings) throws {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw DownloadError("Unable to read the port settings.") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CCTS_OFLOW | CRTS_IFLOW)
        let size: Int32 = switch s.dataBits { case 5: CS5; case 6: CS6; case 7: CS7; default: CS8 }
        t.c_cflag |= tcflag_t(size)
        switch s.parity {
        case .none: break
        case .odd: t.c_cflag |= tcflag_t(PARENB | PARODD)
        case .even: t.c_cflag |= tcflag_t(PARENB)
        }
        if s.twoStopBits { t.c_cflag |= tcflag_t(CSTOPB) }
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        let standard = [300, 600, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115_200, 230_400].contains(s.baudRate)
        cfsetspeed(&t, speed_t(standard ? s.baudRate : 9600))
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { throw DownloadError("Unable to apply the port settings.") }
        if !standard {
            var speed = speed_t(s.baudRate)
            // IOSSIOSPEED = _IOW('T', 2, speed_t)
            guard ioctl(fd, 0x8008_5402, &speed) == 0 else {
                throw DownloadError("This port does not support \(s.baudRate) bps.")
            }
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        try DeviceWriteGuard.check("Serial write to \(path)")
        lock.lock(); defer { lock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                offset += n
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 1000)
            } else {
                throw DownloadError("Writing to \(path) failed: \(String(cString: strerror(errno)))")
            }
        }
        tcdrain(fd)
    }

    /// Reads until `count` bytes arrive or `timeout` passes, and returns what arrived.
    public func read(_ count: Int, timeout: Duration) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 4096)
        while out.count < count {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { break }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(1, left.milliseconds))) > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, count - out.count)) }
            if n > 0 { out += buffer[..<n] } else if n == 0 { break }
        }
        return out
    }

    /// Reads whatever arrives until the line has been quiet for `idle`, or `timeout` passes.
    public func readAvailable(timeout: Duration, idle: Duration = .milliseconds(100)) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = ContinuousClock.now + timeout
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = out.isEmpty ? (deadline - ContinuousClock.now) : idle
            guard poll(&p, 1, Int32(max(1, wait.milliseconds))) > 0 else {
                if out.isEmpty { continue } else { break }
            }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { out += buffer[..<n] } else { break }
        }
        return out
    }

    public func flushInput() { tcflush(fd, TCIFLUSH) }
}

extension Duration {
    var milliseconds: Int {
        Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}
