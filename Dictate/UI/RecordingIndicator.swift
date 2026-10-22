import AppKit
import Observation
import SwiftUI

/// Small pill at the bottom centre of the active window's screen, visible only while `fn` is
/// held and while the dictation is processed.
final class RecordingIndicator {
    enum Flash: Equatable {
        /// No field had focus: the text waits in the pasteboard.
        case copied
        /// Why the dictation failed, so a press that does nothing explains itself.
        case failed(String)
        /// `fn` pressed before the engine's model is in memory.
        case loading(TranscriptionEngine)
    }

    @Observable
    final class State {
        var flash: Flash?
    }

    private let controller: DictationController
    private let state = State()
    /// Created on the first presentation and replaced on every later one, see
    /// `presentOnActiveScreen`.
    private var panel: IndicatorPanel?
    private let content: NSHostingView<IndicatorView>
    private var flashTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?

    /// Wide enough for the loading and error messages; the panel is transparent around the pill.
    private static let size = CGSize(width: 260, height: 56)
    /// Long enough for the fade-out in `IndicatorView` to finish.
    private static let hideDelay: Duration = .milliseconds(450)

    init(controller: DictationController, recorder: AudioRecorder) {
        self.controller = controller
        content = NSHostingView(
            rootView: IndicatorView(controller: controller, recorder: recorder, state: state)
        )
        observeVisibility()
    }

    /// Briefly shows how a finished dictation ended, when it needs attention.
    func show(_ outcome: DictationOutcome) {
        let flash: Flash? = switch outcome {
        case .copied: .copied
        case .failed(let message): .failed(message)
        case .modelLoading(let engine): .loading(engine)
        case .pasted, .discarded: nil
        }
        flashTask?.cancel()
        state.flash = flash
        guard flash != nil else { return }
        flashTask = Task {
            // A sentence takes longer to read than a symbol.
            let duration: Duration = switch flash {
            case .copied: .seconds(1.6)
            case .loading: .seconds(2.5)
            case .failed, nil: .seconds(3)
            }
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            state.flash = nil
        }
    }

    private var shouldBeVisible: Bool {
        controller.phase != .idle || state.flash != nil
    }

    /// A single long-lived subscription: a `withObservationTracking` chain that
    /// re-registers itself after each change can drop a link and leave the pill
    /// hidden for the rest of the session.
    private func observeVisibility() {
        let changes = Observations { [controller, state] in (controller.phase, state.flash) }
        visibilityTask = Task { [weak self] in
            for await (phase, _) in changes {
                guard let self else { return }
                if phase == .starting || phase == .recording, state.flash != nil {
                    flashTask?.cancel()
                    state.flash = nil
                }
                updateVisibility()
            }
        }
    }

    /// The window exists only while something is shown: an invisible panel at
    /// status-bar level would still appear in screen recordings and Mission Control.
    private func updateVisibility() {
        if shouldBeVisible {
            hideTask?.cancel()
            hideTask = nil
            Log.indicator.info("""
                show for \(String(describing: self.controller.phase)), flash \(String(describing: self.state.flash)), \
                panel visible: \(self.panel?.isVisible ?? false), \
                on screen: \(self.panel?.occlusionState.contains(.visible) ?? false)
                """)
            if let panel, panel.isVisible {
                // AppKit may keep reporting the panel as visible after the window
                // server dropped it (suspected after a long session with sleeps):
                // bring it back on every show, without moving it mid-dictation.
                panel.orderFrontRegardless()
            } else {
                presentOnActiveScreen()
            }
        } else if hideTask == nil {
            hideTask = Task {
                try? await Task.sleep(for: Self.hideDelay)
                defer { hideTask = nil }
                guard !Task.isCancelled, !shouldBeVisible else { return }
                panel?.orderOut(nil)
                Log.indicator.info("hidden")
            }
        }
    }

    /// Follows the screen the user is typing on: the one holding the focused
    /// window, else the one under the mouse.
    private func presentOnActiveScreen() {
        let screens = NSScreen.screens
        let index = ActiveWindow.screenIndex(
            for: ActiveWindow.frame(), mouse: NSEvent.mouseLocation, screens: screens.map(\.frame)
        )
        guard let screen = index.map({ screens[$0] }) ?? NSScreen.main else {
            Log.indicator.error("no screen to present on")
            ErrorReporter.capture(message: "no screen to present the indicator on", category: "indicator")
            return
        }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 16)
        let panel = replacePanel()
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        Log.indicator.info("presented at \(origin.x), \(origin.y) on \(screen.localizedName)")
    }

    /// A fresh window for every presentation. When an app leaves full screen
    /// while the panel is hidden, the window server moves the panel to the
    /// desktop space for good: it no longer joins the other spaces, so the pill
    /// shows on the desktop but not over full-screen apps. Setting the collection
    /// behaviour again does not bring it back; only a new window does.
    private func replacePanel() -> IndicatorPanel {
        let old = panel
        let new = IndicatorPanel(size: Self.size)
        new.contentView = content
        panel = new
        old?.close()
        return new
    }
}

/// Never takes focus and lets clicks through, so `Cmd+V` reaches the user's field.
private final class IndicatorPanel: NSPanel {
    init(size: CGSize) {
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        // Closed and dropped by `RecordingIndicator`, not freed by AppKit.
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct IndicatorView: View {
    let controller: DictationController
    let recorder: AudioRecorder
    let state: RecordingIndicator.State

    private enum Mode: Equatable {
        case hidden, recording, processing
        case flash(RecordingIndicator.Flash)
    }

    private var mode: Mode {
        switch controller.phase {
        case .recording: .recording
        case .starting, .transcribing, .enhancing: .processing
        case .idle: state.flash.map(Mode.flash) ?? .hidden
        }
    }

    var body: some View {
        let hidden = mode == .hidden
        ZStack {
            content
                .transition(.blurReplace.combined(with: .scale(0.7)))
        }
        .frame(height: 32)
        .padding(.horizontal, 16)
        .foregroundStyle(.primary)
        .glassEffect(.regular, in: .capsule)
        .opacity(hidden ? 0 : 1)
        .scaleEffect(hidden ? 0.85 : 1, anchor: .bottom)
        .offset(y: hidden ? 10 : 0)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: mode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hidden:
            Color.clear.frame(width: 30)
        case .recording:
            LevelWaves(spectrum: recorder.spectrum)
                .id("recording")
        case .processing:
            Spinner().id("processing")
        case .flash(.copied):
            BouncingSymbol(name: "doc.on.clipboard", color: .white)
                .id("copied")
        case .flash(.failed(let message)):
            HStack(spacing: 8) {
                BouncingSymbol(name: "exclamationmark.triangle.fill", color: .orange)
                Text(message)
                    .font(.callout)
                    .lineLimit(1)
            }
            .id("failed")
        case .flash(.loading(let engine)):
            HStack(spacing: 8) {
                Spinner()
                Text("Chargement de \(engine.displayName)…")
                    .font(.callout)
                    .lineLimit(1)
            }
            .id("loading")
        }
    }
}

/// Plays the symbol's bounce once when it comes on screen.
private struct BouncingSymbol: View {
    let name: String
    let color: Color
    @State private var appeared = false

    var body: some View {
        Image(systemName: name)
            .foregroundStyle(color)
            .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
            .onAppear { appeared = true }
    }
}

/// Rotating arc shown while Claude corrects the text.
private struct Spinner: View {
    @State private var rotation: Angle = .zero

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(rotation)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
            }
    }
}

/// Three overlapping waves in the colours of the app icon, one per frequency
/// band: magenta for the lows, blue for the mids, cyan for the highs. Each sits
/// a little off centre, lows to the left and highs to the right, and the whole
/// group leans towards whichever end the voice favours.
private struct LevelWaves: View {
    let spectrum: VoiceSpectrum

    private struct Wave {
        let colors: [Color]
        /// Full periods across the width.
        let frequency: Double
        /// Radians per second; the sign sets the travel direction.
        let speed: Double
        let phase: Double
        /// Where the wave peaks at rest, as a fraction of the width.
        let center: Double
        let band: KeyPath<VoiceSpectrum, Float>
    }

    /// Drawn in order, so the magenta wave sits on top like in the icon.
    private static let waves = [
        Wave(
            colors: [Color(red: 0.08, green: 0.82, blue: 0.8), Color(red: 0.55, green: 0.96, blue: 0.92)],
            frequency: 2.0, speed: 6.6, phase: 2.6, center: 0.6, band: \.high
        ),
        Wave(
            colors: [Color(red: 0.1, green: 0.42, blue: 0.95), Color(red: 0.5, green: 0.7, blue: 1)],
            frequency: 1.5, speed: -4.3, phase: 1.3, center: 0.5, band: \.mid
        ),
        Wave(
            colors: [Color(red: 0.93, green: 0.09, blue: 0.78), Color(red: 1, green: 0.5, blue: 0.88)],
            frequency: 1.0, speed: 5.5, phase: 0, center: 0.4, band: \.low
        ),
    ]

    /// How far the tilt moves the peaks, as a fraction of the width.
    private static let lean = 0.15

    // The landing page's hero ribbon, scaled down: the motion gathers in the
    // middle third and both tails lie flat, the three peaks sit close together
    // and the waves cross each other more often. Same numbers as `hero` in
    // site/main.js.
    /// Sharpens the envelope; 1.5 is the icon's full-width swell.
    private static let focus = 5.0
    /// Pulls the three resting centres, and the lean, towards the middle.
    private static let spread = 0.4
    /// Extra periods across the width.
    private static let frequencyScale = 1.8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Self.waves.indices, id: \.self) { index in
                    let wave = Self.waves[index]
                    let amplitude = 1 + 11 * min(1, CGFloat(spectrum[keyPath: wave.band]))
                    let rest = 0.5 + (wave.center - 0.5) * Self.spread
                    let center = min(0.75, max(0.25, rest + Self.lean * Self.spread * Double(spectrum.tilt)))
                    let frequency = wave.frequency * Self.frequencyScale
                    let gradient = LinearGradient(
                        colors: [wave.colors[0], wave.colors[1], wave.colors[0]],
                        startPoint: .leading, endPoint: .trailing
                    )
                    let phase = wave.phase + time * wave.speed
                    WaveShape(amplitude: amplitude, center: center, frequency: frequency, phase: phase, focus: Self.focus, closed: true)
                        .fill(gradient)
                        .opacity(0.35)
                        .blur(radius: 3)
                    WaveShape(amplitude: amplitude, center: center, frequency: frequency, phase: phase, focus: Self.focus, closed: false)
                        .stroke(gradient, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                }
            }
            // Short enough to follow each syllable; the analyzer already
            // smooths the fall.
            .animation(.interactiveSpring(response: 0.07, dampingFraction: 0.75), value: spectrum)
        }
        // Wider than tall, like the ribbon, so the flat tails have room.
        .frame(width: 96, height: 26)
    }
}

/// One sine wave across the frame, flat at both ends and widest at `center`
/// (the middle, like the icon, when the voice is balanced). The amplitude and
/// the centre animate; the phase jumps with each frame.
nonisolated private struct WaveShape: Shape {
    var amplitude: CGFloat
    /// Where the envelope peaks, as a fraction of the width.
    var center: Double
    let frequency: Double
    let phase: Double
    /// Exponent on the envelope: higher gathers the wave in the middle and
    /// flattens both ends.
    let focus: Double
    /// Closes the wave back along the midline, for the glow under the stroke.
    let closed: Bool

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(amplitude, center) }
        set { (amplitude, center) = (newValue.first, newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midY = rect.midY
        let steps = Int(rect.width)
        // Warps the width so the envelope's peak lands on `center` while both
        // ends stay pinned to the edges.
        let warp = log(0.5) / log(center)
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let v = pow(u, warp)
            let envelope = pow(4 * v * (1 - v), focus)
            let y = midY - amplitude * envelope * sin(2 * .pi * frequency * u + phase)
            let point = CGPoint(x: rect.minX + u * rect.width, y: y)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: midY))
            path.addLine(to: CGPoint(x: rect.minX, y: midY))
            path.closeSubpath()
        }
        return path
    }
}
