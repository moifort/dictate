import CoreAudio

/// Chooses the microphone to capture from. Opening a Bluetooth microphone
/// switches the headset to its hands-free profile, which cuts its playback and
/// drops to phone quality: a built-in or wired microphone is used instead.
nonisolated enum InputDevicePicker {
    struct Candidate: Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32
        var isDefault: Bool
    }

    static func pick(from candidates: [Candidate]) -> Candidate? {
        guard let preferred = candidates.first(where: \.isDefault) else { return nil }
        guard isWireless(preferred.transport) else { return preferred }
        return candidates.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? candidates.first { !isWireless($0.transport) }
            ?? preferred
    }

    private static func isWireless(_ transport: UInt32) -> Bool {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay, kAudioDeviceTransportTypeContinuityCaptureWireless:
            true
        default:
            false
        }
    }

    /// Every device with an input stream, in CoreAudio order.
    static func candidates() -> [Candidate] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = InputDeviceMonitor.address(kAudioHardwarePropertyDevices)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }

        let defaultDevice = InputDeviceMonitor.defaultInputDevice()
        return devices.compactMap { device in
            guard inputChannelCount(of: device) > 0 else { return nil }
            return Candidate(
                id: device,
                name: name(of: device),
                transport: transportType(of: device),
                isDefault: device == defaultDevice
            )
        }
    }

    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportType(of device: AudioDeviceID) -> UInt32 {
        var address = InputDeviceMonitor.address(kAudioDevicePropertyTransportType)
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return kAudioDeviceTransportTypeUnknown
        }
        return transport
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = InputDeviceMonitor.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return "" }
        return name.takeRetainedValue() as String
    }
}
