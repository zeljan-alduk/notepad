import Foundation

/// A text encoding we can read and write. Internally the editor always works in
/// UTF-8 (so the byte/line engine and the huge-file mmap path stay simple);
/// non-UTF-8 files are transcoded to UTF-8 on open and back on save.
enum FileEncoding: String, CaseIterable {
    case utf8, utf8BOM, utf16LE, utf16BE, ansi

    var label: String {
        switch self {
        case .utf8:    return "UTF-8"
        case .utf8BOM: return "UTF-8 with BOM"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .ansi:    return "ANSI"
        }
    }

    /// Menu/title for the Save As encoding picker.
    var menuTitle: String { label }

    /// True for encodings whose bytes aren't UTF-8 and must be transcoded.
    var needsTranscode: Bool {
        self == .utf16LE || self == .utf16BE || self == .ansi
    }

    /// Encodes a UTF-8 string into this encoding's bytes (with BOM where applicable).
    func encode(_ s: String) -> Data {
        switch self {
        case .utf8:    return Data(s.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF]) + Data(s.utf8)
        case .utf16LE: return Data([0xFF, 0xFE]) + (s.data(using: .utf16LittleEndian) ?? Data())
        case .utf16BE: return Data([0xFE, 0xFF]) + (s.data(using: .utf16BigEndian) ?? Data())
        case .ansi:    return s.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(s.utf8)
        }
    }
}

struct LineEndingInfo {
    var newline: String   // inserted on Return
    var label: String     // status-bar text
    static let crlf = LineEndingInfo(newline: "\r\n", label: "Windows (CRLF)")
}

/// A file prepared for editing: a UTF-8 byte source (the original mmap, or a
/// transcoded temp file), its detected encoding, the first editable byte, and a
/// temp URL to clean up when the document closes.
struct OpenedFile {
    let mapped: MappedFile
    let encoding: FileEncoding
    let contentStart: Int     // past any BOM in the UTF-8 source
    let tempURL: URL?
}

/// mmaps `url`, detects its encoding, and (for non-UTF-8) transcodes it to a
/// temp UTF-8 file that is mmapped instead. UTF-8/ASCII keep the zero-copy path.
func prepareForReading(_ url: URL) -> OpenedFile? {
    guard let raw = MappedFile(url: url) else { return nil }
    let encoding = detectEncoding(raw)

    if encoding.needsTranscode {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoded: String?
        switch encoding {
        case .utf16LE, .utf16BE: decoded = String(data: data, encoding: .utf16)  // BOM picks endianness
        case .ansi:              decoded = String(data: data, encoding: .windowsCP1252)
        default:                 decoded = nil
        }
        guard let text = decoded else { return nil }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("notepad-\(getpid())-\(abs(url.hashValue)).utf8")
        guard (try? Data(text.utf8).write(to: tmp)) != nil,
              let utf8Mapped = MappedFile(url: tmp) else { return nil }
        return OpenedFile(mapped: utf8Mapped, encoding: encoding, contentStart: 0, tempURL: tmp)
    }

    let contentStart = (encoding == .utf8BOM) ? 3 : 0
    return OpenedFile(mapped: raw, encoding: encoding, contentStart: contentStart, tempURL: nil)
}

/// NUL bytes in the head mean this isn't text in any encoding we edit as text
/// (UTF-16 announces itself with a BOM, checked first), so it opens in the hex
/// editor instead of being mangled through the ANSI path.
func looksBinary(_ file: MappedFile) -> Bool {
    let n = file.count
    guard n > 0 else { return false }
    if n >= 2, file.byte(at: 0) == 0xFF, file.byte(at: 1) == 0xFE { return false }
    if n >= 2, file.byte(at: 0) == 0xFE, file.byte(at: 1) == 0xFF { return false }
    let sampleLen = min(n, 1 << 16)
    return memchr(file.rawBase, 0x00, sampleLen) != nil
}

/// BOM sniffing, then a UTF-8 validity check on a 64 KB sample (invalid ⇒ ANSI).
func detectEncoding(_ file: MappedFile) -> FileEncoding {
    let n = file.count
    guard n > 0 else { return .utf8 }

    if n >= 3, file.byte(at: 0) == 0xEF, file.byte(at: 1) == 0xBB, file.byte(at: 2) == 0xBF { return .utf8BOM }
    if n >= 2, file.byte(at: 0) == 0xFF, file.byte(at: 1) == 0xFE { return .utf16LE }
    if n >= 2, file.byte(at: 0) == 0xFE, file.byte(at: 1) == 0xFF { return .utf16BE }

    // No BOM: if a sample isn't valid UTF-8, treat it as legacy ANSI (CP-1252).
    let sampleLen = min(n, 1 << 16)
    let buf = UnsafeRawBufferPointer(start: file.rawBase, count: sampleLen)
    if String(bytes: buf, encoding: .utf8) == nil { return .ansi }
    return .utf8
}

/// Line ending from the first one in a 64 KB sample of the UTF-8 content.
func detectLineEnding(_ file: MappedFile, from start: Int) -> LineEndingInfo {
    let n = file.count
    let sampleEnd = min(n, start + (1 << 16))
    var i = start
    while i < sampleEnd {
        let b = file.byte(at: i)
        if b == 0x0A { return LineEndingInfo(newline: "\n", label: "Unix (LF)") }
        if b == 0x0D {
            if i + 1 < n, file.byte(at: i + 1) == 0x0A { return .crlf }
            return LineEndingInfo(newline: "\r", label: "Macintosh (CR)")
        }
        i += 1
    }
    return .crlf   // default for new/empty/no-newline files, like FlashPad
}
