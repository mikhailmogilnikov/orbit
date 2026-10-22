import Foundation

/// How a text file is stored on disk. Inside Orbit text is always a Swift
/// string with `\n` line breaks; the encoding, byte-order mark and line
/// endings come back on save, so opening and saving changes nothing else.
public struct TextFileFormat: Sendable, Equatable {
    public enum LineEnding: String, Sendable, CaseIterable {
        case lf = "LF", crlf = "CRLF", cr = "CR"

        public var characters: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    public var encoding: String.Encoding
    public var hasBOM: Bool
    public var lineEnding: LineEnding

    public init(encoding: String.Encoding = .utf8, hasBOM: Bool = false, lineEnding: LineEnding = .lf) {
        self.encoding = encoding
        self.hasBOM = hasBOM
        self.lineEnding = lineEnding
    }

    public static let `default` = TextFileFormat()

    public var isDefault: Bool { self == .default }

    /// "UTF-8", "Windows-1251"…
    public var encodingName: String {
        let name = TextFile.encodings.first { $0.encoding == encoding }?.name
            ?? String.localizedName(of: encoding)
        return hasBOM ? "\(name) with BOM" : name
    }
}

public enum TextFile {
    /// Bigger files aren't opened in the editor: TextKit and highlighting would crawl.
    public static let maxEditableSize = 50 << 20

    public enum ReadError: Error, Equatable {
        case binary, tooLarge(Int), undecodable
    }

    /// Encodings offered for reopening or saving, Unicode first.
    public static let encodings: [(name: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16 LE", .utf16LittleEndian),
        ("UTF-16 BE", .utf16BigEndian),
        ("Windows-1251 (Cyrillic)", .windowsCP1251),
    ] + koi8R + [
        ("Windows-1252 (Western)", .windowsCP1252),
        ("ISO Latin 1", .isoLatin1),
        ("Mac Roman", .macOSRoman),
        ("Shift JIS", .shiftJIS),
    ]

    // CoreFoundation's encodings and Foundation's detector are Darwin-only; the
    // Linux build (D55) only needs line endings.
    #if canImport(Darwin)
    private static let koi8R = [("KOI8-R", String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.KOI8_R.rawValue))))]
    #else
    private static let koi8R: [(name: String, encoding: String.Encoding)] = []
    #endif

    private static let boms: [(bytes: [UInt8], encoding: String.Encoding)] = [
        ([0xEF, 0xBB, 0xBF], .utf8),
        ([0xFF, 0xFE], .utf16LittleEndian),
        ([0xFE, 0xFF], .utf16BigEndian),
    ]

    public static func read(_ url: URL) throws -> (text: String, format: TextFileFormat) {
        // A symlink's own size is its target's path.
        let size = (try? (url.symlinkTarget ?? url).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxEditableSize { throw ReadError.tooLarge(size) }
        return try decode(Data(contentsOf: url))
    }

    /// Writes through a symlink: an atomic write would replace the link with a plain file.
    public static func write(_ data: Data, to url: URL) throws {
        let target = url.symlinkTarget ?? url
        // Links pointing at each other end on a link: written over, it'd turn into a file.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(.ELOOP)])
        }
        try data.write(to: target, options: .atomic)
    }

    /// The file's format, or nil when it doesn't exist or isn't text.
    public static func format(of url: URL) -> TextFileFormat? {
        try? read(url).format
    }

    /// BOM, else strict UTF-8, else what Foundation's detector finds; bytes with
    /// NULs and no BOM are binary.
    public static func decode(_ data: Data, as forced: String.Encoding? = nil) throws -> (text: String, format: TextFileFormat) {
        let bytes = [UInt8](data.prefix(4))
        let bom = boms.first { bytes.starts(with: $0.bytes) }
        let encoding: String.Encoding
        var body = data
        if let bom, forced == nil || forced == bom.encoding {
            encoding = bom.encoding
            body = data.dropFirst(bom.bytes.count)
        } else if let forced {
            encoding = forced
        } else if data.prefix(8000).contains(0) {
            throw ReadError.binary
        } else if String(data: data, encoding: .utf8) != nil {
            encoding = .utf8
        } else {
            #if canImport(Darwin)
            var converted: NSString?
            var lossy = ObjCBool(false)
            let detected = NSString.stringEncoding(
                for: data,
                encodingOptions: [
                    .suggestedEncodingsKey: encodings.dropFirst(3).map { $0.encoding.rawValue },
                    .allowLossyKey: false,
                ],
                convertedString: &converted, usedLossyConversion: &lossy
            )
            guard detected != 0 else { throw ReadError.undecodable }
            encoding = String.Encoding(rawValue: detected)
            #else
            throw ReadError.undecodable
            #endif
        }
        guard let raw = String(data: body, encoding: encoding) else { throw ReadError.undecodable }
        let ending = lineEnding(of: raw)
        return (normalized(raw, from: ending), TextFileFormat(encoding: encoding, hasBOM: bom != nil && body.count != data.count, lineEnding: ending))
    }

    public static func encode(_ text: String, as format: TextFileFormat) throws -> Data {
        var stored = normalized(text, from: lineEnding(of: text))
        if format.lineEnding != .lf { stored = stored.replacingOccurrences(of: "\n", with: format.lineEnding.characters) }
        guard var data = stored.data(using: format.encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [
                NSLocalizedDescriptionKey: "The text has characters \(format.encodingName) can't store. Save it as UTF-8 instead.",
            ])
        }
        // Foundation adds its own BOM for plain `.utf16`; the explicit-endian ones don't.
        if format.hasBOM, let bom = boms.first(where: { $0.encoding == format.encoding }) { data = Data(bom.bytes) + data }
        return data
    }

    /// The file's line ending: whichever there are most of (LF when there are none).
    public static func lineEnding(of text: String) -> TextFileFormat.LineEnding {
        var crlf = 0, lf = 0, cr = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 10 {
                if previous == 13 { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if unit == 13 {
                cr += 1
            }
            previous = unit
        }
        if crlf > lf, crlf >= cr { return .crlf }
        if cr > lf, cr > crlf { return .cr }
        return .lf
    }

    /// Text with the given line endings as `\n`; other endings are left alone.
    public static func normalized(_ text: String, from ending: TextFileFormat.LineEnding) -> String {
        ending == .lf ? text : text.replacingOccurrences(of: ending.characters, with: "\n")
    }

    /// For text read some other way (git, a copy): `\n` line breaks if it's CRLF or CR text.
    public static func normalized(_ text: String) -> String {
        normalized(text, from: lineEnding(of: text))
    }

    public static func message(for error: Error) -> String {
        switch error as? ReadError {
        case .binary: "This file is binary, not text."
        case .tooLarge(let size): "This file is too large to edit (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))."
        case .undecodable: "This file's text encoding isn't recognized."
        case nil: error.localizedDescription
        }
    }
}
