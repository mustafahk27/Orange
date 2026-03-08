import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    let onStart: () -> Void
    let onStop: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onDiagnostics: () -> Void

    @State private var isPointerInside = false
    @State private var hoverExpanded = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var collapseTask: Task<Void, Never>?
    @State private var pillBounce = false

    private var isExpanded: Bool {
        appState.overlayExpanded || hoverExpanded
    }

    private var isActive: Bool {
        appState.state != .idle
    }

    private var isProcessing: Bool {
        [SessionState.planning, .transcribing, .executing, .verifying].contains(appState.state)
    }

    var body: some View {
        ZStack {
            if isExpanded {
                expandedView
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                collapsedView
                    .transition(.opacity)
            }
        }
        .clipShape(NotchShape(expanded: isExpanded))
        .background(
            NotchShape(expanded: isExpanded)
                .fill(
                    LinearGradient(
                        colors: [Color.black, Color(white: 0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            NotchShape(expanded: isExpanded)
                .stroke(
                    isExpanded ? Color.orange.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .scaleEffect(pillBounce ? 1.03 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: pillBounce)
        .onHover { hovering in
            isPointerInside = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled, isPointerInside else { return }
                    hoverExpanded = true
                    OverlayWindow.shared.setMode(.expanded)
                }
            } else if !appState.overlayExpanded {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    guard !Task.isCancelled, !isPointerInside else { return }
                    hoverExpanded = false
                    OverlayWindow.shared.setMode(.collapsed)
                }
            }
        }
        .onChange(of: appState.state) { _, newState in
            collapseTask?.cancel()

            // Bounce the pill on state change
            if !isExpanded {
                pillBounce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    pillBounce = false
                }
            }

            let activeStates: Set<SessionState> = [
                .listening, .transcribing, .planning,
                .confirming, .executing, .verifying
            ]

            if activeStates.contains(newState) {
                appState.overlayExpanded = true
                OverlayWindow.shared.setMode(.expanded)
            } else if newState == .idle || newState == .done || newState == .canceled {
                collapseTask = Task {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    appState.overlayExpanded = false
                    if !isPointerInside {
                        hoverExpanded = false
                        OverlayWindow.shared.setMode(.collapsed)
                    }
                }
            }
        }
        .onDisappear {
            hoverTask?.cancel()
            collapseTask?.cancel()
        }
    }

    // MARK: - Collapsed Pill

    private var collapsedView: some View {
        HStack(spacing: 6) {
            if appState.state == .listening {
                AudioWaveformView(color: .red)
            } else {
                Circle()
                    .fill(colorForState(appState.state))
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: isActive ? colorForState(appState.state).opacity(0.6) : .clear,
                        radius: 4
                    )
            }
            if appState.state != .idle {
                Text(appState.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Expanded Content

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Progress bar for processing states
            if isProcessing {
                NotchProgressBar()
                    .padding(.horizontal, -16)
            }

            // Status bar
            HStack {
                if appState.state == .listening {
                    AudioWaveformView(color: .red)
                } else {
                    Circle()
                        .fill(colorForState(appState.state))
                        .frame(width: 10, height: 10)
                        .shadow(color: colorForState(appState.state).opacity(0.5), radius: 3)
                }
                Text(appState.statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Spacer()
                Text(appState.state.rawValue.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }

            // Transcript
            if !appState.transcript.isEmpty {
                Text(appState.transcript)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
            } else if !appState.partialTranscript.isEmpty {
                HStack(spacing: 4) {
                    PulsingDot()
                    Text(appState.partialTranscript)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                }
            }

            // Action plan
            if let plan = appState.actionPlan {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.summary ?? "Plan")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    ForEach(plan.actions.prefix(3), id: \.id) { action in
                        HStack(spacing: 4) {
                            Image(systemName: iconForAction(action.kind))
                                .font(.system(size: 9))
                            Text("\(action.kind.rawValue) \(action.target ?? action.text ?? "")")
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    if plan.actions.count > 3 {
                        Text("+\(plan.actions.count - 3) more")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }

            // Safety prompts
            if !appState.safetyPrompts.isEmpty {
                ForEach(appState.safetyPrompts) { prompt in
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text("\(prompt.title): \(prompt.message)")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.orange)
                }
            }

            // Planner events
            if !appState.plannerEvents.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(appState.plannerEvents.suffix(2)) { event in
                        Text(event.message)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }

            Spacer(minLength: 0)

            // Action buttons
            HStack(spacing: 8) {
                if appState.state == .confirming {
                    NotchButton(title: "Confirm", color: .green, action: onConfirm)
                    NotchButton(title: "Cancel", color: .gray, action: onCancel)
                } else if appState.state == .listening {
                    NotchButton(title: "Stop", color: .red, action: onStop)
                } else {
                    NotchButton(title: "Start", color: .orange, action: onStart)
                }

                Spacer()

                Button(action: onDiagnostics) {
                    Text("Diagnostics")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)

                Text("F8")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.top, NotchGeometry.hasNotch ? NotchGeometry.notchHeight + 4 : 10)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Helpers

    private func colorForState(_ state: SessionState) -> Color {
        switch state {
        case .listening: return .red
        case .planning, .transcribing, .executing, .verifying: return .orange
        case .done: return .green
        case .failed, .canceled: return .gray
        default: return .blue
        }
    }

    private func iconForAction(_ kind: ActionKind) -> String {
        switch kind {
        case .click: return "cursorarrow.click"
        case .doubleClick: return "cursorarrow.click.2"
        case .type: return "keyboard"
        case .keyCombo: return "command"
        case .scroll: return "scroll"
        case .openApp: return "app"
        case .runAppleScript: return "applescript"
        case .selectMenuItem: return "filemenu.and.selection"
        case .wait: return "clock"
        }
    }
}
