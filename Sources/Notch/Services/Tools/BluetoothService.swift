import AppKit
import IOBluetooth
import Observation

struct BluetoothAccessory: Equatable {
    var name: String
    /// 0...1 per side; AirPods report each bud separately, other devices only `main`.
    var main: Double?
    var left: Double?
    var right: Double?
    var caseLevel: Double?

    var lowestLevel: Double? {
        [main, left, right].compactMap { $0 }.min()
    }

    var symbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "airpodsmax" }
        if lower.contains("airpods pro") { return "airpodspro" }
        if lower.contains("airpods") { return "airpods" }
        if lower.contains("beats") || lower.contains("headphone") { return "headphones" }
        if lower.contains("mouse") || lower.contains("magic trackpad") { return "magicmouse" }
        if lower.contains("keyboard") { return "keyboard" }
        return "wave.3.right"
    }
}

/// Reports Bluetooth accessories connecting, with battery when macOS knows it.
/// Levels come from `system_profiler`, since IOBluetooth doesn't expose them.
@MainActor
@Observable
final class BluetoothService {
    private(set) var lastConnected: BluetoothAccessory?

    /// Fired shortly after a device connects, once the battery has been read.
    @ObservationIgnored var onConnected: ((BluetoothAccessory) -> Void)?

    @ObservationIgnored private var connectObserver: IOBluetoothUserNotification?
    @ObservationIgnored private var pending: DispatchWorkItem?

    func start() {
        guard connectObserver == nil else { return }
        connectObserver = IOBluetoothDevice.register(forConnectNotifications: self,
                                                     selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectObserver?.unregister()
        connectObserver = nil
    }

    /// Reads current levels for an already connected device (Tools tab).
    func refresh(name: String? = nil) {
        loadBattery(for: name ?? lastConnected?.name, notify: false)
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? device.addressString ?? "Bluetooth device"
        // macOS needs a moment before it reports battery for a fresh connection.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.loadBattery(for: name, notify: true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func loadBattery(for name: String?, notify: Bool) {
        guard let name else { return }
        DispatchQueue.global(qos: .utility).async {
            let accessory = Self.readAccessory(named: name)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let result = accessory ?? BluetoothAccessory(name: name)
                self.lastConnected = result
                if notify { self.onConnected?(result) }
            }
        }
    }

    /// Parses `system_profiler SPBluetoothDataType -json` for the device's levels.
    nonisolated private static func readAccessory(named name: String) -> BluetoothAccessory? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = json["SPBluetoothDataType"] as? [[String: Any]] else { return nil }

        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (deviceName, value) in entry {
                    guard deviceName == name, let info = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Double? {
                        guard let text = info[key] as? String else { return nil }
                        return Double(text.replacingOccurrences(of: "%", with: "")).map { $0 / 100 }
                    }
                    return BluetoothAccessory(name: deviceName,
                                              main: level("device_batteryLevelMain"),
                                              left: level("device_batteryLevelLeft"),
                                              right: level("device_batteryLevelRight"),
                                              caseLevel: level("device_batteryLevelCase"))
                }
            }
        }
        return nil
    }
}
