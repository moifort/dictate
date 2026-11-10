@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Observation

/// Records the default microphone into memory as 16 kHz mono samples.
///
/// Always the input selected in macOS, Bluetooth headsets included: the user
/// picks the microphone there, and the app never second-guesses that choice.
/// While a call holds the microphone with voice processing (FaceTime, Meet in
/// Safari), macOS mutes it for every other app: Dictate then hears nothing,
/// the price of capturing the input alone, which keeps AirPods out of it.
@Observable
public final class AudioRecorder {
    /// Recent input level and its spread across frequency bands, for the recording indicator.
    public private(set) var spectrum = VoiceSpectrum.silent

    @ObservationIgnored private var capture: QueueCapture?
    @ObservationIgnored private var tap: TapProcessor?

    /// Shorter than the ten seconds a wedged device takes to fail: the key is
    /// held all that time.
    private static let openingTimeout: Duration = .seconds(5)
    /// AirPods measured 1.3 to 2.8 s of digital silence while they switch to
    /// their call profile. A muted microphone (the built-in one with the lid
    /// closed) never delivers sound: past this, the recording starts anyway.
    private static let signalTimeout: Duration = .seconds(4)

    public enum RecorderError: LocalizedError {
        case noInputDevice
        /// Core Audio's `kAudioHardwareNotRunningError` ('stop'): the device
        /// refused to start, often after a sleep or when another app grabbed it.
        case deviceNotRunning

        public var errorDescription: String? {
            switch self {
            case .noInputDevice: String(localized: "Aucun micro disponible", bundle: .module)
            case .deviceNotRunning: String(localized: "Le micro ne répond pas", bundle: .module)
            }
        }
    }

    /// Opens the microphone off the main thread: a wedged device can block
    /// the start for ten seconds before it fails, and the pill must keep
    /// showing that something is happening meanwhile. Past `openingTimeout`
    /// it gives up, and a start that still succeeds later is closed.
    public init() {}

    /// Returns once the microphone delivers sound, or gives up waiting for
    /// it. Cancelling the calling task cuts that wait short.
    public func start() async throws {
        let onSpectrum: @Sendable (VoiceSpectrum) -> Void = { [weak self] spectrum in
            Task { @MainActor in self?.spectrum = spectrum }
        }
        let opening = Task.detached(priority: .userInitiated) {
            try Self.startCapture(onSpectrum: onSpectrum)
        }
        let started: StartedCapture
        do {
            started = try await value(of: opening, within: Self.openingTimeout) { late in
                Log.dictation.notice("microphone opened after the timeout: closing it")
                late.capture.stop()
            }
        } catch is DeadlineExceeded {
            throw RecorderError.deviceNotRunning
        }
        capture = started.capture
        tap = started.tap
        // The pill says "listening" only once the user can be heard.
        let clock = ContinuousClock()
        let opened = clock.now
        let heard = await started.tap.waitForSignal(within: Self.signalTimeout)
        let milliseconds = (clock.now - opened).milliseconds
        if heard {
            Log.dictation.info("microphone delivered sound \(milliseconds) ms after opening")
        } else {
            Log.dictation.notice("no sound from the microphone after \(milliseconds) ms: recording anyway")
        }
    }

    nonisolated private struct StartedCapture: Sendable {
        let capture: QueueCapture
        let tap: TapProcessor
    }

    nonisolated private static func startCapture(
        onSpectrum: @escaping @Sendable (VoiceSpectrum) -> Void
    ) throws -> StartedCapture {
        guard defaultInputDevice() != nil else { throw RecorderError.noInputDevice }
        let processor = try TapProcessor(inputFormat: QueueCapture.format, onSpectrum: onSpectrum)
        do {
            let capture = try QueueCapture { buffer in processor.consume(buffer) }
            return StartedCapture(capture: capture, tap: processor)
        } catch {
            if (error as NSError).code == Int(kAudioHardwareNotRunningError) { throw RecorderError.deviceNotRunning }
            throw error
        }
    }

    /// Stops recording and returns everything captured since `start()`.
    public func stop() -> [Float] {
        capture?.stop()
        capture = nil
        spectrum = .silent
        defer { tap = nil }
        return tap?.drain() ?? []
    }

    nonisolated private static func defaultInputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}

/// Opens the default input and nothing else. `AVAudioEngine` also started the
/// default output, and waking AirPods there held the microphone back by up
/// to 1.4 s, a USB webcam's included, against 0.17 s for this queue.
nonisolated final class QueueCapture: @unchecked Sendable {
    /// What the queue hands over whatever the device: it converts the rate
    /// and mixes the channels down itself.
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    /// About 21 ms, so the waves follow syllables.
    private static let framesPerBuffer: UInt32 = 1_024
    private static let bufferCount = 4

    private var queue: AudioQueueRef?
    private let callbacks = DispatchQueue(label: "com.thibautmottet.dictate.microphone", qos: .userInteractive)

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let format = Self.format
        var created: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&created, &description, 0, callbacks) { queue, buffer, _, _, _ in
            let bytes = buffer.pointee.mAudioDataByteSize
            let frames = bytes / 4
            if frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let channel = pcm.floatChannelData {
                pcm.frameLength = frames
                memcpy(channel[0], buffer.pointee.mAudioData, Int(bytes))
                onBuffer(pcm)
            }
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        }
        guard status == noErr, let created else { throw Self.error(status) }
        queue = created
        for _ in 0..<Self.bufferCount {
            var buffer: AudioQueueBufferRef?
            let allocated = AudioQueueAllocateBuffer(created, Self.framesPerBuffer * 4, &buffer)
            guard allocated == noErr, let buffer else { stop(); throw Self.error(allocated) }
            AudioQueueEnqueueBuffer(created, buffer, 0, nil)
        }
        let started = AudioQueueStart(created, nil)
        guard started == noErr else { stop(); throw Self.error(started) }
    }

    /// Synchronous: no buffer arrives once it returns.
    func stop() {
        guard let queue else { return }
        self.queue = nil
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
    }

    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
}

/// Runs on the audio thread: resamples each buffer and accumulates samples.
nonisolated final class TapProcessor: @unchecked Sendable {
    private let resampler: AudioResampler
    private let onSpectrum: @Sendable (VoiceSpectrum) -> Void
    private let analyzer = SpectrumAnalyzer()
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Past this, buffers are dropped: a recording nobody stops (a key-up the
    /// app never received) must not grow without end. The app releases its
    /// recordings well before.
    private let maximumSamples: Int
    /// Set by the first buffer holding anything but digital silence.
    private var hasSignal = false
    private var signalWaiter: CheckedContinuation<Bool, Never>?
    /// Timed out or cancelled: one wait per recording, so it never resets.
    private var waitEnded = false

    /// Fifteen minutes at 16 kHz, about 58 MB.
    static let defaultMaximumSamples = AudioAnalysis.sampleRate * 15 * 60

    init(
        inputFormat: AVAudioFormat,
        maximumSamples: Int = TapProcessor.defaultMaximumSamples,
        onSpectrum: @escaping @Sendable (VoiceSpectrum) -> Void
    ) throws {
        resampler = try AudioResampler(inputFormat: inputFormat)
        self.maximumSamples = maximumSamples
        self.onSpectrum = onSpectrum
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        let chunk = resampler.convert(buffer)
        guard !chunk.isEmpty else { return }
        lock.lock()
        samples.append(contentsOf: chunk.prefix(max(0, maximumSamples - samples.count)))
        var heardNow: CheckedContinuation<Bool, Never>?
        // Exact zeros: a real microphone always picks up some room noise.
        if !hasSignal, chunk.contains(where: { $0 != 0 }) {
            hasSignal = true
            heardNow = signalWaiter
            signalWaiter = nil
        }
        lock.unlock()
        heardNow?.resume(returning: true)
        onSpectrum(analyzer.process(chunk))
    }

    /// Waits for the microphone to deliver actual sound, at most `limit`.
    /// AirPods and other Bluetooth headsets need seconds to switch to their
    /// call profile, and hand over digital silence until then: whatever is
    /// said meanwhile is lost. False on timeout or cancellation.
    func waitForSignal(within limit: Duration) async -> Bool {
        let timer = Task { [self] in
            try? await Task.sleep(for: limit)
            endWait()
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                // The timer or a cancellation may have come before the waiter.
                if hasSignal || waitEnded {
                    let heard = hasSignal
                    lock.unlock()
                    continuation.resume(returning: heard)
                    return
                }
                signalWaiter = continuation
                lock.unlock()
            }
        } onCancel: {
            endWait()
        }
    }

    private func endWait() {
        lock.lock()
        waitEnded = true
        let waiter = signalWaiter
        signalWaiter = nil
        lock.unlock()
        waiter?.resume(returning: false)
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
public nonisolated final class AudioResampler: @unchecked Sendable {
    public enum ResamplerError: Error { case unsupportedFormat }

    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(AudioAnalysis.sampleRate),
        channels: 1,
        interleaved: false
    )!

    /// Rebuilt when a buffer arrives in another format: a device can change
    /// rate while the tap runs, and a converter set for the old one fails.
    private var converter: AVAudioConverter

    public init(inputFormat: AVAudioFormat) throws {
        guard let converter = Self.converter(from: inputFormat) else { throw ResamplerError.unsupportedFormat }
        self.converter = converter
    }

    private static func converter(from inputFormat: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        // Discrete multichannel input maps to no output channel by default,
        // which yields silence: take the first channel explicitly.
        if inputFormat.channelCount > 1 { converter.channelMap = [0] }
        return converter
    }

    public func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if buffer.format != converter.inputFormat {
            guard let converter = Self.converter(from: buffer.format) else { return [] }
            self.converter = converter
        }
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
    public static func samples(fromFile url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        return try AudioResampler(inputFormat: file.processingFormat).convert(buffer)
    }
}
