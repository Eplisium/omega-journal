import Foundation

// MARK: - ZIP reader for "AppleJournalEntries.zip" (pure)
//
// Apple's own instructions end with "Compress" in Finder, so imports accept
// the .zip directly. Reads the central directory (ZIP64 included), STORED and
// DEFLATE entries, and refuses encrypted entries. Entries are inflated only
// when asked for, so a large export with videos is never held in memory at once
// (map the file with `Data(contentsOf:options:.alwaysMapped)`).

public enum AppleJournalZipError: Error, Equatable {
    case notAZip
    case unsupported(String)
    case corrupt(String)
    case tooLarge(String)
}

public struct AppleJournalZipReader {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let method: UInt16
        public let flags: UInt16
        public let crc32: UInt32
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
        public var isDirectory: Bool { name.hasSuffix("/") }
        public var isEncrypted: Bool { flags & 1 != 0 }
    }

    public let data: Data
    public let entries: [Entry]
    /// Largest single entry this reader will inflate (default 2 GB).
    public var maxEntrySize: UInt64 = 2 << 30

    public init(data: Data) throws {
        self.data = data
        self.entries = try Self.readCentralDirectory(data)
    }

    /// Normalised name → entry (later duplicates lose). Skips Finder's
    /// `__MACOSX/` resource forks and `._*` AppleDouble files.
    public var filesByName: [String: Entry] {
        var out: [String: Entry] = [:]
        for e in entries where !e.isDirectory && !Self.isFinderJunk(e.name) {
            let key = Self.normalize(e.name)
            if out[key] == nil { out[key] = e }
        }
        return out
    }

    public static func isFinderJunk(_ name: String) -> Bool {
        name.hasPrefix("__MACOSX/") || (name as NSString).lastPathComponent.hasPrefix("._")
            || (name as NSString).lastPathComponent == ".DS_Store"
    }

    /// Resolves `.`/`..` and leading slashes; a name that climbs out of the
    /// archive root resolves to "" (never matched).
    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for p in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if p == "." || p.isEmpty { continue }
            if p == ".." { if parts.isEmpty { return "" }; parts.removeLast(); continue }
            parts.append(p)
        }
        return parts.joined(separator: "/")
    }

    public func contents(of entry: Entry) throws -> Data {
        guard !entry.isEncrypted else { throw AppleJournalZipError.unsupported("encrypted entry \(entry.name)") }
        guard entry.uncompressedSize <= maxEntrySize else { throw AppleJournalZipError.tooLarge(entry.name) }
        let off = Int(entry.localHeaderOffset)
        guard off + 30 <= data.count, data.u32(at: off) == 0x0403_4B50 else { throw AppleJournalZipError.corrupt("local header \(entry.name)") }
        let nameLen = Int(data.u16(at: off + 26)), extraLen = Int(data.u16(at: off + 28))
        let start = off + 30 + nameLen + extraLen
        guard entry.compressedSize <= UInt64(Int.max), start + Int(entry.compressedSize) <= data.count else {
            throw AppleJournalZipError.corrupt("truncated \(entry.name)")
        }
        let raw = data.subdata(in: start..<(start + Int(entry.compressedSize)))
        let out: Data
        switch entry.method {
        case 0: out = raw
        case 8:
            if entry.uncompressedSize == 0 { out = Data(); break }
            guard let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data else {
                throw AppleJournalZipError.corrupt("inflate \(entry.name)")
            }
            out = inflated
        default:
            throw AppleJournalZipError.unsupported("compression method \(entry.method)")
        }
        guard UInt64(out.count) == entry.uncompressedSize else { throw AppleJournalZipError.corrupt("size \(entry.name)") }
        guard EPUBCRC32.checksum(out) == entry.crc32 else { throw AppleJournalZipError.corrupt("checksum \(entry.name)") }
        return out
    }

    static func readCentralDirectory(_ d: Data) throws -> [Entry] {
        guard d.count >= 22 else { throw AppleJournalZipError.notAZip }
        // End of central directory: scan back over a possible comment (≤ 64 KB).
        var eocd = -1
        var p = d.count - 22
        let floor = max(0, d.count - 22 - 0xFFFF)
        while p >= floor {
            if d.u32(at: p) == 0x0605_4B50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw AppleJournalZipError.notAZip }
        var count = UInt64(d.u16(at: eocd + 10))
        var cdSize = UInt64(d.u32(at: eocd + 12))
        var cdOffset = UInt64(d.u32(at: eocd + 16))
        // ZIP64 locator sits right before the classic record.
        if eocd >= 20, d.u32(at: eocd - 20) == 0x0706_4B50 {
            let z64 = Int(clamping: d.u64(at: eocd - 12))
            guard z64 >= 0, z64 + 56 <= d.count, d.u32(at: z64) == 0x0606_4B50 else { throw AppleJournalZipError.corrupt("zip64 record") }
            count = d.u64(at: z64 + 32)
            cdSize = d.u64(at: z64 + 40)
            cdOffset = d.u64(at: z64 + 48)
        }
        guard cdOffset + cdSize <= UInt64(d.count), count < 1_000_000 else { throw AppleJournalZipError.corrupt("central directory") }
        var entries: [Entry] = []
        var q = Int(cdOffset)
        for _ in 0..<count {
            guard q + 46 <= d.count, d.u32(at: q) == 0x0201_4B50 else { throw AppleJournalZipError.corrupt("directory entry") }
            let flags = d.u16(at: q + 8)
            let method = d.u16(at: q + 10)
            let crc = d.u32(at: q + 16)
            var csize = UInt64(d.u32(at: q + 20))
            var usize = UInt64(d.u32(at: q + 24))
            let nameLen = Int(d.u16(at: q + 28)), extraLen = Int(d.u16(at: q + 30)), commentLen = Int(d.u16(at: q + 32))
            var offset = UInt64(d.u32(at: q + 42))
            guard q + 46 + nameLen + extraLen + commentLen <= d.count else { throw AppleJournalZipError.corrupt("directory entry") }
            let nameData = d.subdata(in: (q + 46)..<(q + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            // ZIP64 extended info (0x0001): only the fields saturated in the record follow.
            var x = q + 46 + nameLen
            let xEnd = x + extraLen
            while x + 4 <= xEnd {
                let id = d.u16(at: x), len = Int(d.u16(at: x + 2))
                if id == 0x0001 {
                    var f = x + 4
                    if usize == 0xFFFF_FFFF, f + 8 <= x + 4 + len { usize = d.u64(at: f); f += 8 }
                    if csize == 0xFFFF_FFFF, f + 8 <= x + 4 + len { csize = d.u64(at: f); f += 8 }
                    if offset == 0xFFFF_FFFF, f + 8 <= x + 4 + len { offset = d.u64(at: f) }
                }
                x += 4 + len
            }
            entries.append(Entry(name: name, method: method, flags: flags, crc32: crc, compressedSize: csize,
                                 uncompressedSize: usize, localHeaderOffset: offset))
            q += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }
}

extension Data {
    func u16(at i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= count else { return 0 }
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func u32(at i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= count else { return 0 }
        return UInt32(u16(at: i)) | UInt32(u16(at: i + 2)) << 16
    }
    func u64(at i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= count else { return 0 }
        return UInt64(u32(at: i)) | UInt64(u32(at: i + 4)) << 32
    }
}
