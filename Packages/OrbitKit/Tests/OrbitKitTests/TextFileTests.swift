import Foundation
import Testing
@testable import OrbitAPI

@Suite struct TextFileTests {
    private func roundTrip(_ data: Data) throws -> (String, TextFileFormat, Data) {
        let (text, format) = try TextFile.decode(data)
        return (text, format, try TextFile.encode(text, as: format))
    }

    @Test func crlfFilesEditWithNewlinesAndSaveBack() throws {
        let data = Data("a\r\nb\r\n".utf8)
        let (text, format, saved) = try roundTrip(data)
        #expect(text == "a\nb\n")
        #expect(format.lineEnding == .crlf)
        #expect(saved == data)
        // A line typed in the editor gets the file's ending too.
        #expect(try TextFile.encode("a\nb\nc\n", as: format) == Data("a\r\nb\r\nc\r\n".utf8))
    }

    @Test func mostlyLFFilesKeepTheirStrayCR() throws {
        let data = Data("a\nb\r\nc\n".utf8)
        let (text, format, saved) = try roundTrip(data)
        #expect(format.lineEnding == .lf)
        #expect(text == "a\nb\r\nc\n")
        #expect(saved == data)
    }

    @Test func byteOrderMarksAndUTF16SurviveASave() throws {
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data("hi\n".utf8)
        let (text, format, saved) = try roundTrip(utf8)
        #expect(text == "hi\n")
        #expect(format.hasBOM && format.encoding == .utf8)
        #expect(saved == utf8)

        let utf16 = Data([0xFF, 0xFE]) + "привет\r\n".data(using: .utf16LittleEndian)!
        let (text16, format16, saved16) = try roundTrip(utf16)
        #expect(text16 == "привет\n")
        #expect(format16.encoding == .utf16LittleEndian && format16.lineEnding == .crlf)
        #expect(saved16 == utf16)
    }

    @Test func legacyEncodingsAreDetected() throws {
        let data = "Привет, мир! Это тест кодировки.\n".data(using: .windowsCP1251)!
        let (text, format, saved) = try roundTrip(data)
        #expect(text == "Привет, мир! Это тест кодировки.\n")
        #expect(format.encoding != .utf8)
        #expect(saved == data)
    }

    @Test func binaryIsRefusedUnlessAnEncodingIsForced() throws {
        let data = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        #expect(throws: TextFile.ReadError.binary) { try TextFile.decode(data) }
        let utf16 = "ab".data(using: .utf16LittleEndian)!
        #expect(try TextFile.decode(utf16, as: .utf16LittleEndian).text == "ab")
    }

    @Test func charactersTheEncodingCantStoreFailTheSave() {
        let format = TextFileFormat(encoding: .windowsCP1251)
        #expect(throws: (any Error).self) { try TextFile.encode("emoji 🙂", as: format) }
    }
}
