import Foundation
import NamecardCore

/// Read the CC and TLVs only as far as the NDEF value. Keep raw verification,
/// including preceding NULL/control TLVs and extended lengths, within 512 bytes.
enum URLNDEFReader {
    static func read(block: @Sendable (Int) async throws -> Data) async throws -> Data? {
        var memory = Data()
        func ensure(_ count: Int) async throws {
            guard count <= 512 else { throw URLCodecError.malformedType5 }
            while memory.count < count {
                try Task.checkCancellation()
                let bytes = try await block(memory.count / 4)
                guard bytes.count == 4 else { throw URLCodecError.malformedType5 }
                memory.append(bytes)
            }
        }
        try await ensure(4)
        guard memory[0] == 0xe1 || memory[0] == 0xe2 else { return nil }
        var offset = memory[2] == 0 ? 8 : 4
        while offset < 512 {
            try await ensure(offset + 1)
            let type = memory[offset]
            offset += 1
            if type == 0 { continue }
            if type == 0xfe { return nil }
            try await ensure(offset + 1)
            var length = Int(memory[offset])
            offset += 1
            if length == 255 {
                try await ensure(offset + 2)
                length = Int(memory[offset]) * 256 + Int(memory[offset + 1])
                offset += 2
            }
            try await ensure(offset + length)
            if type == 3 { return try URLCodec.type5NDEF(in: memory) }
            offset += length
        }
        return nil
    }
}
