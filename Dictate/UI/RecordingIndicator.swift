import AppKit
import Observation
import SwiftUI

/// Small pill at the bottom centre of the screen, visible only while `fn` is
/// held and while the dictation is processed.
final class RecordingIndicator {
    enum Flash: Equatable {
        case copied(raw: Bool)
        case rawPasted
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

    private static let size = CGSize(width: 120, height: 44)

    init(controller: DictationController, recorder: AudioRecorder) {
        self.controller = controller
        panel = IndicatorPanel(size: Self.size)
        panel.contentView = NSHostingView(
            rootView: IndicatorView(controller: controller, recorder: recorder, state: state)
        )
        observePhase()
    }

    /// Briefly shows how a finished dictation ended, when it needs attention.
    func show(_ outcome: DictationOutcome) {
        let flash: Flash? = switch outcome {
        case .copied(let raw): .copied(raw: raw)
        case .pasted(raw: true): .rawPasted
        case .failed: .failed
        case .pasted(raw: false), .discarded: nil
        }
        flashTask?.cancel()
        state.flash = flash
        guard flash != nil else { return }
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            state.flash = nil
        }
    }

    private func observePhase() {
        withObservationTracking {
            _ = controller.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.phase == .recording {
                    self.flashTask?.cancel()
                    self.state.flash = nil
                    self.presentOnActiveScreen()
                }
                self.observePhase()
            }
        }
    }

    /// Follows the screen the user is working on, found from the mouse position.
    private func presentOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + 16)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        Log.app.info("indicator shown at \(String(describing: origin), privacy: .public), visible: \(self.panel.isVisible)")
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
        case hidden, recording, transcribing, enhancing
        case flash(RecordingIndicator.Flash)
    }

    private var mode: Mode {
        switch controller.phase {
        case .recording: .recording
        case .transcribing: .transcribing
        case .enhancing: .enhancing
        case .idle: state.flash.map(Mode.flash) ?? .hidden
        }
    }

    var body: some View {
        content
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(Color.black.opacity(0.78), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
            .opacity(mode == .hidden ? 0 : 1)
            .scaleEffect(mode == .hidden ? 0.85 : 1)
            .animation(.spring(duration: 0.25), value: mode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hidden:
            Color.clear.frame(width: 30)
        case .recording:
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBars(level: CGFloat(recorder.level))
            }
        case .transcribing:
            Image(systemName: "waveform")
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers)
        case .enhancing:
            Spinner()
        case .flash(.copied(let raw)):
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard").foregroundStyle(.white)
                if raw { Circle().fill(.orange).frame(width: 6, height: 6) }
            }
        case .flash(.rawPasted):
            HStack(spacing: 6) {
                Image(systemName: "text.cursor").foregroundStyle(.white)
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
        case .flash(.failed):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Rotating arc shown while Claude corrects the text.
private struct Spinner: View {
    @State private var rotation: Angle = .zero

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(rotation)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
            }
    }
}

private struct LevelBars: View {
    let level: CGFloat
    private let weights: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: 4 + 14 * min(1, level * weights[index]))
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
