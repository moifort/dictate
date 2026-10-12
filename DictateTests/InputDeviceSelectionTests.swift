import CoreAudio
import Testing
@testable import Dictate

struct InputDeviceSelectionTests {
    private let builtIn = InputDeviceMonitor.InputDevice(id: 1, transport: kAudioDeviceTransportTypeBuiltIn)
    private let headset = InputDeviceMonitor.InputDevice(id: 2, transport: kAudioDeviceTransportTypeBluetooth)
    private let usb = InputDeviceMonitor.InputDevice(id: 3, transport: kAudioDeviceTransportTypeUSB)

    @Test func bluetoothDefaultIsReplacedByTheBuiltInMic() {
        #expect(InputDeviceMonitor.replacement(forDefault: headset, among: [headset, builtIn]) == 1)
    }

    @Test func bluetoothLEDefaultIsReplacedToo() {
        let le = InputDeviceMonitor.InputDevice(id: 4, transport: kAudioDeviceTransportTypeBluetoothLE)
        #expect(InputDeviceMonitor.replacement(forDefault: le, among: [le, builtIn]) == 1)
    }

    @Test func otherDefaultsAreKept() {
        #expect(InputDeviceMonitor.replacement(forDefault: usb, among: [usb, builtIn]) == nil)
        #expect(InputDeviceMonitor.replacement(forDefault: builtIn, among: [builtIn]) == nil)
        #expect(InputDeviceMonitor.replacement(forDefault: nil, among: [builtIn]) == nil)
    }

    @Test func headsetIsKeptWithoutABuiltInMic() {
        #expect(InputDeviceMonitor.replacement(forDefault: headset, among: [headset, usb]) == nil)
    }
}
