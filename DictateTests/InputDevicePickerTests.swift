import CoreAudio
import Testing
@testable import Dictate

struct InputDevicePickerTests {
    private typealias Candidate = InputDevicePicker.Candidate

    private let airPods = Candidate(id: 89, name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth, isDefault: true)
    private let builtIn = Candidate(id: 78, name: "MacBook Pro Microphone", transport: kAudioDeviceTransportTypeBuiltIn, isDefault: false)
    private let usb = Candidate(id: 60, name: "USB Mic", transport: kAudioDeviceTransportTypeUSB, isDefault: false)
    private let iPhone = Candidate(id: 94, name: "iPhone Microphone", transport: kAudioDeviceTransportTypeContinuityCaptureWired, isDefault: false)

    @Test func keepsTheDefaultWhenItIsNotBluetooth() {
        var builtIn = builtIn
        builtIn.isDefault = true
        var airPods = airPods
        airPods.isDefault = false

        #expect(InputDevicePicker.pick(from: [airPods, usb, builtIn]) == builtIn)
    }

    @Test func prefersTheBuiltInMicrophoneOverABluetoothDefault() {
        #expect(InputDevicePicker.pick(from: [airPods, iPhone, usb, builtIn]) == builtIn)
    }

    @Test func fallsBackToAWiredMicrophoneWithoutABuiltInOne() {
        #expect(InputDevicePicker.pick(from: [airPods, usb]) == usb)
    }

    @Test func keepsTheBluetoothDefaultWhenNothingElseIsWired() {
        let other = Candidate(id: 12, name: "Other headset", transport: kAudioDeviceTransportTypeBluetoothLE, isDefault: false)

        #expect(InputDevicePicker.pick(from: [airPods, other]) == airPods)
    }

    @Test func returnsNothingWithoutADefault() {
        var builtIn = builtIn
        builtIn.isDefault = false

        #expect(InputDevicePicker.pick(from: [builtIn]) == nil)
        #expect(InputDevicePicker.pick(from: []) == nil)
    }
}
