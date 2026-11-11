import Foundation

// MARK: - Minimal ZIP writer (pure, no dependencies)
//
// Enough of PKWARE APPNOTE 6.3 for EPUB: local headers, a central directory,
// STORED or DEFLATE entries (DEFLATE via Foundation's raw-deflate `.zlib`
// algorithm), UTF-8 names. No ZIP64: an export over 4 GB fails loudly
// instead of writing a corrupt file.

public enum EPUBZipError: Error, Equatable, LocalizedError {
    case tooLarge
    case duplicateName(String)
    case unsafeName(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The book is too large to save (over 4 GB)."
        case .duplicateName(let n): return "Two files in the book share the name “\(n)”."
        case .unsafeName(let n): return "“\(n)” isn't a safe file name inside a book."
        }
    }
}

public enum EPUBCRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

public struct EPUBZipWriter {
    public enum Method: UInt16, Sendable { case stored = 0, deflate = 8 }

    struct Record {
        let name: [UInt8]
        let method: UInt16
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private(set) public var data = Data()
    private var records: [Record] = []
    private var names = Set<String>()
    /// MS-DOS timestamp written on every entry (fixed → reproducible output).
    let dosTime: UInt16
    let dosDate: UInt16

    public init(modified: Date = Date(timeIntervalSince1970: 1_577_836_800), calendar: Calendar = Calendar(identifier: .gregorian)) {
        var cal = calendar
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: modified)
        let year = max(1980, min(2107, c.year ?? 2020))
        dosDate = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        dosTime = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
    }

    /// Relative, forward-slash names only (no `..`, no leading `/`).
    static func isSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    public mutating func add(_ name: String, _ content: Data, method: Method = .deflate) throws {
        guard Self.isSafe(name) else { throw EPUBZipError.unsafeName(name) }
        guard names.insert(name).inserted else { throw EPUBZipError.duplicateName(name) }
        var payload = content
        var m = method
        if method == .deflate {
            if let packed = try? (content as NSData).compressed(using: .zlib) as Data, packed.count < content.count {
                payload = packed
            } else {
                m = .stored
            }
        }
        guard content.count < Int(UInt32.max), payload.count < Int(UInt32.max),
              data.count + payload.count + 30 + name.utf8.count < Int(UInt32.max) else { throw EPUBZipError.tooLarge }
        let nameBytes = Array(name.utf8)
        let rec = Record(name: nameBytes, method: m.rawValue, crc: EPUBCRC32.checksum(content),
                         compressedSize: UInt32(payload.count), size: UInt32(content.count), offset: UInt32(data.count))
        data.appendLE(UInt32(0x0403_4B50))
        data.appendLE(UInt16(20))            // version needed
        data.appendLE(UInt16(0x0800))        // flags: UTF-8 names
        data.appendLE(rec.method)
        data.appendLE(dosTime)
        data.appendLE(dosDate)
        data.appendLE(rec.crc)
        data.appendLE(rec.compressedSize)
        data.appendLE(rec.size)
        data.appendLE(UInt16(nameBytes.count))
        data.appendLE(UInt16(0))             // no extra field (EPUB requires none on `mimetype`)
        data.append(contentsOf: nameBytes)
        data.append(payload)
        records.append(rec)
    }

    public mutating func add(_ name: String, text: String, method: Method = .deflate) throws {
        try add(name, Data(text.utf8), method: method)
    }

    /// Appends the central directory and returns the finished archive.
    public mutating func finish() throws -> Data {
        let cdStart = data.count
        for r in records {
            data.appendLE(UInt32(0x0201_4B50))
            data.appendLE(UInt16(0x031E))    // made by: Unix, spec 3.0
            data.appendLE(UInt16(20))
            data.appendLE(UInt16(0x0800))
            data.appendLE(r.method)
            data.appendLE(dosTime)
            data.appendLE(dosDate)
            data.appendLE(r.crc)
            data.appendLE(r.compressedSize)
            data.appendLE(r.size)
            data.appendLE(UInt16(r.name.count))
            data.appendLE(UInt16(0))         // extra
            data.appendLE(UInt16(0))         // comment
            data.appendLE(UInt16(0))         // disk
            data.appendLE(UInt16(0))         // internal attrs
            data.appendLE(UInt32(0o100644) << 16) // external attrs: regular file rw-r--r--
            data.appendLE(r.offset)
            data.append(contentsOf: r.name)
        }
        let cdSize = data.count - cdStart
        guard records.count < 0xFFFF, data.count < Int(UInt32.max) else { throw EPUBZipError.tooLarge }
        data.appendLE(UInt32(0x0605_4B50))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(records.count))
        data.appendLE(UInt16(records.count))
        data.appendLE(UInt32(cdSize))
        data.appendLE(UInt32(cdStart))
        data.appendLE(UInt16(0))
        return data
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
