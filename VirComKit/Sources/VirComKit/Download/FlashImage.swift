public import Foundation

/// The device models listed in VirCom's "ZLAN webpage & code download tool". The model picks the
/// transfer protocol: only the 2003 and 7004 families take firmware ("code") downloads and use the
/// sequenced, CRC-checked protocol.
public enum DownloadModel: Int, CaseIterable, Codable, Sendable, Identifiable {
    case zlsn2030 = 0
    case zlsn2003 = 1
    case zlsn7004 = 2

    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .zlsn2030: "2030/2032EX"
        case .zlsn2003: "2003"
        case .zlsn7004: "7004"
        }
    }
    public var supportsCodeDownload: Bool { self != .zlsn2030 }
}

public enum DownloadKind: Int, Codable, Sendable {
    /// A directory of web pages and configuration files, packed into the web flash area.
    case webpage = 0
    /// A firmware file sent as is.
    case code = 1
}

public struct DownloadError: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A packed image ready to send, plus how much of it is used.
public struct FlashImage: Sendable, Equatable {
    /// The whole buffer: `flashKB` × 1024 bytes for web pages (zero filled), or the file for code.
    public var bytes: [UInt8]
    /// Bytes actually filled.
    public var usedLength: Int

    public init(bytes: [UInt8], usedLength: Int) {
        self.bytes = bytes
        self.usedLength = usedLength
    }
}

/// Packs a web page directory the way VirCom does (`0x44d3f0`, `0x44d0b0`).
///
/// Each file becomes one record, in directory-walk order:
///
///     FA F3 [EA D3]   magic; the second pair is present for flash sizes above 7 KB
///     "/dir/name.htm" path relative to the directory, '/' separators, NUL terminated
///     length          2 bytes little-endian (7 KB flash) or 4 bytes big-endian
///     data
///
/// With `compressHTML`, tabs, CR, LF and spaces at the start of a line are removed from
/// `.htm`/`.html` files.
public enum FlashImageBuilder {
    /// Flash sizes offered by VirCom, in KB. The default is 2048.
    public static let flashSizesKB = [7, 128, 256, 384, 512, 2048]

    public static func build(directory: URL, flashKB: Int, compressHTML: Bool) throws -> FlashImage {
        let capacity = flashKB * 1024
        let large = flashKB > 7
        var image = [UInt8](repeating: 0, count: capacity)
        var used = 0
        for file in try files(in: directory) {
            var data = [UInt8](try Data(contentsOf: file.url))
            if compressHTML, isHTML(file.relativePath) { data = compress(data) }
            let magic: [UInt8] = large ? [0xFA, 0xF3, 0xEA, 0xD3] : [0xFA, 0xF3]
            var record = magic
            let path = Array(file.relativePath.utf8)
            guard path.count < 0x100 else {
                throw DownloadError("File and folder names together are longer than 256 bytes: \(file.relativePath)")
            }
            record += path + [0]
            let n = data.count
            if large {
                record += [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                           UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            } else {
                record += [UInt8(truncatingIfNeeded: n), UInt8(truncatingIfNeeded: n >> 8)]
            }
            record += data
            // VirCom's check: magic + data + used + 256 + magic must fit.
            guard magic.count * 2 + n + used + 0x100 <= capacity else {
                throw DownloadError("Total webpage size exceeds the flash size, please reduce the total webpage size.")
            }
            image.replaceSubrange(used..<(used + record.count), with: record)
            used += record.count
        }
        return FlashImage(bytes: image, usedLength: used)
    }

    /// A firmware file for a code download. It must fit in `flashKB`.
    public static func code(file: URL, flashKB: Int) throws -> FlashImage {
        let data = [UInt8](try Data(contentsOf: file))
        guard data.count <= flashKB * 1024 else {
            throw DownloadError("The file size is larger than the maximum size allowed.")
        }
        return FlashImage(bytes: data, usedLength: data.count)
    }

    struct Entry {
        var url: URL
        var relativePath: String
    }

    /// Files in walk order: entries sorted like an NTFS directory listing (case-insensitive),
    /// with subdirectories walked where they appear.
    static func files(in root: URL) throws -> [Entry] {
        var result: [Entry] = []
        func walk(_ dir: URL, prefix: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0 != ".DS_Store" }
                .sorted { $0.uppercased() < $1.uppercased() }
            for name in names {
                let url = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    try walk(url, prefix: prefix + "/" + name)
                } else {
                    result.append(Entry(url: url, relativePath: prefix + "/" + name))
                }
            }
        }
        try walk(root, prefix: "")
        return result
    }

    /// VirCom looks for "htm" (which also matches "html") after the first dot, case-sensitively.
    static func isHTML(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.firstIndex(of: ".") else { return false }
        return name[dot...].contains("htm")
    }

    static func compress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var lineStart = true
        for b in data {
            switch b {
            case 0x09: continue
            case 0x0D, 0x0A: lineStart = true; continue
            case 0x20 where lineStart: continue
            default: lineStart = false; out.append(b)
            }
        }
        return out
    }
}

/// The CRC VirCom's download code uses (`0x44d6e0`): the Modbus table CRC returned with its
/// bytes swapped, i.e. `hi` is the first byte on the wire.
public enum DownloadCRC {
    public static func value(_ bytes: some Sequence<UInt8>, initial: UInt16 = 0xFFFF) -> UInt16 {
        // The table code keeps hi/lo separately, so its value is the reflected CRC-16 byte-swapped.
        var crc = initial.byteSwapped
        for b in bytes {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc.byteSwapped
    }

    /// The two bytes in wire order.
    public static func bytes(_ data: some Sequence<UInt8>, initial: UInt16 = 0xFFFF) -> [UInt8] {
        let v = value(data, initial: initial)
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
}
