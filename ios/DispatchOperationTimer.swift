import Foundation

/**
 * The OperationTimer of one link's GattOperationQueue, on the manager's queue (Android's
 * counterpart runs on its Handler).
 *
 * Requirement: a burst of operations leaves nothing behind on the manager's queue. During
 * a burst of writes without response every operation arms a timeout and completes at once.
 * A DispatchWorkItem per operation, cancelled on completion, would stay scheduled on the
 * queue for its full 30 s anyway (cancelling a work item only makes it do nothing when it
 * runs), so a burst would pile up thousands of them. So the timer is one
 * DispatchSourceTimer, re-armed for each operation when it starts: the queue has at most
 * one operation in flight, so at most one task is armed.
 */
final class DispatchOperationTimer: OperationTimer {
    /// The one task the timer runs next, until it runs or is cancelled.
    private final class Armed: ScheduledTask {
        let deadline: DispatchTime
        let task: () -> Void
        weak var timer: DispatchOperationTimer?

        init(deadline: DispatchTime, task: @escaping () -> Void, timer: DispatchOperationTimer) {
            self.deadline = deadline
            self.task = task
            self.timer = timer
        }

        func cancel() {
            guard let timer, timer.armed === self else { return }
            timer.armed = nil
        }
    }

    private let source: DispatchSourceTimer
    private var armed: Armed?

    /// `queue`: the manager's queue, where the tasks run (the queue the GattOperationQueue is confined to).
    init(queue: DispatchQueue) {
        source = DispatchSource.makeTimerSource(queue: queue)
        source.setEventHandler { [weak self] in
            self?.fire()
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    /// Arms the timer for `task`, replacing a task armed before (the queue cancelled it: its operation finished).
    func schedule(_ task: @escaping () -> Void, delayMs: Int) -> any ScheduledTask {
        let next = Armed(deadline: .now() + .milliseconds(delayMs), task: task, timer: self)
        armed = next
        source.schedule(deadline: next.deadline)
        return next
    }

    private func fire() {
        // A firing already on its way when its task was cancelled and the timer re-armed
        // for the next one finds a later deadline: not its turn yet. The source fires
        // again at that deadline.
        guard let current = armed, DispatchTime.now() >= current.deadline else { return }
        armed = nil
        current.task()
    }
}
