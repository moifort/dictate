import Foundation

/// 16-bit PCM WAV, mono: what every audio tool and speech model reads.
nonisolated enum WAVFile {
    static func data(samples: [Float], sampleRate: Int = AudioAnalysis.sampleRate) -> Data {
        let bytesPerSample = 2
        let payload = samples.count * bytesPerSample
        var data = Data(capacity: 44 + payload)
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + payload), to: &data)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)                           // fmt chunk size
        append(UInt16(1), to: &data)                            // PCM
        append(UInt16(1), to: &data)                            // mono
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * bytesPerSample), to: &data)  // byte rate
        append(UInt16(bytesPerSample), to: &data)               // block align
        append(UInt16(16), to: &data)                           // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(payload), to: &data)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)), to: &data)
        }
        return data
    }

    /// The samples of a file written by `data(samples:)`, nil for anything else.
    static func samples(from data: Data) -> [Float]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 44,
              bytes[0..<4].elementsEqual("RIFF".utf8),
              bytes[8..<16].elementsEqual("WAVEfmt ".utf8)
        else { return nil }
        return stride(from: 44, to: bytes.count - 1, by: 2).map { index in
            Float(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)) / Float(Int16.max)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
