import Foundation
import CoreBluetooth
import NitroModules

/**
 * The calls made while the central's state is still `.unknown`, waiting for its first real
 * state, in call order. On the manager's queue only.
 *
 * Requirement: the state is `.unknown` right after the central is created, and
 * CoreBluetooth reports the real state shortly after (centralManagerDidUpdateState). With
 * lazy init the first call is what creates the central, so it always meets `.unknown`.
 * Failing those calls with BluetoothInUnknownState would fail every early call for no
 * reason. They wait for the state instead, then run or fail with that state's error.
 * destroy() fails them with BluetoothManagerDestroyed.
 *
 * Two kinds of call wait here:
 * - `needPoweredOn`: a call that needs Bluetooth on (connect, startScan). Once the state is
 *   known it runs with the central, or fails with the state's error.
 * - `keepOrder`: a call that doesn't need Bluetooth on but must not overtake the calls
 *   ahead of it (disconnect: it must cancel a connect still waiting here, see
 *   BleCore.disconnect). Once the state is known it runs, whatever the state.
 */
final class PoweredOnWaiters {
    /// A call's place in line, for leaving it (`leave`).
    struct Ticket: Equatable {
        fileprivate let number: Int
    }

    /// One waiting call. Taken out of the line before it runs (`takeAll`).
    struct Waiter {
        fileprivate let ticket: Ticket
        fileprivate let needsPoweredOn: Bool
        fileprivate let run: (CBCentralManager) -> Void
        fileprivate let failure: (BleError) -> Void

        /// The state is known: runs the call, or fails it with the state's error when it needs Bluetooth on.
        func resume(on central: CBCentralManager) {
            if needsPoweredOn, let unavailable = unavailableError(central.state) {
                failure(unavailable)
            } else {
                run(central)
            }
        }

        /// Fails the call without running it (destroy).
        func fail(_ error: BleError) {
            failure(error)
        }
    }

    private var waiting: [Waiter] = []
    private var lastTicket = 0

    var isEmpty: Bool {
        return waiting.isEmpty
    }

    /// Queues a call that needs Bluetooth on. `failing` is what the call fails, at most once.
    @discardableResult
    func needPoweredOn<F: Failable>(failing: F, _ run: @escaping (CBCentralManager) -> Void) -> Ticket where F.Failure == BleError {
        return append(needsPoweredOn: true, failing: failing, run)
    }

    /// Queues a call that only keeps its place in line.
    @discardableResult
    func keepOrder<F: Failable>(failing: F, _ run: @escaping () -> Void) -> Ticket where F.Failure == BleError {
        return append(needsPoweredOn: false, failing: failing) { _ in run() }
    }

    /// Takes a call out of the line without running or failing it: a call that another one replaced (a scan start). No-op once it left.
    func leave(_ ticket: Ticket) {
        waiting.removeAll { $0.ticket == ticket }
    }

    /// Empties the line; the caller resumes or fails the calls, in call order, after its own state changes (collect, then fire).
    func takeAll() -> [Waiter] {
        let taken = waiting
        waiting = []
        return taken
    }

    private func append<F: Failable>(
        needsPoweredOn: Bool,
        failing: F,
        _ run: @escaping (CBCentralManager) -> Void
    ) -> Ticket where F.Failure == BleError {
        lastTicket += 1
        let ticket = Ticket(number: lastTicket)
        waiting.append(Waiter(ticket: ticket, needsPoweredOn: needsPoweredOn, run: run, failure: { failing.fail($0) }))
        return ticket
    }
}
