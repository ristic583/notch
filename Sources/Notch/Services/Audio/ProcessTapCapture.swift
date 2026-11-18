import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Captures the whole system output with a Core Audio process tap (macOS 14.2+)
/// attached to a private aggregate device. Nothing is played back or muted.
final class ProcessTapCapture: @unchecked Sendable {
    enum CaptureError: Error {
        case coreAudio(String, OSStatus)
        case unsupportedFormat
    }

    private let analyzer: SpectrumAnalyzer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "notch.audio.tap", qos: .userInteractive)
    private var mono = [Float](repeating: 0, count: 8192)

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
    }

    var isRunning: Bool { ioProcID != nil }

    func start() throws {
        guard !isRunning else { return }
        do {
            try createTap()
            try createAggregateDevice()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        analyzer.reset()
    }

    // MARK: - Setup

    private var tapUUID = UUID()

    private func createTap() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapUUID = UUID()
        description.uuid = tapUUID
        description.name = "Notch Spectrum"
        description.muteBehavior = .unmuted
        description.isPrivate = true

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw CaptureError.coreAudio("AudioHardwareCreateProcessTap", status) }
        tapID = id

        var format = AudioStreamBasicDescription()
        try getProperty(tapID, kAudioTapPropertyFormat, &format)
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { throw CaptureError.unsupportedFormat }
        analyzer.configure(sampleRate: format.mSampleRate)
    }

    private func createAggregateDevice() throws {
        var outputID = AudioObjectID(kAudioObjectUnknown)
        try getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &outputID)
        var outputUID: CFString = "" as CFString
        try getProperty(outputID, kAudioDevicePropertyDeviceUID, &outputUID)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notch Spectrum Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else { throw CaptureError.coreAudio("AudioHardwareCreateAggregateDevice", status) }
        aggregateID = id
    }

    private func startIO() throws {
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let procID else { throw CaptureError.coreAudio("AudioDeviceCreateIOProcIDWithBlock", status) }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw CaptureError.coreAudio("AudioDeviceStart", status) }
    }

    // MARK: - Audio thread

    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        mono.withUnsafeMutableBufferPointer { out in
            let frames = downmix(buffers, into: out)
            if frames > 0 { analyzer.process(out.baseAddress!, count: frames) }
        }
    }

    // MARK: - Helpers

    private func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw CaptureError.coreAudio("get property \(selector)", status) }
    }
}
