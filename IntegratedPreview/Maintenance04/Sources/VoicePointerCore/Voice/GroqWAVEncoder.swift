import Foundation

enum GroqWAVEncodingError: Error, Equatable {
    case invalidPCMSize
}

enum GroqWAVEncoder {
    static let minimumPCMByteCount = 320
    static let maximumPCMByteCount = 9_600_000

    static func encode(pcm16Mono16K: Data) throws -> Data {
        let byteCount = pcm16Mono16K.count
        guard byteCount >= minimumPCMByteCount,
              byteCount <= maximumPCMByteCount,
              byteCount % 2 == 0 else {
            throw GroqWAVEncodingError.invalidPCMSize
        }

        var wav = Data(capacity: 44 + byteCount)
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE32(UInt32(36 + byteCount), to: &wav)
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendLE32(16, to: &wav)                          // fmt chunk size
        appendLE16(1, to: &wav)                           // PCM format
        appendLE16(1, to: &wav)                           // channels
        appendLE32(16_000, to: &wav)                      // sample rate
        appendLE32(32_000, to: &wav)                      // byte rate
        appendLE16(2, to: &wav)                           // block align
        appendLE16(16, to: &wav)                           // bits per sample
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendLE32(UInt32(byteCount), to: &wav)
        wav.append(pcm16Mono16K)
        return wav
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
