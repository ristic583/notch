import AppKit
import Observation

/// Pomodoro phases; a plain countdown has no phase.
enum PomodoroPhase: Equatable {
    case work
    case shortBreak
    case longBreak

    var title: String {
        switch self {
        case .work: "Focus"
        case .shortBreak: "Break"
        case .longBreak: "Long break"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .work: 25 * 60
        case .shortBreak: 5 * 60
        case .longBreak: 15 * 60
        }
    }

    var symbol: String {
        switch self {
        case .work: "brain.head.profile"
        case .shortBreak, .longBreak: "cup.and.saucer"
        }
    }
}

/// Countdown shown in the pill.
@MainActor
@Observable
final class TimerService {
    static let presets: [TimeInterval] = [60, 5 * 60, 10 * 60, 25 * 60]

    private(set) var endDate: Date?
    private(set) var remaining: TimeInterval = 0
    private(set) var total: TimeInterval = 0
    /// Set while a pomodoro run is going; nil for a plain countdown.
    private(set) var phase: PomodoroPhase?
    /// Focus rounds finished in this run (every fourth break is a long one).
    private(set) var completedRounds = 0

    /// Fired once when the countdown reaches zero.
    @ObservationIgnored var onFinished: (() -> Void)?
    /// Fired when the countdown starts or stops.
    @ObservationIgnored var onRunningChanged: ((Bool) -> Void)?

    @ObservationIgnored private var ticker: Timer?

    var isRunning: Bool { endDate != nil }

    var formattedRemaining: String {
        let seconds = Int(remaining.rounded(.up))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Starts a pomodoro run: focus, break, focus … until cancelled.
    func startPomodoro() {
        completedRounds = 0
        start(PomodoroPhase.work.duration, phase: .work)
    }

    func start(_ duration: TimeInterval, phase: PomodoroPhase? = nil) {
        self.phase = phase
        total = duration
        remaining = duration
        let wasRunning = isRunning
        endDate = Date().addingTimeInterval(duration)
        if !wasRunning { onRunningChanged?(true) }
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func add(_ seconds: TimeInterval) {
        guard let endDate else { return }
        total += seconds
        self.endDate = endDate.addingTimeInterval(seconds)
        tick()
    }

    func cancel() {
        let wasRunning = isRunning
        phase = nil
        completedRounds = 0
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        remaining = 0
        if wasRunning { onRunningChanged?(false) }
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        guard remaining <= 0 else { return }

        let finishedPhase = phase
        let rounds = completedRounds
        cancel()
        NSSound(named: "Glass")?.play()
        onFinished?()

        // A pomodoro run rolls straight into the next phase.
        guard let finishedPhase else { return }
        switch finishedPhase {
        case .work:
            let next: PomodoroPhase = (rounds + 1) % 4 == 0 ? .longBreak : .shortBreak
            start(next.duration, phase: next)
            completedRounds = rounds + 1
        case .shortBreak, .longBreak:
            start(PomodoroPhase.work.duration, phase: .work)
            completedRounds = rounds
        }
    }
}
