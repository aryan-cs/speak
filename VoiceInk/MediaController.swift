import AudioToolbox
import Combine
import CoreAudio
import Foundation

final class MediaController: ObservableObject {

    static let shared = MediaController()

    private struct VolumeControlState {
        let address: AudioObjectPropertyAddress
        let originalValue: Float32
        let duckedValue: Float32
    }

    private struct DuckingSession {
        let deviceID: AudioDeviceID
        let controls: [VolumeControlState]
    }

    private var activeDuckingSession: DuckingSession?
    private var restorationTask: Task<Void, Never>?
    private var duckingGeneration = 0

    // Keep the existing defaults key so current installations and settings
    // backups retain the user's preference.
    @Published var isSystemMuteEnabled: Bool = UserDefaults.standard.bool(forKey: "isSystemMuteEnabled") {
        didSet { UserDefaults.standard.set(isSystemMuteEnabled, forKey: "isSystemMuteEnabled") }
    }

    @Published var audioDuckingLevel: Double = UserDefaults.standard.double(forKey: "audioDuckingLevel") {
        didSet {
            let normalizedValue = Self.normalizedDuckingLevel(audioDuckingLevel)
            if normalizedValue != audioDuckingLevel {
                audioDuckingLevel = normalizedValue
            }
            UserDefaults.standard.set(normalizedValue, forKey: "audioDuckingLevel")
        }
    }

    @Published var audioResumptionDelay: Double = UserDefaults.standard.double(forKey: "audioResumptionDelay") {
        didSet { UserDefaults.standard.set(audioResumptionDelay, forKey: "audioResumptionDelay") }
    }

    private init() {
        audioDuckingLevel = Self.normalizedDuckingLevel(audioDuckingLevel)
    }

    func cancelPendingRestoration() {
        restorationTask?.cancel()
        restorationTask = nil
        duckingGeneration += 1
    }

    func duckSystemAudio() async -> Bool {
        guard isSystemMuteEnabled else { return false }
        guard let deviceID = getDefaultOutputDevice() else { return false }

        cancelPendingRestoration()

        let targetVolume = Float32(Self.normalizedDuckingLevel(audioDuckingLevel))

        if let activeDuckingSession {
            if activeDuckingSession.deviceID == deviceID {
                return reapplyDucking(to: activeDuckingSession, targetVolume: targetVolume)
            }

            restoreVolume(from: activeDuckingSession)
            self.activeDuckingSession = nil
        }

        let controls = writableVolumeAddresses(for: deviceID).compactMap { address -> VolumeControlState? in
            guard let originalValue = readVolume(deviceID: deviceID, address: address) else {
                return nil
            }

            let requestedValue = min(originalValue, targetVolume)
            guard requestedValue < originalValue else { return nil }
            guard setVolume(requestedValue, deviceID: deviceID, address: address),
                  let appliedValue = readVolume(deviceID: deviceID, address: address) else {
                return nil
            }

            return VolumeControlState(
                address: address,
                originalValue: originalValue,
                duckedValue: appliedValue
            )
        }

        guard !controls.isEmpty else {
            return writableVolumeAddresses(for: deviceID).contains { address in
                guard let currentValue = readVolume(deviceID: deviceID, address: address) else {
                    return false
                }
                return currentValue <= targetVolume
            }
        }

        activeDuckingSession = DuckingSession(deviceID: deviceID, controls: controls)
        return true
    }

    func restoreSystemAudio() async {
        guard let session = activeDuckingSession else { return }

        let delay = max(0, audioResumptionDelay)
        let generation = duckingGeneration

        let task = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard let self, !Task.isCancelled else { return }
            guard self.duckingGeneration == generation else { return }

            self.restoreVolume(from: session)
            self.activeDuckingSession = nil
        }

        restorationTask = task
        await task.value
    }

    private static func normalizedDuckingLevel(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0.4 }
        return min(max(value, 0.05), 1.0)
    }

    private func reapplyDucking(to session: DuckingSession, targetVolume: Float32) -> Bool {
        let refreshedControls = session.controls.compactMap { control -> VolumeControlState? in
            guard let currentValue = readVolume(
                deviceID: session.deviceID,
                address: control.address
            ) else {
                return nil
            }

            let tolerance: Float32 = 0.015
            let baselineValue = abs(currentValue - control.duckedValue) <= tolerance
                ? control.originalValue
                : currentValue
            let requestedValue = min(baselineValue, targetVolume)
            guard setVolume(requestedValue, deviceID: session.deviceID, address: control.address),
                  let appliedValue = readVolume(deviceID: session.deviceID, address: control.address) else {
                return nil
            }

            return VolumeControlState(
                address: control.address,
                originalValue: baselineValue,
                duckedValue: appliedValue
            )
        }

        guard !refreshedControls.isEmpty else { return false }
        activeDuckingSession = DuckingSession(
            deviceID: session.deviceID,
            controls: refreshedControls
        )
        return true
    }

    private func restoreVolume(from session: DuckingSession) {
        let tolerance: Float32 = 0.015

        for control in session.controls {
            guard let currentValue = readVolume(
                deviceID: session.deviceID,
                address: control.address
            ) else {
                continue
            }

            // Preserve a volume adjustment the user made while recording.
            guard abs(currentValue - control.duckedValue) <= tolerance else {
                continue
            }

            _ = setVolume(
                control.originalValue,
                deviceID: session.deviceID,
                address: control.address
            )
        }
    }

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        return status == noErr ? deviceID : nil
    }

    private func writableVolumeAddresses(for deviceID: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let virtualMainAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if isVolumeAddressWritable(virtualMainAddress, deviceID: deviceID) {
            return [virtualMainAddress]
        }

        let mainAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if isVolumeAddressWritable(mainAddress, deviceID: deviceID) {
            return [mainAddress]
        }

        return (1...32).compactMap { channel in
            let address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: AudioObjectPropertyElement(channel)
            )
            return isVolumeAddressWritable(address, deviceID: deviceID) ? address : nil
        }
    }

    private func isVolumeAddressWritable(
        _ inputAddress: AudioObjectPropertyAddress,
        deviceID: AudioDeviceID
    ) -> Bool {
        var address = inputAddress
        guard AudioObjectHasProperty(deviceID, &address) else { return false }

        var isSettable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard status == noErr, isSettable.boolValue else { return false }

        return readVolume(deviceID: deviceID, address: address) != nil
    }

    private func readVolume(
        deviceID: AudioDeviceID,
        address inputAddress: AudioObjectPropertyAddress
    ) -> Float32? {
        var address = inputAddress
        var volume = Float32(0)
        var propertySize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &volume
        )

        return status == noErr ? volume : nil
    }

    private func setVolume(
        _ inputVolume: Float32,
        deviceID: AudioDeviceID,
        address inputAddress: AudioObjectPropertyAddress
    ) -> Bool {
        var address = inputAddress
        var volume = min(max(inputVolume, 0), 1)
        let propertySize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            propertySize,
            &volume
        )

        return status == noErr
    }
}
