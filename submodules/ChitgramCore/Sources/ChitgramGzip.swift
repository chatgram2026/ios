import Foundation

/// gzip as Java's `GZIPOutputStream` writes it, so iOS and Android read each other's cloud copies (Android
/// `SavedCloud.pack`: text → gzip → Base64). Deflate itself is Foundation's (`NSData.compressed(using: .zlib)`,
/// which is raw RFC 1951 data); the gzip header and trailer are added here.
public enum ChitgramGzip {
    private static let crcTable: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0 ..< 8 {
            value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = self.crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    /// Text → gzip → Base64 (no line breaks).
    public static func pack(_ text: String) -> String? {
        let input = Data(text.utf8)
        guard let deflated = try? (input as NSData).compressed(using: .zlib) as Data else {
            return nil
        }
        var output = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF])
        output.append(deflated)
        output.append(contentsOf: self.littleEndian(self.crc32(input)))
        output.append(contentsOf: self.littleEndian(UInt32(truncatingIfNeeded: input.count)))
        return output.base64EncodedString()
    }

    /// The reverse of `pack`; nil when the data is damaged.
    public static func unpack(_ base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count >= 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return nil
        }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var offset = 10
        if (flags & 0x04) != 0 {
            // FEXTRA
            guard offset + 2 <= bytes.count else {
                return nil
            }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        if (flags & 0x08) != 0 {
            // FNAME, zero-terminated
            while offset < bytes.count && bytes[offset] != 0 {
                offset += 1
            }
            offset += 1
        }
        if (flags & 0x10) != 0 {
            // FCOMMENT, zero-terminated
            while offset < bytes.count && bytes[offset] != 0 {
                offset += 1
            }
            offset += 1
        }
        if (flags & 0x02) != 0 {
            // FHCRC
            offset += 2
        }
        guard offset < bytes.count - 8 else {
            return nil
        }
        let deflated = Data(bytes[offset ..< bytes.count - 8])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else {
            return nil
        }
        return String(data: inflated, encoding: .utf8)
    }
}
