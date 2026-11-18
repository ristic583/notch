import Accelerate
import CoreAudio

/// Averages every channel of a Float32 buffer list (interleaved or not) into `mono`.
/// Returns the number of frames written. Allocation free, safe on the audio thread.
func downmix(_ buffers: UnsafeMutableAudioBufferListPointer, into mono: UnsafeMutableBufferPointer<Float>) -> Int {
    guard let first = buffers.first, first.mData != nil, let dst = mono.baseAddress else { return 0 }
    let firstChannels = Int(max(1, first.mNumberChannels))
    let frames = min(Int(first.mDataByteSize) / (MemoryLayout<Float>.size * firstChannels), mono.count)
    guard frames > 0 else { return 0 }

    dst.update(repeating: 0, count: frames)
    var totalChannels = 0
    for buffer in buffers {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let channels = Int(max(1, buffer.mNumberChannels))
        for channel in 0..<channels {
            vDSP_vadd(data + channel, vDSP_Stride(channels), dst, 1, dst, 1, vDSP_Length(frames))
        }
        totalChannels += channels
    }
    if totalChannels > 1 {
        var gain = 1 / Float(totalChannels)
        vDSP_vsmul(dst, 1, &gain, dst, 1, vDSP_Length(frames))
    }
    return frames
}
