import AudioToolbox
import CoreAudio
import Observation

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32

    var symbol: String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker"
        default:
            return "speaker.wave.2"
        }
    }
}

/// Output devices, the default output, and its volume / mute. Event based (Core Audio listeners).
@MainActor
@Observable
final class AudioOutputService {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var currentID = AudioObjectID(kAudioObjectUnknown)
    private(set) var volume: Float = 0
    private(set) var isMuted = false
    private(set) var canSetVolume = false

    var current: AudioOutputDevice? { devices.first { $0.id == currentID } }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var deviceListener: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var listenedDevice = AudioObjectID(kAudioObjectUnknown)

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    func start() {
        guard !started else { return }
        started = true
        let onChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        var devicesAddress = Self.address(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(Self.system, &devicesAddress, .main, onChange)
        var defaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(Self.system, &defaultAddress, .main, onChange)
        reload()
    }

    // MARK: - Actions

    func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        var clamped = min(max(value, 0), 1)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(currentID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped)
        volume = clamped
        if isMuted, clamped > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(currentID, &address) else { return }
        AudioObjectSetPropertyData(currentID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        isMuted = muted
    }

    func select(_ device: AudioOutputDevice) {
        var id = device.id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(Self.system, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
    }

    // MARK: - State

    private func reload() {
        devices = Self.outputDevices()
        var id = AudioObjectID(kAudioObjectUnknown)
        _ = Self.get(Self.system, kAudioHardwarePropertyDefaultOutputDevice, &id)
        currentID = id
        listenToVolume(of: id)
        refreshVolume()
    }

    private func refreshVolume() {
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        var settable: DarwinBoolean = false
        canSetVolume = AudioObjectHasProperty(currentID, &address)
            && AudioObjectIsPropertySettable(currentID, &address, &settable) == noErr && settable.boolValue
        var value: Float32 = 0
        if Self.get(currentID, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, &value, scope: kAudioObjectPropertyScopeOutput) {
            volume = value
        }
        var muted: UInt32 = 0
        isMuted = Self.get(currentID, kAudioDevicePropertyMute, &muted, scope: kAudioObjectPropertyScopeOutput) && muted != 0
    }

    private func listenToVolume(of device: AudioObjectID) {
        guard device != listenedDevice else { return }
        let selectors = [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute]
        if let block = deviceListener, listenedDevice != kAudioObjectUnknown {
            for selector in selectors {
                var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
                AudioObjectRemovePropertyListenerBlock(listenedDevice, &address, .main, block)
            }
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshVolume() }
        }
        for selector in selectors {
            var address = Self.address(selector, scope: kAudioObjectPropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        }
        deviceListener = block
        listenedDevice = device
    }

    // MARK: - Core Audio helpers

    private static func outputDevices() -> [AudioOutputDevice] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var name: CFString = "" as CFString
            guard get(id, kAudioObjectPropertyName, &name) else { return nil }
            let deviceName = name as String
            if deviceName.hasPrefix("Notch Spectrum") { return nil } // our own capture device
            var transport: UInt32 = 0
            _ = get(id, kAudioDevicePropertyTransportType, &transport)
            return AudioOutputDevice(id: id, name: deviceName, transport: transport)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    @discardableResult
    private static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        } == noErr
    }
}
