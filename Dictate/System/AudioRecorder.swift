@preconcurrency import AVFoundation
import CoreAudio
import Observation

/// Records the default microphone into memory as 16 kHz mono samples.
@Observable
final class AudioRecorder: AudioRecording {
    /// Recent input level in 0...1, for the recording indicator.
    private(set) var level: Float = 0

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var tap: TapProcessor?
    @ObservationIgnored private var isRecording = false
    /// Configured ahead of time while another app holds the mic: enabling voice
    /// processing takes most of a second, which would cut the first words.
    @ObservationIgnored private var voiceEngine: AVAudioEngine?
    @ObservationIgnored private var isWarmingVoiceEngine = false
    @ObservationIgnored private var inputMonitor: InputDeviceMonitor?

    enum RecorderError: LocalizedError {
        case noInputDevice

        var errorDescription: String? { "Aucun micro disponible." }
    }

    init() {
        inputMonitor = InputDeviceMonitor { [weak self] deviceChanged in
            self?.inputDeviceChanged(deviceChanged: deviceChanged)
        }
        inputDeviceChanged(deviceChanged: false)
    }

    func start() throws {
        if Self.isInputInUseElsewhere() {
            // An app holding the mic with voice processing (Safari WebRTC, FaceTime…)
            // mutes it for everyone else; only a voice-processed stream still hears the user.
            if voiceEngine == nil {
                Log.dictation.info("voice-processing engine not ready: configuring it now")
                voiceEngine = try Self.makeVoiceEngine()
            }
            engine = voiceEngine!
        } else {
            engine = AVAudioEngine()
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        let processor = try TapProcessor(inputFormat: format) { [weak self] level in
            Task { @MainActor in self?.level = level }
        }
        tap = processor
        input.installTap(onBus: 0, bufferSize: 4_096, format: format, block: processor.makeBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tap = nil
            throw error
        }
        isRecording = true
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        defer {
            tap = nil
            inputDeviceChanged(deviceChanged: false)
        }
        return tap?.drain() ?? []
    }

    private func inputDeviceChanged(deviceChanged: Bool) {
        // A voice-processing engine stays bound to the device it was configured on.
        if deviceChanged { voiceEngine = nil }
        // Our own capture marks the device as running: decide again once it stops.
        guard !isRecording else { return }
        if Self.isInputInUseElsewhere() {
            warmVoiceEngine()
        } else if voiceEngine != nil {
            Log.dictation.info("microphone released by the other app: dropping the voice-processing engine")
            voiceEngine = nil
        }
    }

    private func warmVoiceEngine() {
        guard voiceEngine == nil, !isWarmingVoiceEngine else { return }
        isWarmingVoiceEngine = true
        Log.dictation.info("microphone in use by another app: preparing a voice-processing engine")
        Task {
            let engine = await Task.detached(priority: .userInitiated) { try? Self.makeVoiceEngine() }.value
            isWarmingVoiceEngine = false
            if voiceEngine == nil { voiceEngine = engine }
            inputDeviceChanged(deviceChanged: false)
        }
    }

    nonisolated private static func makeVoiceEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: false, duckingLevel: .min)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        return engine
    }

    /// Whether another process is capturing audio input. Asked per process: the
    /// device-wide running flag counts our own capture, and lags for a moment after it stops.
    private static func isInputInUseElsewhere() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = InputDeviceMonitor.address(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }

        let ownPID = getpid()
        return processes.contains { process in
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = InputDeviceMonitor.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != ownPID else {
                return false
            }
            var running = UInt32(0)
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = InputDeviceMonitor.address(kAudioProcessPropertyIsRunningInput)
            return AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr && running != 0
        }
    }
}

/// Reports, on the main queue, when the default input device changes or another
/// process starts or stops using it.
final class InputDeviceMonitor {
    private let onChange: (_ deviceChanged: Bool) -> Void
    private var device: AudioDeviceID?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var runningListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping (_ deviceChanged: Bool) -> Void) {
        self.onChange = onChange
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchDefaultDevice()
                self?.onChange(true)
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        defaultDeviceListener = listener
        watchDefaultDevice()
    }

    isolated deinit {
        if let defaultDeviceListener {
            var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultDeviceListener)
        }
        unwatchDevice()
    }

    private func watchDefaultDevice() {
        unwatchDevice()
        guard let device = Self.defaultInputDevice() else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange(false) }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, .main, listener)
        self.device = device
        runningListener = listener
    }

    private func unwatchDevice() {
        guard let device, let runningListener else { return }
        var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        AudioObjectRemovePropertyListenerBlock(device, &address, .main, runningListener)
        self.device = nil
        self.runningListener = nil
    }

    nonisolated static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Runs on the audio thread: resamples each buffer and accumulates samples.
nonisolated final class TapProcessor: @unchecked Sendable {
    private let resampler: AudioResampler
    private let onLevel: @Sendable (Float) -> Void
    private let lock = NSLock()
    private var samples: [Float] = []
    private var smoothedLevel: Float = 0

    init(inputFormat: AVAudioFormat, onLevel: @escaping @Sendable (Float) -> Void) throws {
        resampler = try AudioResampler(inputFormat: inputFormat)
        self.onLevel = onLevel
    }

    func makeBlock() -> AVAudioNodeTapBlock {
        { [self] buffer, _ in process(buffer) }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()

        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let level = AudioAnalysis.meterLevel(rms: (sum / Float(chunk.count)).squareRoot())
        // Rises instantly, falls over a few buffers: the meter breathes instead of flickering.
        smoothedLevel = max(level, smoothedLevel * 0.8)
        onLevel(smoothedLevel)
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let captured = samples
        samples = []
        return captured
    }
}

/// Converts PCM buffers of any format to 16 kHz mono Float32.
nonisolated final class AudioResampler: @unchecked Sendable {
    enum ResamplerError: Error { case unsupportedFormat }

    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(AudioAnalysis.sampleRate),
        channels: 1,
        interleaved: false
    )!

    private let converter: AVAudioConverter

    init(inputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw ResamplerError.unsupportedFormat
        }
        // Discrete multichannel input (voice processing) maps to no output channel
        // by default, which yields silence: take the first channel explicitly.
        if inputFormat.channelCount > 1 { converter.channelMap = [0] }
        self.converter = converter
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = Self.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// Reads a whole audio file as 16 kHz mono samples.
    static func samples(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        return try AudioResampler(inputFormat: file.processingFormat).convert(buffer)
    }
}
