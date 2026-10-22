@preconcurrency import AVFoundation
import CoreAudio
import Observation

/// Records the default microphone into memory as 16 kHz mono samples.
@Observable
final class AudioRecorder: AudioRecording {
    /// Recent input level and its spread across frequency bands, for the recording indicator.
    private(set) var spectrum = VoiceSpectrum.silent

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
        /// Core Audio's `kAudioHardwareNotRunningError` ('stop'): the device
        /// refused to start, often after a sleep or when another app grabbed it.
        case deviceNotRunning

        var errorDescription: String? {
            switch self {
            case .noInputDevice: String(localized: "Aucun micro disponible")
            case .deviceNotRunning: String(localized: "Le micro ne répond pas")
            }
        }
    }

    init() {
        inputMonitor = InputDeviceMonitor { [weak self] deviceChanged in
            self?.inputDeviceChanged(deviceChanged: deviceChanged)
        }
        inputDeviceChanged(deviceChanged: false)
    }

    /// Opens the microphone off the main thread: a wedged device can block
    /// `AVAudioEngine.start()` for ten seconds before it fails, and the pill
    /// must keep showing that something is happening meanwhile.
    func start() async throws {
        // Our own capture marks the device as running: `inputDeviceChanged`
        // must not take it for another app while the engine starts.
        isRecording = true
        let warmed = voiceEngine
        let onSpectrum: @Sendable (VoiceSpectrum) -> Void = { [weak self] spectrum in
            Task { @MainActor in self?.spectrum = spectrum }
        }
        let started: StartedEngine
        do {
            started = try await Task.detached(priority: .userInitiated) {
                try Self.startEngine(warmedVoiceEngine: warmed, onSpectrum: onSpectrum)
            }.value
        } catch {
            isRecording = false
            throw error
        }
        engine = started.engine
        tap = started.tap
        if started.usesVoiceProcessing { voiceEngine = started.engine }
    }

    nonisolated private struct StartedEngine: @unchecked Sendable {
        let engine: AVAudioEngine
        let tap: TapProcessor
        let usesVoiceProcessing: Bool
    }

    nonisolated private static func startEngine(
        warmedVoiceEngine: AVAudioEngine?,
        onSpectrum: @escaping @Sendable (VoiceSpectrum) -> Void
    ) throws -> StartedEngine {
        let engine: AVAudioEngine
        let usesVoiceProcessing = isInputInUseElsewhere()
        if usesVoiceProcessing {
            // An app holding the mic with voice processing (Safari WebRTC, FaceTime…)
            // mutes it for everyone else; only a voice-processed stream still hears the user.
            if let warmedVoiceEngine {
                engine = warmedVoiceEngine
            } else {
                Log.dictation.info("voice-processing engine not ready: configuring it now")
                engine = try makeVoiceEngine()
            }
        } else {
            engine = AVAudioEngine()
            bindInput(of: engine)
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }

        let processor = try TapProcessor(inputFormat: format, onSpectrum: onSpectrum)
        // About 21 ms at 48 kHz, so the waves follow syllables; the hardware may
        // still deliver larger buffers, which the analyzer handles.
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: processor.makeBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if (error as NSError).code == Int(kAudioHardwareNotRunningError) { throw RecorderError.deviceNotRunning }
            throw error
        }
        return StartedEngine(engine: engine, tap: processor, usesVoiceProcessing: usesVoiceProcessing)
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        spectrum = .silent
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
            let engine = await Task.detached(priority: .userInitiated) { () -> AVAudioEngine? in
                do {
                    return try Self.makeVoiceEngine()
                } catch {
                    Log.dictation.error("voice-processing engine failed: \(error.localizedDescription, privacy: .public)")
                    ErrorReporter.capture(error, "voice-processing engine could not be prepared", category: "recorder")
                    return nil
                }
            }.value
            isWarmingVoiceEngine = false
            if voiceEngine == nil { voiceEngine = engine }
            inputDeviceChanged(deviceChanged: false)
        }
    }

    nonisolated private static func makeVoiceEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        bindInput(of: engine)
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            .init(enableAdvancedDucking: false, duckingLevel: .min)
        try engine.inputNode.setVoiceProcessingEnabled(true)
        return engine
    }

    /// Captures from the microphone the picker chose when it is not the default
    /// one. Must run before anything else touches the input node: a voice-processing
    /// unit bound afterwards captures nothing or fails to initialise.
    nonisolated private static func bindInput(of engine: AVAudioEngine) {
        guard let device = InputDevicePicker.pick(from: InputDevicePicker.candidates()), !device.isDefault,
              let unit = engine.inputNode.audioUnit else { return }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status == noErr {
            Log.dictation.info("default microphone is wireless: capturing from \(device.name, privacy: .public) instead")
        } else {
            Log.dictation.error("could not capture from \(device.name, privacy: .public): \(status)")
            ErrorReporter.capture(message: "could not bind the input device, status \(status)", category: "recorder")
        }
    }

    /// Whether another process is capturing audio input. Asked per process: the
    /// device-wide running flag counts our own capture, and lags for a moment after it stops.
    nonisolated private static func isInputInUseElsewhere() -> Bool {
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
    private let onSpectrum: @Sendable (VoiceSpectrum) -> Void
    private let analyzer = SpectrumAnalyzer()
    private let lock = NSLock()
    private var samples: [Float] = []

    init(inputFormat: AVAudioFormat, onSpectrum: @escaping @Sendable (VoiceSpectrum) -> Void) throws {
        resampler = try AudioResampler(inputFormat: inputFormat)
        self.onSpectrum = onSpectrum
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
        onSpectrum(analyzer.process(chunk))
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
