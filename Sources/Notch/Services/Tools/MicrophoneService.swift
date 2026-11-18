import CoreAudio
import Observation

/// Shows when something is listening to the microphone and mutes it.
/// Everything comes from Core Audio properties, so no permission is needed.
@MainActor
@Observable
final class MicrophoneService {
    private(set) var isInUse = false
    private(set) var isMuted = false
    private(set) var canMute = false
    private(set) var deviceName = ""

    @ObservationIgnored private var deviceID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var started = false

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let watched: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioDevicePropertyMute,
        kAudioDevicePropertyVolumeScalar,
    ]

    func start() {
        guard !started else { return }
        started = true
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(Self.system, &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard deviceID != kAudioObjectUnknown else { return }
        var mute: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        if AudioObjectHasProperty(deviceID, &address) {
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute)
        } else {
            // Devices without a mute switch: drop the input gain instead.
            var volume: Float32 = muted ? 0 : 1
            var volumeAddress = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)
            guard AudioObjectHasProperty(deviceID, &volumeAddress) else { return }
            AudioObjectSetPropertyData(deviceID, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        }
        refresh()
    }

    // MARK: - State

    private func reload() {
        if let listener, deviceID != kAudioObjectUnknown {
            for selector in Self.watched {
                var address = Self.address(selector, scope: kAudioObjectPropertyScopeInput)
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, listener)
            }
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        _ = Self.get(Self.system, kAudioHardwarePropertyDefaultInputDevice, &id)
        deviceID = id
        guard id != kAudioObjectUnknown else {
            isInUse = false
            canMute = false
            return
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        for selector in Self.watched {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeInput)
            AudioObjectAddPropertyListenerBlock(id, &address, .main, block)
        }
        listener = block
        refresh()
    }

    private func refresh() {
        var name: CFString = "" as CFString
        if Self.get(deviceID, kAudioObjectPropertyName, &name) { deviceName = name as String }

        var running: UInt32 = 0
        isInUse = Self.get(deviceID, kAudioDevicePropertyDeviceIsRunningSomewhere, &running) && running != 0

        var muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        var volumeAddress = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)
        if AudioObjectHasProperty(deviceID, &muteAddress) {
            var mute: UInt32 = 0
            canMute = true
            isMuted = Self.get(deviceID, kAudioDevicePropertyMute, &mute, scope: kAudioObjectPropertyScopeInput) && mute != 0
        } else if AudioObjectHasProperty(deviceID, &volumeAddress) {
            var volume: Float32 = 1
            canMute = true
            isMuted = Self.get(deviceID, kAudioDevicePropertyVolumeScalar, &volume, scope: kAudioObjectPropertyScopeInput) && volume <= 0.001
        } else {
            canMute = false
            isMuted = false
        }
    }

    // MARK: - Helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    @discardableResult
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope: scope)
        guard object != kAudioObjectUnknown, AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        } == noErr
    }
}
