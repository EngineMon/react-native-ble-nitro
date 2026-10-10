@testable import BleNitroCore

/// The error type the tests specialize the core with, standing in for the glue's BleError.
struct TestError: Equatable, CustomStringConvertible {
    let code: String
    let message: String

    init(_ code: String, _ message: String = "") {
        self.code = code
        self.message = message
    }

    var description: String {
        return code
    }
}

/// What the tests' callbacks report, in order.
final class EventLog {
    private(set) var entries: [String] = []

    func add(_ entry: String) {
        entries.append(entry)
    }
}

/// A manual clock instead of a DispatchQueue: scheduled tasks run when `advance` moves
/// the clock past their due time, earliest first (enqueue order among equals).
final class FakeTimer: OperationTimer {
    private final class Task: ScheduledTask {
        let due: Int
        let run: () -> Void
        var cancelled = false

        init(due: Int, run: @escaping () -> Void) {
            self.due = due
            self.run = run
        }

        func cancel() {
            cancelled = true
        }
    }

    private var now = 0
    private var tasks: [Task] = []

    func schedule(_ task: @escaping () -> Void, delayMs: Int) -> any ScheduledTask {
        let scheduled = Task(due: now + delayMs, run: task)
        tasks.append(scheduled)
        return scheduled
    }

    func advance(_ ms: Int) {
        now += ms
        while let due = tasks.filter({ !$0.cancelled && $0.due <= now }).min(by: { $0.due < $1.due }) {
            tasks.removeAll { $0 === due }
            due.run()
        }
    }
}
