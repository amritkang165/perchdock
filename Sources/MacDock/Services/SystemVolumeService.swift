import AudioToolbox
import CoreAudio
import Observation

/// System output volume and mute (the same ones the menu bar and volume keys change),
/// via Core Audio on the default output device.
///
/// Listens for changes from anywhere (keys, Control Center, another output device
/// being selected). Devices without a software volume (some HDMI/USB outputs)
/// report `blnHasVolume == false`.
@MainActor
@Observable
final class SystemVolumeService {
    /// Output volume, 0…1.
    private(set) var fltVolume: Float = 0
    /// Whether output is muted.
    private(set) var blnIsMuted = false
    /// Whether the current output device's volume can be controlled.
    private(set) var blnHasVolume = false

    @ObservationIgnored private var intDevice = AudioDeviceID(kAudioObjectUnknown)
    /// Devices we've attached volume/mute listeners to (once each).
    @ObservationIgnored private var setIntWatchedDevices: Set<AudioDeviceID> = []
    @ObservationIgnored private var blnStarted = false

    /// Reads the current state and starts listening for changes.
    func start() {
        guard !blnStarted else { return }
        blnStarted = true

        // Follow the default output device (e.g. switching to headphones).
        var objDefaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &objDefaultAddress, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Sets the output volume (unmuting, like the volume keys do).
    /// - Parameter fltNewVolume: Volume 0…1.
    func setVolume(_ fltNewVolume: Float) {
        var fltValue = min(1, max(0, fltNewVolume))
        var objAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        let intStatus = AudioObjectSetPropertyData(intDevice, &objAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &fltValue)
        guard intStatus == noErr else { return }
        fltVolume = fltValue
        if blnIsMuted && fltValue > 0 { setMuted(false) }
    }

    /// Mutes or unmutes output.
    /// - Parameter blnMuted: New state.
    func setMuted(_ blnMuted: Bool) {
        var intValue: UInt32 = blnMuted ? 1 : 0
        var objAddress = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectSetPropertyData(intDevice, &objAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &intValue) == noErr else { return }
        blnIsMuted = blnMuted
    }

    /// Re-reads the default device, its volume and mute state.
    func refresh() {
        var objDefaultAddress = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var intNewDevice = AudioDeviceID(kAudioObjectUnknown)
        var intSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &objDefaultAddress, 0, nil, &intSize, &intNewDevice) == noErr else {
            blnHasVolume = false
            return
        }
        intDevice = intNewDevice
        watch(intNewDevice)

        // Volume.
        var objVolumeAddress = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var fltValue: Float32 = 0
        intSize = UInt32(MemoryLayout<Float32>.size)
        let blnReadVolume = AudioObjectHasProperty(intNewDevice, &objVolumeAddress)
            && AudioObjectGetPropertyData(intNewDevice, &objVolumeAddress, 0, nil, &intSize, &fltValue) == noErr
        blnHasVolume = blnReadVolume
        if blnReadVolume { fltVolume = fltValue }

        // Mute.
        var objMuteAddress = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var intMuted: UInt32 = 0
        intSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(intNewDevice, &objMuteAddress),
           AudioObjectGetPropertyData(intNewDevice, &objMuteAddress, 0, nil, &intSize, &intMuted) == noErr {
            blnIsMuted = intMuted != 0
        } else {
            blnIsMuted = false
        }
    }

    /// Attaches volume and mute listeners to a device (once).
    /// - Parameter intDeviceId: Output device.
    private func watch(_ intDeviceId: AudioDeviceID) {
        guard intDeviceId != kAudioObjectUnknown, !setIntWatchedDevices.contains(intDeviceId) else { return }
        setIntWatchedDevices.insert(intDeviceId)
        for intSelector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var objAddress = Self.address(intSelector, kAudioDevicePropertyScopeOutput)
            AudioObjectAddPropertyListenerBlock(intDeviceId, &objAddress, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Builds a Core Audio property address on the main element.
    /// - Parameters:
    ///   - intSelector: Property.
    ///   - intScope: Scope.
    /// - Returns: Address.
    private static func address(_ intSelector: AudioObjectPropertySelector,
                                _ intScope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: intSelector, mScope: intScope, mElement: kAudioObjectPropertyElementMain)
    }
}
