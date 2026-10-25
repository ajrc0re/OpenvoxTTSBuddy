import Foundation

struct PCMFormat: Equatable {
    var sampleRate: Double
    var channels: Int
    var bitsPerSample: Int
    var isFloat: Bool

    var bytesPerFrame: Int { max(1, channels * bitsPerSample / 8) }

    /// Used when a stream chunk arrives without a WAV header before any header
    /// was seen. Kokoro and most OpenVox models output 24 kHz mono 16-bit.
    static let fallback = PCMFormat(sampleRate: 24_000, channels: 1, bitsPerSample: 16, isFloat: false)
}

enum WAV {
    /// Splits a RIFF/WAVE blob into its format and PCM payload.
    /// Returns nil when the data doesn't start with a WAV header.
    static func parse(_ data: Data) -> (format: PCMFormat, pcm: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<12].elementsEqual("WAVE".utf8) else { return nil }

        var format: PCMFormat?
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = Int(readUInt32(bytes, offset + 4))
            let start = offset + 8
            if id == "fmt ", start + 16 <= bytes.count {
                var tag = readUInt16(bytes, start)
                let channels = Int(readUInt16(bytes, start + 2))
                let sampleRate = Double(readUInt32(bytes, start + 4))
                let bits = Int(readUInt16(bytes, start + 14))
                if tag == 0xFFFE, start + 26 <= bytes.count {
                    // WAVE_FORMAT_EXTENSIBLE: real format is the first two bytes of the sub-format GUID.
                    tag = readUInt16(bytes, start + 24)
                }
                format = PCMFormat(sampleRate: sampleRate, channels: max(1, channels), bitsPerSample: bits, isFloat: tag == 3)
            } else if id == "data" {
                // Streaming encoders often write 0 or 0xFFFFFFFF as the data size.
                let end = (size == 0 || size == 0xFFFF_FFFF) ? bytes.count : min(bytes.count, start + size)
                guard let format else { return nil }
                return (format, Data(bytes[min(start, bytes.count)..<end]))
            }
            offset = start + size + (size & 1)
            if size == 0xFFFF_FFFF { break }
        }
        return nil
    }

    private static func readUInt16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func readUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    /// Wraps raw PCM in a WAV header (used to save streamed audio).
    static func file(format: PCMFormat, pcm: Data) -> Data {
        var out = Data()
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        let byteRate = UInt32(format.sampleRate) * UInt32(format.bytesPerFrame)
        out.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + pcm.count))
        out.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(format.isFloat ? 3 : 1)
        append16(UInt16(format.channels))
        append32(UInt32(format.sampleRate))
        append32(byteRate)
        append16(UInt16(format.bytesPerFrame))
        append16(UInt16(format.bitsPerSample))
        out.append(contentsOf: "data".utf8)
        append32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}
