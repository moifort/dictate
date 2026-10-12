import AppKit
import Observation
import SwiftUI

/// Small pill at the bottom centre of the screen, visible only while `fn` is
/// held and while the dictation is processed.
final class RecordingIndicator {
    enum Flash: Equatable {
        /// No field had focus: the text waits in the pasteboard.
        case copied
        case failed
    }

    @Observable
    final class State {
        var flash: Flash?
    }

    private let controller: DictationController
    private let state = State()
    private let panel: IndicatorPanel
    private var flashTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?

    private static let size = CGSize(width: 140, height: 56)
    /// Long enough for the fade-out in `IndicatorView` to finish.
    private static let hideDelay: Duration = .milliseconds(450)

    init(controller: DictationController, recorder: AudioRecorder) {
        self.controller = controller
        panel = IndicatorPanel(size: Self.size)
        panel.contentView = NSHostingView(
            rootView: IndicatorView(controller: controller, recorder: recorder, state: state)
        )
        observeVisibility()
    }

    /// Briefly shows how a finished dictation ended, when it needs attention.
    func show(_ outcome: DictationOutcome) {
        let flash: Flash? = switch outcome {
        case .copied: .copied
        case .failed: .failed
        case .pasted, .discarded: nil
        }
        flashTask?.cancel()
        state.flash = flash
        guard flash != nil else { return }
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
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
                if phase == .recording, state.flash != nil {
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
                panel visible: \(self.panel.isVisible), on screen: \(self.panel.occlusionState.contains(.visible))
                """)
            if panel.isVisible {
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
                panel.orderOut(nil)
                Log.indicator.info("hidden")
            }
        }
    }

    /// Follows the screen the user is working on, found from the mouse position.
    private func presentOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            Log.indicator.error("no screen to present on")
            return
        }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 16)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        Log.indicator.info("presented at \(origin.x), \(origin.y) on \(screen.localizedName)")
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
        case .transcribing, .enhancing: .processing
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
            HStack(spacing: 10) {
                PulsingDot()
                LevelBars(level: CGFloat(recorder.level))
            }
            .id("recording")
        case .processing:
            Spinner().id("processing")
        case .flash(.copied):
            BouncingSymbol(name: "doc.on.clipboard", color: .white)
                .id("copied")
        case .flash(.failed):
            BouncingSymbol(name: "exclamationmark.triangle.fill", color: .orange)
                .id("failed")
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

/// Red recording dot with a soft expanding ring.
private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(.red.opacity(0.7), lineWidth: 1.5)
                    .scaleEffect(pulsing ? 2.4 : 1)
                    .opacity(pulsing ? 0 : 1)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
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

/// Thin white bars following the microphone level, each with its own slight
/// sway so they never move as one block.
private struct LevelBars: View {
    let level: CGFloat
    private let weights: [CGFloat] = [0.5, 0.75, 0.9, 1, 0.9, 0.75, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(weights.indices, id: \.self) { index in
                    let sway = 0.8 + 0.2 * sin(time * 11 + Double(index) * 1.7)
                    Capsule()
                        .fill(.white)
                        .frame(width: 2, height: 3 + 23 * min(1, level * weights[index] * sway))
                }
            }
        }
        .frame(height: 26)
        .animation(.interactiveSpring(response: 0.1, dampingFraction: 0.7), value: level)
    }
}
