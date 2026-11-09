// DeviceLoadMonitor.swift
//
// Centralised observable for device pressure signals that throttle native
// scan + camera workloads:
//
//   1. Low-power mode  — `ProcessInfo.isLowPowerModeEnabled`
//      (notification: `.NSProcessInfoPowerStateDidChange`)
//   2. Thermal state   — `ProcessInfo.thermalState`
//      (notification: `.NSProcessInfoThermalStateDidChange`)
//
// Consumers (ScanSessionTask, CameraFrameProcessor) query a single 0…1
// load factor at start-of-work and subscribe to changes so they can apply
// the multiplier live to in-flight work.
//
// Multipliers (lower = throttle harder):
//   • low-power off   →  1.0
//   • low-power on    →  0.5
//   • thermal nominal →  1.0
//   • thermal fair    →  1.0
//   • thermal serious →  0.5
//   • thermal critical→  0.25
//
// The exposed `currentLoadFactor` is the product of the two — so e.g. a
// device in low-power + .serious throttles to 0.25x, and a fresh device on
// AC stays at 1.0x.

import Foundation

final class DeviceLoadMonitor: @unchecked Sendable {

    static let shared = DeviceLoadMonitor()

    /// Posted whenever `currentLoadFactor` changes. Object is the monitor,
    /// userInfo carries the new factor under key `"loadFactor"` for any
    /// observer that prefers KVO-style payloads to a direct property read.
    static let loadFactorDidChange = Notification.Name(
        "com.nsfw_detect_ios.DeviceLoadMonitor.loadFactorDidChange"
    )

    private let lock = NSLock()
    private var _lowPower: Bool
    private var _thermal:  ProcessInfo.ThermalState

    private init() {
        self._lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        self._thermal  = ProcessInfo.processInfo.thermalState

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: .NSProcessInfoPowerStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public state

    /// Combined load factor in `[0.25, 1.0]`. Multiply by it to throttle
    /// (workers, FPS, batch size). 1.0 = no throttling.
    var currentLoadFactor: Double {
        lock.lock(); defer { lock.unlock() }
        return Self.combine(lowPower: _lowPower, thermal: _thermal)
    }

    var isLowPowerMode: Bool {
        lock.lock(); defer { lock.unlock() }
        return _lowPower
    }

    var thermalState: ProcessInfo.ThermalState {
        lock.lock(); defer { lock.unlock() }
        return _thermal
    }

    /// Snapshot helper so callers can derive a worker count without doing
    /// the math twice. Always returns at least 1.
    func scaledWorkers(base: Int) -> Int {
        let scaled = Int((Double(max(1, base)) * currentLoadFactor).rounded())
        return max(1, scaled)
    }

    /// Same shape, but for FPS. Returns at least 1.
    func scaledFps(base: Int) -> Int {
        let scaled = Int((Double(max(1, base)) * currentLoadFactor).rounded())
        return max(1, scaled)
    }

    // MARK: - Notifications

    @objc private func powerStateChanged() {
        let newValue = ProcessInfo.processInfo.isLowPowerModeEnabled
        lock.lock()
        let changed = (_lowPower != newValue)
        _lowPower = newValue
        let factor = Self.combine(lowPower: _lowPower, thermal: _thermal)
        lock.unlock()
        if changed { broadcast(factor: factor) }
    }

    @objc private func thermalStateChanged() {
        let newValue = ProcessInfo.processInfo.thermalState
        lock.lock()
        let changed = (_thermal != newValue)
        _thermal = newValue
        let factor = Self.combine(lowPower: _lowPower, thermal: _thermal)
        lock.unlock()
        if changed { broadcast(factor: factor) }
    }

    private func broadcast(factor: Double) {
        NotificationCenter.default.post(
            name: Self.loadFactorDidChange,
            object: self,
            userInfo: ["loadFactor": factor]
        )
    }

    // MARK: - Math

    private static func combine(lowPower: Bool,
                                thermal: ProcessInfo.ThermalState) -> Double {
        let powerFactor: Double = lowPower ? 0.5 : 1.0
        let thermalFactor: Double = {
            switch thermal {
            case .nominal:  return 1.0
            case .fair:     return 1.0
            case .serious:  return 0.5
            case .critical: return 0.25
            @unknown default: return 1.0
            }
        }()
        return powerFactor * thermalFactor
    }
}
