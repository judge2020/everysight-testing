import Foundation
import MaverickAI

struct SensorReading {
    let value: String
    let receivedAt: TimeInterval
    let deviceTimestamp: Int64?
    var count: Int
}

struct SensorSnapshot {
    let readings: [String: SensorReading]
    let capturedAt: TimeInterval
}

/// SDK callbacks only write this bounded, locked latest-value store. UIKit reads it at 1 Hz.
final class SensorMonitor: NSObject, IM2SensorsEvents, IM2GlassesSystemEvents,
    IM2GlassesBatteryEvents, IM2DisplayEvents, IM2EyeTrackerEvents,
    IM2MicrophoneEvents {
    private let lock = NSLock()
    private var readings: [String: SensorReading] = [:]
    private var accepting = false
    private(set) var isRunning = false
    private var audioSquareSum = 0.0
    private var audioSamples = 0
    private var audioPeak = 0.0
    private var byteCounts: [Int32: Int] = [:]
    private var rateStarted = ProcessInfo.processInfo.systemUptime

    private func locked<T>(_ action: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return action()
    }

    private func record(_ values: [String: String], timestamp: Int64? = nil) {
        locked {
            guard accepting else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for (key, value) in values {
                readings[key] = SensorReading(value: value, receivedAt: now,
                    deviceTimestamp: timestamp, count: (readings[key]?.count ?? 0) + 1)
            }
        }
    }

    func start() {
        guard !isRunning, Evs.shared.glassesService.isReady() else { return }
        locked {
            readings.removeAll()
            audioSquareSum = 0; audioSamples = 0; audioPeak = 0
            byteCounts.removeAll()
            rateStarted = ProcessInfo.processInfo.systemUptime
            accepting = true
        }
        isRunning = true
        let evs = Evs.shared
        evs.sensorsService.registerListener(listener: self)
        evs.glassesService.registerSystemListener(listener: self)
        evs.glassesService.registerBatteryListener(listener: self)
        evs.displayService.registerListener(listener: self)
        evs.eyeTrackerService.registerListener(listener: self)
        evs.micService.registerListener(listener: self)

        // Raw streams must be enabled separately from fused orientation in SDK 0.2.0.
        evs.sensorsService.enableInertialSensors(rate: .slow)
        evs.sensorsService.enableAcc(rate: .slow)
        evs.sensorsService.enableGyro(rate: .slow)
        evs.sensorsService.enableMag(rate: .slow)
        evs.glassesService.enableDevice(device: .ambient, enable: true)
        evs.glassesService.enableDevice(device: .prox, enable: true)
        evs.glassesService.enableDevice(device: .touch, enable: true)
        evs.eyeTrackerService.enableEyeTracker(config: M2EyeTrackerConfig.companion.DEFAULT)

        evs.micService.pcmFrameListener { [weak self] _, bytes, _ in
            self?.receivePCM(bytes)
        }
        evs.micService.enablePCM(enable: true)
        _ = evs.micService.openMicrophone(mode: .directional, bitrateKBs: 20)
        _ = evs.micService.openMicrophone(mode: .omni, bitrateKBs: 20)
        pollStatus()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        locked { accepting = false }
        let evs = Evs.shared
        // Drop callbacks first, including any late frames from a disconnect.
        evs.sensorsService.unregisterListener(listener: self)
        evs.glassesService.unregisterSystemListener(listener: self)
        evs.glassesService.unregisterBatteryListener(listener: self)
        evs.displayService.unregisterListener(listener: self)
        evs.eyeTrackerService.unregisterListener(listener: self)
        evs.micService.unregisterListener(listener: self)
        evs.micService.pcmFrameListener(pcmFrameListener: nil)
        evs.micService.enablePCM(enable: false)
        evs.micService.closeMicrophone()
        evs.eyeTrackerService.disableEyeTracker()
        evs.sensorsService.disableAcc()
        evs.sensorsService.disableGyro()
        evs.sensorsService.disableMag()
        evs.sensorsService.disableInertialSensors()
        if evs.glassesService.isReady() {
            for device in [M2DeviceType.ambient, .prox, .touch] {
                evs.glassesService.enableDevice(device: device, enable: false)
            }
        }
    }

    /// Getter-only telemetry is sampled alongside the UI, never on a render loop.
    func pollStatus() {
        guard isRunning, Evs.shared.glassesService.isReady() else { return }
        let evs = Evs.shared
        record([
            "battery": "\(evs.glassesService.battery()) %",
            "batteryPower": "\(evs.glassesService.batteryMW()) mW",
            "charging": "Charger \(evs.glassesService.isChargerConnected() ? "connected" : "disconnected") · \(evs.glassesService.isCharging() ? "charging" : "not charging")",
            "brightness": "\(evs.displayService.getBrightness()) / 255",
            "display": evs.displayService.isDisplayOn() ? "On" : "Off",
            "autoBrightness": "\(evs.displayService.isAutoBrightnessOn() ? "On" : "Off") · gain \(evs.displayService.getAutoBrightnessGain())",
            "eyeState": evs.eyeTrackerService.isEyeTrackerOn() ? "On" : "Off / waiting",
            "eyeFPS": String(format: "%.1f feature frames/s", evs.eyeTrackerService.getFps()),
            "micState": "Directional \(evs.micService.isMicrophoneOpen(mode: .directional) ? "on" : "off") · omni \(evs.micService.isMicrophoneOpen(mode: .omni) ? "on" : "off")",
            "sensorError": "\(evs.sensorsService.lastSensorsErrCode) · \(evs.sensorsService.getLastErrCodeDescription())"
        ])
        let rates: [String: String] = locked {
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - rateStarted)
            var result: [String: String] = [:]
            for (id, name) in [(M2MicMode.directional.micId, "directional"), (M2MicMode.omni.micId, "omni")] {
                result[name] = String(format: "%.1f KiB/s LC3", Double(byteCounts[id] ?? 0) / elapsed / 1024)
            }
            if audioSamples > 0 {
                let rms = sqrt(audioSquareSum / Double(audioSamples))
                result["audioLevel"] = String(format: "RMS %.1f dBFS · peak %.1f dBFS", 20 * log10(max(rms, 0.000001)), 20 * log10(max(audioPeak, 0.000001)))
            }
            audioSquareSum = 0; audioSamples = 0; audioPeak = 0
            byteCounts.removeAll()
            rateStarted = ProcessInfo.processInfo.systemUptime
            return result
        }
        record(rates)
    }

    func snapshot() -> SensorSnapshot {
        locked { SensorSnapshot(readings: readings,
            capturedAt: ProcessInfo.processInfo.systemUptime) }
    }

    private func vector(_ x: Float, _ y: Float, _ z: Float) -> String {
        String(format: "x % .3f   y % .3f   z % .3f", x, y, z)
    }
    private func floats(_ array: KotlinFloatArray) -> String {
        (0..<array.size).map { String(format: "%.3f", array.get(index: $0)) }.joined(separator: ", ")
    }
    private func point(_ pair: KotlinPair<KotlinFloat, KotlinFloat>?) -> String {
        guard let x = pair?.first?.floatValue, let y = pair?.second?.floatValue else { return "Not detected" }
        return String(format: "x %.3f   y %.3f", x, y)
    }

    func onAcc(timestampMs: Int64, x: Float, y: Float, z: Float) {
        record(["acc": vector(x, y, z)], timestamp: timestampMs)
    }
    func onGyro(timestampMs: Int64, x: Float, y: Float, z: Float) {
        record(["gyro": vector(x, y, z)], timestamp: timestampMs)
    }
    func onMag(timestampMs: Int64, x: Float, y: Float, z: Float) {
        record(["mag": vector(x, y, z)], timestamp: timestampMs)
    }
    func onQuaternion(timestampMs: Int64, quaternion: M2Quaternion, calibrationState: M2ImuCalibrationState) {
        let euler = quaternion.toEuler()
        record([
            "quaternion": String(format: "w %.4f   x %.4f\ny %.4f   z %.4f", quaternion.w, quaternion.x, quaternion.y, quaternion.z),
            "orientation": String(format: "Yaw %.1f°   pitch %.1f°   roll %.1f°", euler.get(index: 0) * 180 / .pi, euler.get(index: 1) * 180 / .pi, euler.get(index: 2) * 180 / .pi),
            "calibration": calibrationState.name
        ], timestamp: timestampMs)
    }
    func onAmbient(lux: Float) { record(["ambient": String(format: "%.1f lux", lux)]) }
    func onGlassesOnFace(isOnFace: Bool) { record(["proximity": isOnFace ? "On face" : "Off face"]) }
    func onTouch(touch: M2Touch) { record(["touch": touch.name]) }
    func onPowerButtonPressed(event: M2PowerButton) { record(["powerButton": event.name]) }
    func onDeviceEnableChanged(device: M2DeviceType, enabled: Bool) {
        record(["device.\(device.name)": enabled ? "Enabled" : "Disabled"])
    }
    func onError(fatal: Bool, info: String, errorCode: Int8) {
        record(["systemError": "\(fatal ? "Fatal" : "Warning") \(errorCode): \(info)"])
    }
    func onBatteryPercentageChanged(batteryPercentage: Int32) { record(["battery": "\(batteryPercentage) %"]) }
    func onChargingStateChanged(chargerConnected: Bool, isCharging: Bool) {
        record(["charging": "Charger \(chargerConnected ? "connected" : "disconnected") · \(isCharging ? "charging" : "not charging")"])
    }
    func onBrightnessChanged(brightness: Int32) { record(["brightness": "\(brightness) / 255"]) }
    func onDisplayStateChanged(isDisplayOn: Bool) { record(["display": isDisplayOn ? "On" : "Off"]) }
    func onAutoBrightnessGainChanged(gain: Int32) {}
    func onAutoBrightnessStateChanged(isAutoBrightnessOn: Bool) {}
    func onEyeTrackerStateChanged(isOn: Bool) { record(["eyeState": isOn ? "On" : "Off"]) }
    func onError(type: M2EyeTrackerErrors, message_: String) { record(["eyeError": "\(type.name): \(message_)"]) }
    func onM2EyeTrackerResult(result: M2EyeTrackerResult) {
        // These are eye-camera features, not calibrated display gaze coordinates.
        record([
            "eyeValid": result.isValid ? "Valid geometry" : "Invalid / eye closed / no geometry",
            "pupilVisibility": String(format: "%.1f %%", result.pupilVisibility * 100),
            "pupilCenter": point(result.filteredPupilCenter),
            "iris": floats(result.iris), "pupil": floats(result.pupil),
            "earCorner": point(result.earCorner), "noseCorner": point(result.noseCorner),
            "eyelidTop": point(result.eyelidTop), "eyelidBottom": point(result.eyelidBottom),
            "led": point(result.ledPosition), "filteredLED": point(result.filteredLedPosition),
            "eyeFrame": "\(result.frameWidth) × \(result.frameHeight) · \(result.framePixels?.size ?? 0) debug pixels"
        ])
    }
    func onMicrophoneStateChanged(isOn: Bool) { record(["micState": isOn ? "Open" : "Off"]) }
    func onError(type: M2MicService.Errors, message__: String) { record(["micError": "\(type.name): \(message__)"]) }
    func onMicrophoneRawReceived(micId: Int32, rawData: KotlinByteArray) {
        locked { if accepting { byteCounts[micId, default: 0] += Int(rawData.size) } }
        let key = micId == M2MicMode.directional.micId ? "directionalPackets" : "omniPackets"
        record([key: "Last packet \(rawData.size) bytes"])
    }
    private func receivePCM(_ bytes: KotlinByteArray) {
        // Directional PCM is little-endian signed 16-bit. Do not retain or record audio.
        var sum = 0.0, peak = 0.0
        let count = Int(bytes.size) / 2
        for i in 0..<count {
            let lo = UInt16(UInt8(bitPattern: bytes.get(index: Int32(i * 2))))
            let hi = UInt16(UInt8(bitPattern: bytes.get(index: Int32(i * 2 + 1)))) << 8
            let value = Double(Int16(bitPattern: lo | hi)) / 32768
            sum += value * value
            peak = max(peak, abs(value))
        }
        locked {
            guard accepting else { return }
            audioSquareSum += sum; audioSamples += count; audioPeak = max(audioPeak, peak)
        }
    }
}
