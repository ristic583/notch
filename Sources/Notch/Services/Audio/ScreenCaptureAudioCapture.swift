import CoreMedia
import ScreenCaptureKit

/// Fallback capture through ScreenCaptureKit (needs Screen Recording permission).
/// Video is reduced to a 2×2 px frame per second; only audio is used.
final class ScreenCaptureAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private let analyzer: SpectrumAnalyzer
    private let queue = DispatchQueue(label: "notch.audio.sck", qos: .userInteractive)
    private var stream: SCStream?
    private var mono = [Float](repeating: 0, count: 16384)

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    var isRunning: Bool { stream != nil }

    func start() async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "Notch", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to capture"])
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) // avoids "dropping frame" spam
        analyzer.configure(sampleRate: 48_000)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
        analyzer.reset()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            mono.withUnsafeMutableBufferPointer { out in
                let frames = downmix(buffers, into: out)
                if frames > 0 { analyzer.process(out.baseAddress!, count: frames) }
            }
        }
    }
}
