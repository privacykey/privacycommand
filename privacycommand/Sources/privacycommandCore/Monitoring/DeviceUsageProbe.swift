import Foundation
#if canImport(CoreMediaIO)
import CoreMediaIO
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif

/// Direct hardware-abstraction-layer queries for "is any process
/// currently using the camera / microphone?".
///
/// Why this exists: AVFoundation's
/// `AVCaptureDevice.isInUseByAnotherApplication` is unreliable for
/// cross-process introspection on macOS 14+. Apple has tightened device
/// state reads at the AVFoundation layer in ways that aren't documented
/// and that quietly return `false` regardless of what other apps are
/// doing. The CoreMediaIO and CoreAudio HALs sit beneath AVFoundation
/// and expose the device-running flag via well-defined property
/// selectors — these continue to work without entitlements.
///
/// We query *system-wide* state (any process other than ours), not
/// per-process. Attribution to the inspected app is then handled by the
/// caller via frontmost-app correlation, the same way the AVFoundation
/// path did.
public enum DeviceUsageProbe {

    /// Returns `true` if any process other than ours has the camera open.
    public static func anyCameraInUse() -> Bool {
        #if canImport(CoreMediaIO)
        let devices = enumerateCMIODevices()
        for d in devices {
            if cmioDeviceIsRunningSomewhere(d) { return true }
        }
        #endif
        return false
    }

    /// Returns `true` if any input audio device is currently running. We
    /// filter to devices that actually have an input scope — output-only
    /// devices like AirPods (when used purely for playback) shouldn't
    /// count as "microphone in use".
    public static func anyMicrophoneInUse() -> Bool {
        #if canImport(CoreAudio)
        let devices = enumerateAudioDevices()
        for d in devices {
            guard audioDeviceHasInput(d) else { continue }
            if audioDeviceIsRunningSomewhere(d) { return true }
        }
        #endif
        return false
    }

    // MARK: - CoreMediaIO --------------------------------------------------

    #if canImport(CoreMediaIO)
    private static func enumerateCMIODevices() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size)
        guard status == 0, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<CMIODeviceID>.stride
        var ids = [CMIODeviceID](repeating: 0, count: count)
        status = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
            size, &size, &ids)
        guard status == 0 else { return [] }
        return ids.map { CMIOObjectID($0) }
    }

    private static func cmioDeviceIsRunningSomewhere(_ id: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        var inUse: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(id, &addr, 0, nil, size, &size, &inUse)
        return status == 0 && inUse != 0
    }
    #endif

    // MARK: - CoreAudio ---------------------------------------------------

    #if canImport(CoreAudio)
    private static func enumerateAudioDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard status == 0, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        guard status == 0 else { return [] }
        return ids
    }

    /// True if the device exposes any input streams. Filters out
    /// output-only devices (most speakers, AirPods in playback-only mode)
    /// so a music-playing app doesn't trip the mic-in-use signal.
    private static func audioDeviceHasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return status == 0 && size > 0
    }

    private static func audioDeviceIsRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var inUse: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &inUse)
        return status == 0 && inUse != 0
    }
    #endif
}
