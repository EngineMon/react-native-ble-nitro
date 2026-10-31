import XCTest
@testable import BleNitroCore

/// A serial queue under the test's control: posted tasks run in order when `run` is called.
private final class FakeQueue {
    private var tasks: [() -> Void] = []

    func post(_ task: @escaping () -> Void) {
        tasks.append(task)
    }

    func run() {
        while !tasks.isEmpty {
            tasks.removeFirst()()
        }
    }
}

/**
 * A manager core as BleCore uses the tenancy: it attaches in its first task, destroy()
 * closes its gate on the caller's thread and posts its teardown, which runs once and
 * detaches it. Every teardown logs who takes the central's calls while it runs: a
 * teardown must never run while another core does.
 */
private final class FakeCore: HostTenant {
    let name: String
    private let tenancy: HostTenancy<FakeCore, String>
    private let queue: FakeQueue
    private let log: EventLog
    /// The gate is closed (BleCore.isDestroying).
    private(set) var isDestroying = false
    private var tornDown = false
    /// Runs inside the teardown, as a completion the teardown fails may run code inline.
    var duringTearDown: (() -> Void)?

    init(_ name: String, tenancy: HostTenancy<FakeCore, String>, queue: FakeQueue, log: EventLog) {
        self.name = name
        self.tenancy = tenancy
        self.queue = queue
        self.log = log
    }

    /// The manager is created: its first task attaches it (BleCore.init, CentralHost.attach).
    func create() {
        queue.post { [self] in
            if let restored = tenancy.attach(self) {
                log.add("\(name) restored \(restored)")
            }
            if tenancy.isAttached(self) {
                log.add("\(name) attached")
            }
        }
    }

    /// destroy(): the gate closes, and only the call that closed it posts the teardown.
    func destroy() {
        guard !isDestroying else { return }
        closeGate()
        postTearDown()
    }

    /// The first half of destroy(), on its caller's thread.
    func closeGate() {
        isDestroying = true
    }

    /// The second half of destroy().
    func postTearDown() {
        queue.post { [self] in tearDown() }
    }

    func supersede() {
        log.add("\(name) superseded")
        closeGate()
        tearDown()
    }

    private func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        log.add("\(name) torn down (calls reach \(tenancy.live?.name ?? "nobody"))")
        tenancy.detach(self)
        duringTearDown?()
    }
}

/// Unit tests for `HostTenancy`: which core gets a central's calls as managers come and go on one host, in every order a JS reload can produce.
final class HostTenancyTests: XCTestCase {
    private let tenancy = HostTenancy<FakeCore, String>()
    private let queue = FakeQueue()
    private let log = EventLog()

    private func core(_ name: String) -> FakeCore {
        return FakeCore(name, tenancy: tenancy, queue: queue, log: log)
    }

    /// willRestoreState, as CentralHost forwards it.
    private func restore(_ state: String) {
        if let live = tenancy.restore(state) {
            log.add("\(live.name) restored \(state)")
        }
    }

    // MARK: - The restored state

    func testRestoreBeforeAnyCoreIsKeptForTheFirstCoreOnly() {
        restore("P")
        let a = core("A")
        a.create()
        queue.run()
        a.destroy()
        queue.run()
        let b = core("B")
        b.create()
        queue.run()

        XCTAssertEqual(log.entries, ["A restored P", "A attached", "A torn down (calls reach nobody)", "B attached"])
    }

    func testRestoreAfterTheAttachReachesTheLiveCoreAndIsNotKept() {
        let a = core("A")
        a.create()
        queue.run()
        restore("P")
        let b = core("B")
        b.create()
        queue.run()

        XCTAssertEqual(log.entries, ["A attached", "A restored P", "A superseded", "A torn down (calls reach nobody)", "B attached"])
    }

    func testRestoreWhileTheCoreIsBeingDestroyedIsKeptForTheNext() {
        let a = core("A")
        a.create()
        queue.run()
        a.destroy()
        restore("P")
        let b = core("B")
        b.create()
        queue.run()

        XCTAssertEqual(log.entries, ["A attached", "A torn down (calls reach nobody)", "B restored P", "B attached"])
    }

    func testASecondKeptRestoreReplacesTheFirstAndNeitherIsDeliveredTwice() {
        restore("P")
        restore("Q")
        let a = core("A")
        a.create()
        queue.run()
        a.destroy()
        queue.run()
        let b = core("B")
        b.create()
        queue.run()

        XCTAssertEqual(log.entries, ["A restored Q", "A attached", "A torn down (calls reach nobody)", "B attached"])
    }

    // MARK: - Calls between attaches (a pending connect completing before, during, after)

    func testCallsReachOnlyTheLiveCoreBeforeDuringAndAfterASupersede() {
        let a = core("A")
        a.create()
        XCTAssertNil(tenancy.live, "before the first core's first task, calls are dropped")
        queue.run()
        XCTAssertTrue(tenancy.live === a)

        let b = core("B")
        b.create()
        queue.run()

        XCTAssertTrue(tenancy.live === b)
        // During the supersede (A's teardown) no core takes calls.
        XCTAssertEqual(log.entries, ["A attached", "A superseded", "A torn down (calls reach nobody)", "B attached"])
    }

    // MARK: - JS reload orders

    func testReloadWithTheNewManagerBeforeTheOldOnesDeinit() {
        let a = core("A")
        a.create()
        queue.run()
        let b = core("B")
        b.create()
        queue.run()
        a.destroy()
        queue.run()

        XCTAssertTrue(tenancy.live === b)
        XCTAssertEqual(log.entries, ["A attached", "A superseded", "A torn down (calls reach nobody)", "B attached"])
    }

    func testReloadWithTheOldManagersDeinitBeforeTheNewManager() {
        let a = core("A")
        a.create()
        queue.run()
        a.destroy()
        queue.run()
        let b = core("B")
        b.create()
        queue.run()

        XCTAssertTrue(tenancy.live === b)
        XCTAssertEqual(log.entries, ["A attached", "A torn down (calls reach nobody)", "B attached"])
    }

    func testReloadWithTheNewAttachPostedBetweenTheOldGateAndItsTeardown() {
        let a = core("A")
        a.create()
        queue.run()
        a.closeGate()
        let b = core("B")
        b.create()
        a.postTearDown()
        queue.run()

        // A was still attached, so B's attach tore it down first; its own posted teardown found nothing left.
        XCTAssertTrue(tenancy.live === b)
        XCTAssertEqual(log.entries, ["A attached", "A superseded", "A torn down (calls reach nobody)", "B attached"])
    }

    // MARK: - Destroy twice, superseded cores, two live managers

    func testAnotherTeardownOfASupersededCoreLeavesItsSuccessorAttached() {
        let a = core("A")
        a.create()
        queue.run()
        let b = core("B")
        b.create()
        queue.run()

        tenancy.detach(a)

        XCTAssertTrue(tenancy.isAttached(b))
        XCTAssertTrue(tenancy.live === b)
    }

    func testTheNewestOfSeveralLiveManagersWins() {
        let a = core("A")
        let b = core("B")
        let c = core("C")
        a.create()
        b.create()
        c.create()
        queue.run()

        XCTAssertTrue(a.isDestroying)
        XCTAssertTrue(b.isDestroying)
        XCTAssertTrue(tenancy.live === c)
        XCTAssertEqual(log.entries, [
            "A attached",
            "A superseded", "A torn down (calls reach nobody)", "B attached",
            "B superseded", "B torn down (calls reach nobody)", "C attached",
        ])
    }

    // MARK: - Cores destroyed before they attach

    func testCoreDestroyedBeforeItsFirstTaskNeverAttachesNorSupersedes() {
        let a = core("A")
        a.create()
        queue.run()
        let b = core("B")
        b.create()
        b.destroy()
        queue.run()

        XCTAssertTrue(tenancy.live === a)
        XCTAssertEqual(log.entries, ["A attached", "B torn down (calls reach A)"])
    }

    func testCoreDestroyedBeforeItsFirstTaskLeavesTheKeptRestoreForTheNext() {
        restore("P")
        let b = core("B")
        b.create()
        b.destroy()
        queue.run()
        let c = core("C")
        c.create()
        queue.run()

        XCTAssertEqual(log.entries, ["B torn down (calls reach nobody)", "C restored P", "C attached"])
    }

    func testCoreDestroyedByTheTeardownItSupersedesDoesNotAttach() {
        let a = core("A")
        a.create()
        queue.run()
        a.closeGate()
        restore("P")
        let b = core("B")
        b.create()
        a.duringTearDown = { b.destroy() }
        a.postTearDown()
        queue.run()

        XCTAssertNil(tenancy.live)
        XCTAssertFalse(tenancy.isAttached(b))

        let c = core("C")
        c.create()
        queue.run()

        XCTAssertEqual(log.entries, [
            "A attached",
            "A superseded", "A torn down (calls reach nobody)",
            "B torn down (calls reach nobody)",
            "C restored P", "C attached",
        ])
    }

    // MARK: - Memory

    func testTheTenancyDoesNotKeepItsCoreAlive() {
        var a: FakeCore? = core("A")
        weak var attached = a
        a?.create()
        queue.run()

        a = nil

        XCTAssertNil(attached)
        XCTAssertNil(tenancy.live)
    }
}
