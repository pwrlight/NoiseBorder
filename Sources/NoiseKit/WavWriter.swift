import Foundation

public enum WavWriter {
    /// 16-bit PCM WAV; каналы заданы раздельными массивами.
    public static func write(_ channels: [[Float]], sampleRate: Int, to url: URL) throws {
        let ch = channels.count
        let frames = channels[0].count
        let dataBytes = frames * ch * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(ch))
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * ch * 2)); u16(UInt16(ch * 2)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        var pcm = [Int16](repeating: 0, count: frames * ch)
        for i in 0..<frames {
            for c in 0..<ch {
                let v = max(-1, min(1, channels[c][i]))
                pcm[i * ch + c] = Int16((v * 32767).rounded()).littleEndian
            }
        }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        try d.write(to: url)
    }
}
