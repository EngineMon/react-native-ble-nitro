import Foundation
import CoreBluetooth
import NitroModules

/**
 * One manager's BLE state and logic on CoreBluetooth: the central and its serial queue,
 * the links (one PeripheralLink per peripheral used, which owns its connect state machine
 * and, while up, a GattSession with the operation queue and notification hub), the scan
 * (BleScanner), the calls waiting for the first state (PoweredOnWaiters), state
 * restoration (StateRestoration), the state and connection-event observers, and destroy.
 * The facade (BleNitroBleManager) validates and copies inputs on the caller's thread,
 * wraps each callback once (CallbackGate) and calls in here. Android's counterpart is
 * BleCore.kt.
 *
 * Threading (NativeBleNitro.nitro.ts, section "Threading"):
 * - `queue` owns everything here, in the links and in the sessions: CoreBluetooth
 *   delivers every central and peripheral delegate call on it, and nothing else touches
 *   the state.
 * - Every method the facade calls hops onto the queue by itself. Methods answering
 *   through a callback post (`perform`) and return at once, so requests run in call order
 *   and a callback never runs inline on the caller's thread, not even when the call fails
 *   at once. Synchronous getters wait for the queue (`query`), run inline when already on
 *   it (a C++ callback calling back in, where `queue.sync` would deadlock), and never
 *   invoke a user callback: a C++ caller blocked in one may hold a lock its callbacks take.
 * - Only the core's callback wrappers (Reply, Once, Listener, and Failable for what may
 *   only be failed) reach this class, so every completion is delivered at most once and
 *   no raw user callback is held below the facade.
 * - Collect, then fire: every state transition finishes before any callback of it runs,
 *   so a C++ callback calling a synchronous getter inline sees the new state (e.g. a link
 *   that went down is not connected any more when its queued operations fail).
 *
 * Lifetime: closures capture this object, never the facade, so the facade can go away
 * while work is queued. The facade's deinit and dispose() call destroy(); its posted
 * teardown keeps this object alive until it ran. The central's delegate and every link
 * hold it weakly, so nothing here forms a cycle.
 */
final class BleCore: LinkOwner {

    /**
     * The ids of observer registrations posted to the queue and not applied yet.
     * Thread-safe: filled on the registering caller's thread, emptied on the queue.
     *
     * Requirement (NativeBleNitro.nitro.ts, unsubscribeFromStateChange and
     * unsubscribeFromConnectionEvents): once the synchronous unsubscribe returned, the
     * listener is never called. An unsubscribe that runs inline on the queue (a C++
     * callback, handed the id by another thread) can run while the registration of that id
     * is still waiting behind the current task; it then finds no observer, and the
     * registration would add it afterwards, for good. So such an unsubscribe takes the id
     * out of this set, and a posted registration applies only if its id is still here.
     * Only registrations in flight are held, so the set stays bounded however often an id
     * is unsubscribed.
     */
    private final class PendingRegistrations: @unchecked Sendable {
        /// Guards `ids`.
        private let lock = NSLock()
        private var ids: Set<Int64> = []

        func insert(_ id: Int64) {
            lock.lock()
            ids.insert(id)
            lock.unlock()
        }

        /// Removes `id`; whether it was there (its registration is still wanted).
        func take(_ id: Int64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return ids.remove(id) != nil
        }
    }

    private let queue = DispatchQueue(label: "co.zyke.ble.nitro")
    /**
     * Present only on `queue`. A getter called from code already running there (a C++
     * callback calling back in) runs inline, where `queue.sync` would deadlock.
     */
    private let queueKey = DispatchSpecificKey<Bool>()

    /// Every callback the facade handed in was wrapped through this gate; destroy() closes it.
    let gate: CallbackGate
    private let pendingRegistrations = PendingRegistrations()

    private var restoreIdentifier: String?
    private var central: CBCentralManager?
    /// CBCentralManager.delegate is weak.
    private var centralDelegate: BleCentralManagerDelegate?
    /// The central was created with a restore identifier.
    private var restoresState = false
    private let restoration: StateRestoration

    private let stateObservers = ObserverSet<BLEState>()
    private let connectionObservers = ObserverSet<ConnectionEvent>()
    private let waiters = PoweredOnWaiters()
    private let scanner = BleScanner()
    /**
     * The startScan waiting in `waiters` for the first state. A later startScan or
     * stopScan replaces it: it leaves the line, and neither starts nor reports anything (a
     * replaced scan's callback gets nothing more).
     */
    private var waitingScanStart: PoweredOnWaiters.Ticket?
    /**
     * The link of every peripheral this manager connected or was handed (restoration), by
     * device id. Kept as long as the peripheral object is valid, so a peripheral never gets
     * a second delegate: until the central's state drops below poweredOff (see
     * bluetoothBecameUnavailable) or destroy. Bounded by the peripherals actually used.
     */
    private var links: [String: PeripheralLink] = [:]

    /**
     * destroy() was called; its teardown may not have run yet. From then on no new OS work
     * starts (no central is created, no connect, scan or GATT request is issued), every
     * call fails with BluetoothManagerDestroyed (`perform`), synchronous getters return
     * their empty value (`query`), and the central's delegate calls are dropped
     * (BleCentralManagerDelegate). LinkOwner: the links ask it too, so a GATT request
     * queued before destroy() never reaches the OS. Also on the queue before the teardown
     * ran: the gate is closed on destroy()'s caller thread, before the teardown is posted.
     */
    var isDestroying: Bool {
        return !gate.isOpen
    }

    /**
     * `createCentral` false (BLENitroLazyInit): the central, and with it the permission
     * prompt and state restoration, waits for the first call that needs it, or lazyInit().
     * `gate` is the gate the facade wrapped `restoreCallback` (and every later callback)
     * through.
     */
    init(restoreIdentifier: String?, restoreCallback: Once<[BLEDevice]>?, gate: CallbackGate, createCentral: Bool) {
        self.restoreIdentifier = restoreIdentifier
        self.restoration = StateRestoration(callback: restoreCallback)
        self.gate = gate
        queue.setSpecific(key: queueKey, value: true)
        if createCentral {
            queue.async { [self] in _ = ensureCentral() }
        }
    }

    // MARK: - The queue

    private var isOnQueue: Bool {
        return DispatchQueue.getSpecific(key: queueKey) != nil
    }

    /// Runs `work` on the queue and returns its result.
    private func sync<T>(_ work: () -> T) -> T {
        if isOnQueue {
            return work()
        }
        return queue.sync(execute: work)
    }

    /**
     * A synchronous getter: `work` on the queue, or `empty` once destroy() was called
     * (NativeBleNitro.nitro.ts, section "After destroy()": synchronous methods return their empty
     * value, also before the posted teardown ran).
     */
    private func query<T>(_ empty: T, _ work: () -> T) -> T {
        guard !isDestroying else { return empty }
        return sync { isDestroying ? empty : work() }
    }

    /**
     * Every call that answers through a callback: posts `task` to the queue, after
     * everything requested before. Once destroy() was called, `failing` fails with
     * BluetoothManagerDestroyed instead and the task never runs, so no OS work starts after
     * destroy() even for a call posted before it (NativeBleNitro.nitro.ts, section
     * "After destroy()"). This is the one place that rule is checked for the facade's calls; the
     * same check on Android is BleCore.kt's `perform`. "Destroyed" wins over every other
     * error, input errors included (`reject`).
     */
    private func perform<F: Failable>(failing: F, _ task: @escaping () -> Void) where F.Failure == BleError {
        queue.async { [self] in
            if isDestroying {
                failing.fail(destroyedError())
            } else {
                task()
            }
        }
    }

    /**
     * Fails `failing` with `error` (an input the facade rejected), from the queue like every
     * callback, after everything requested before; with BluetoothManagerDestroyed instead
     * once destroy() was called.
     */
    func reject<F: Failable>(_ failing: F, _ error: BleError) where F.Failure == BleError {
        perform(failing: failing) { failing.fail(error) }
    }

    /// Completes `reply` with success from the queue (an unsubscribe of an id this manager never handed out).
    func complete(_ reply: Reply<Void, BleError>) {
        perform(failing: reply) { reply.succeed() }
    }

    /**
     * Registers observer `id`: inline when already on the queue, else posted. Inline on the
     * queue so that an unsubscribe right after it, which runs inline there too, finds it;
     * posted from elsewhere, so it runs after every call made before it and before any
     * unsubscribe made after it returned on another thread (FIFO). An unsubscribe that runs
     * inline on the queue before the posted registration cancels it (PendingRegistrations).
     * Never fires anything, so running inline can't call back into the caller.
     */
    private func register(id: Int64, _ work: @escaping () -> Void) {
        pendingRegistrations.insert(id)
        let run: () -> Void = { [self] in
            // After destroy a registration still returns its id but never fires
            // (NativeBleNitro.nitro.ts, section "After destroy()").
            guard pendingRegistrations.take(id), !isDestroying else { return }
            work()
        }
        if isOnQueue {
            run()
        } else {
            queue.async(execute: run)
        }
    }

    /// Unregisters observer `id` of `observers`, or cancels its registration still in flight. Synchronous.
    private func unregister<Value>(id: Int64, from observers: ObserverSet<Value>) {
        sync {
            if !observers.remove(id: id) {
                _ = pendingRegistrations.take(id)
            }
        }
    }

    // MARK: - The central

    /// The central, created on first use. Nil once destroy() was called: no central is created, and none is handed out.
    private func ensureCentral() -> CBCentralManager? {
        guard !isDestroying else { return nil }
        if let central {
            return central
        }
        var options: [String: Any] = [:]
        if let identifier = restoreIdentifier {
            options[CBCentralManagerOptionRestoreIdentifierKey] = identifier
        }
        let delegate = BleCentralManagerDelegate(core: self)
        let central = CBCentralManager(delegate: delegate, queue: queue, options: options.isEmpty ? nil : options)
        self.centralDelegate = delegate
        self.central = central
        self.restoresState = restoreIdentifier != nil
        return central
    }

    /// LinkOwner: the central a link may start or cancel a connection through; nil once destroy() was called.
    var liveCentral: CBCentralManager? {
        return isDestroying ? nil : central
    }

    /**
     * Runs `run` with the central once Bluetooth is on, or fails `failing` with why it
     * can't: destroyed, or the state's error. While the state is still `.unknown` the call
     * waits in `waiters` for the first real state; the returned ticket is its place there.
     */
    @discardableResult
    private func withPoweredOnCentral<F: Failable>(
        failing: F,
        _ run: @escaping (CBCentralManager) -> Void
    ) -> PoweredOnWaiters.Ticket? where F.Failure == BleError {
        guard let central = ensureCentral() else {
            failing.fail(destroyedError())
            return nil
        }
        if central.state == .unknown {
            return waiters.needPoweredOn(failing: failing, run)
        }
        if let unavailable = unavailableError(central.state) {
            failing.fail(unavailable)
        } else {
            run(central)
        }
        return nil
    }

    // MARK: - Lazy init, restoration, state

    /**
     * The CBCentralManager restore identifier. It takes effect when the central is created
     * (right after init, or at the first call with lazy init); setting it later changes
     * nothing, which is logged (NativeBleNitro.nitro.ts, restoreStateIdentifier).
     */
    var restoreStateIdentifier: String? {
        get { return sync { restoreIdentifier } }
        set {
            sync {
                if central != nil && newValue != restoreIdentifier {
                    bleLog("restoreStateIdentifier was set after the central was created; it takes effect only for a new manager")
                }
                restoreIdentifier = newValue
            }
        }
    }

    func lazyInit() {
        queue.async { [self] in _ = ensureCentral() }
    }

    /// The restored peripherals reach `callback` once; a report made before it was registered waits for it.
    func setRestoreCallback(_ callback: Once<[BLEDevice]>) {
        queue.async { [self] in
            // Listeners registered after destroy() are never kept (the teardown released the others).
            guard !isDestroying else { return }
            restoration.setCallback(callback)
        }
    }

    /// Unknown once destroy() was called. With lazy init this creates the central.
    func state() -> BLEState {
        return query(.unknown) { ensureCentral()?.state.bleState ?? .unknown }
    }

    /// iOS doesn't let apps turn Bluetooth on: fails with BluetoothStateChangeFailed, as ble-plx's enable() does there.
    func requestBluetoothEnable(_ reply: Reply<Void, BleError>) {
        reject(reply, bluetoothStateChangeFailedError())
    }

    /**
     * The listener hears every later state change, until removed. Registering creates the
     * central (lazy init): without one there is no state to hear about.
     */
    func addStateObserver(id: Int64, _ listener: Listener<BLEState>) {
        register(id: id) { [self] in
            stateObservers.add(id: id, listener)
            _ = ensureCentral()
        }
    }

    /// Synchronous: once it returns, the listener is never called again.
    func removeStateObserver(id: Int64) {
        unregister(id: id, from: stateObservers)
    }

    func addConnectionObserver(id: Int64, _ listener: Listener<ConnectionEvent>) {
        register(id: id) { [self] in connectionObservers.add(id: id, listener) }
    }

    /// Synchronous: once it returns, the listener is never called again.
    func removeConnectionObserver(id: Int64) {
        unregister(id: id, from: connectionObservers)
    }

    // MARK: - Scanning

    /**
     * Starts a scan, replacing the running one, whose callback gets nothing more (see
     * BleScanner.start). A start that can't reach the OS fails through
     * `callbacks.startFailure` (Bluetooth not on, destroyed); a running scan that
     * Bluetooth ends reports through `callbacks.ended`. The facade rejects invalid service
     * UUIDs before this, so such a start never touches the running scan
     * (NativeBleNitro.nitro.ts, startScan).
     */
    func startScan(services: [CBUUID], rssiThreshold: Double?, allowDuplicates: Bool, callbacks: ScanCallbacks) {
        perform(failing: callbacks.startFailure) { [self] in
            leaveWaitingScanStart()
            waitingScanStart = withPoweredOnCentral(failing: callbacks.startFailure) { [self] central in
                waitingScanStart = nil
                scanner.start(
                    on: central,
                    services: services,
                    rssiThreshold: rssiThreshold,
                    allowDuplicates: allowDuplicates,
                    callbacks: callbacks
                )
            }
        }
    }

    /**
     * Returns whether a scan was running (false once destroy() was called: the teardown
     * stops it). A start still waiting for the first state is cancelled too.
     */
    func stopScan() -> Bool {
        return query(false) {
            leaveWaitingScanStart()
            return scanner.stop(on: central)
        }
    }

    func isScanning() -> Bool {
        return query(false) { scanner.isScanning }
    }

    private func leaveWaitingScanStart() {
        if let ticket = waitingScanStart {
            waitingScanStart = nil
            waiters.leave(ticket)
        }
    }

    // MARK: - Devices

    /**
     * NativeBleNitro.nitro.ts, getConnectedDevices, with the same filter meaning as on
     * Android (ServiceFilter): this manager's links that are up and whose discovered
     * services pass the filter (all of them for `.any`), and for `.anyOf` the peripherals
     * the system holds connected that offer one of the services
     * (retrieveConnectedPeripherals), maybe for another app: connect() makes them this
     * manager's. isConnected tells which are this manager's links.
     */
    func connectedDevices(_ filter: ServiceFilter) -> [BLEDevice] {
        return query([]) {
            var devices: [String: BLEDevice] = [:]
            for (deviceId, link) in links where link.isUp && filter.admits(link.peripheral) {
                devices[deviceId] = BLEDevice.known(link.peripheral, isConnected: true)
            }
            if case .anyOf(let services) = filter, !services.isEmpty, let central, central.state == .poweredOn {
                for peripheral in central.retrieveConnectedPeripherals(withServices: services) {
                    let deviceId = peripheral.identifier.uuidString
                    if devices[deviceId] == nil {
                        devices[deviceId] = BLEDevice.known(peripheral, isConnected: links[deviceId]?.isUp ?? false)
                    }
                }
            }
            return Array(devices.values)
        }
    }

    /// The link of `peripheral`, created on first use: a peripheral has one delegate for as long as it is valid.
    private func link(for peripheral: CBPeripheral) -> PeripheralLink {
        let deviceId = peripheral.identifier.uuidString
        if let link = links[deviceId] {
            return link
        }
        let link = PeripheralLink(peripheral: peripheral, queue: queue, owner: self)
        links[deviceId] = link
        return link
    }

    /// This manager's link to the device, when it is up (connect() brought it up or adopted it, and nothing is taking it down).
    private func upLink(_ id: UUID) -> PeripheralLink? {
        guard let link = links[id.uuidString], link.isUp else { return nil }
        return link
    }

    /// The session of this manager's link to the device, when it is up: what every GATT request and getter works on.
    private func upSession(_ id: UUID) -> GattSession? {
        return links[id.uuidString]?.upSession
    }

    /// Releases every peripheral this manager holds: the links (their delegates) and the scan results.
    private func forgetPeripherals() {
        links.values.forEach { $0.release() }
        links.removeAll()
        scanner.forgetPeripherals()
    }

    // MARK: - Connection

    /**
     * NativeBleNitro.nitro.ts, connect. Waits for the first Bluetooth state when it is
     * still unknown (PoweredOnWaiters); the deadline counts from when the connect starts,
     * so a permission prompt the user hasn't answered yet doesn't use it up. The device is
     * found among this manager's links, the scan results, and the peripherals the system
     * knows (retrievePeripherals); DeviceNotFound otherwise. The link decides the rest
     * (PeripheralLink.connect): succeed at once on a link that is up, adopt a restored
     * one, wait for one going down, take over an attempt the system keeps pending.
     */
    func connect(_ id: UUID, deadline: GattRules.ConnectDeadline, reply: Reply<Void, BleError>, onDisconnect: Once<ConnectionEvent>?) {
        perform(failing: reply) { [self] in
            withPoweredOnCentral(failing: reply) { [self] central in
                let deviceId = id.uuidString
                guard let peripheral = links[deviceId]?.peripheral
                    ?? scanner.discoveredPeripheral(deviceId)
                    ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
                    return reply.fail(deviceNotFoundError(deviceId))
                }
                link(for: peripheral).connect(deadline: deadline, reply: reply, onDisconnect: onDisconnect)
            }
        }
    }

    /**
     * NativeBleNitro.nitro.ts, disconnect. Without a link of this manager it fails with
     * DeviceNotConnected; the link decides the rest (PeripheralLink.disconnect).
     *
     * A connect still waiting for the first Bluetooth state has neither a link nor a
     * pending connect yet, so a disconnect made after it waits in the same line
     * (PoweredOnWaiters.keepOrder): it runs right after that connect started (or failed),
     * whatever the state, and cancels it like any pending connect. Answering
     * DeviceNotConnected instead would let the device connect after the caller asked for
     * it to be dropped.
     */
    func disconnect(_ id: UUID, reply: Reply<Void, BleError>) {
        perform(failing: reply) { [self] in
            if waiters.isEmpty {
                disconnectNow(id, reply: reply)
            } else {
                waiters.keepOrder(failing: reply) { [self] in disconnectNow(id, reply: reply) }
            }
        }
    }

    private func disconnectNow(_ id: UUID, reply: Reply<Void, BleError>) {
        guard let link = links[id.uuidString] else {
            return reply.fail(notConnectedError(id.uuidString))
        }
        link.disconnect(reply: reply)
    }

    func isConnected(_ id: UUID) -> Bool {
        return query(false) { upLink(id) != nil }
    }

    // MARK: - Operations

    /**
     * Runs `run` with the session of this manager's link to the device, or fails
     * `failing`: destroyed, or no link of this manager is up (DeviceNotConnected). A link
     * that disconnect() or an operation timeout is taking down, or that CoreBluetooth
     * dropped before its didDisconnectPeripheral ran, is not up (isConnected() is false
     * for it already), so a new call fails with DeviceNotConnected, as on Android; only
     * operations queued before the close fail with DeviceDisconnected
     * (NativeBleNitro.nitro.ts, section "When a link goes down").
     */
    private func withSession<F: Failable>(_ id: UUID, failing: F, _ run: @escaping (GattSession) -> Void) where F.Failure == BleError {
        perform(failing: failing) { [self] in
            guard let session = upSession(id) else {
                return failing.fail(notConnectedError(id.uuidString))
            }
            run(session)
        }
    }

    /// The ATT MTU in effect on this manager's link; nil when it isn't up (NativeBleNitro.nitro.ts, getMtu).
    func mtu(_ id: UUID) -> Double? {
        return query(nil) { upSession(id).map { Double($0.attMtu) } }
    }

    /**
     * iOS negotiates the MTU by itself; the request reports the one in effect
     * (NativeBleNitro.nitro.ts, requestMTU). `mtu` must still be an integer in 23...517
     * (GattRules.validMtuRequest, DeviceMTUChangeFailed otherwise), as on Android, checked
     * after the link like the other input checks of an operation (DeviceNotConnected comes
     * first). Queued like every operation of the link, so one made behind a discovery
     * reads the MTU after it.
     */
    func requestMtu(_ id: UUID, mtu: Double, reply: Reply<Double, BleError>) {
        withSession(id, failing: reply) { session in
            guard GattRules.validMtuRequest(mtu: mtu) != nil else {
                return reply.fail(invalidMtuError(mtu))
            }
            session.requestMtu(reply: reply)
        }
    }

    /// Android only: completes without error while the link is up (NativeBleNitro.nitro.ts, requestConnectionPriority).
    func requestConnectionPriority(_ id: UUID, reply: Reply<Void, BleError>) {
        withSession(id, failing: reply) { _ in reply.succeed() }
    }

    func readRSSI(_ id: UUID, reply: Reply<Double, BleError>) {
        withSession(id, failing: reply) { $0.readRSSI(reply: reply) }
    }

    func discoverServices(_ id: UUID, reply: Reply<Void, BleError>) {
        withSession(id, failing: reply) { $0.discoverServices(reply: reply) }
    }

    /// Full lowercase 128-bit UUIDs; empty when the link isn't up or nothing is discovered.
    func services(_ id: UUID) -> [String] {
        return query([]) {
            upLink(id)?.peripheral.services?.map { $0.uuid.fullUUIDString } ?? []
        }
    }

    /// Full lowercase 128-bit UUIDs; empty when the link isn't up or the service or its characteristics aren't discovered.
    func characteristics(_ id: UUID, service: CBUUID) -> [String] {
        return query([]) {
            let match = upLink(id)?.peripheral.services?.first { $0.uuid == service }
            return match?.characteristics?.map { $0.uuid.fullUUIDString } ?? []
        }
    }

    /// Nil when the link isn't up or the lookup the operations make fails (NativeBleNitro.nitro.ts, getCharacteristicProperties).
    func characteristicProperties(_ id: UUID, key: CharacteristicKey) -> CharacteristicProperties? {
        return query(nil) {
            upSession(id)?.lookup(key).map { CharacteristicProperties(declaredBy: $0) }
        }
    }

    func read(_ id: UUID, key: CharacteristicKey, reply: Reply<ArrayBuffer, BleError>) {
        withSession(id, failing: reply) { $0.read(key, reply: reply) }
    }

    /// `data` is the caller's bytes, copied by the facade before the call returned.
    func write(_ id: UUID, key: CharacteristicKey, data: Data, withResponse: Bool, reply: Reply<ArrayBuffer, BleError>) {
        withSession(id, failing: reply) { $0.write(key, data: data, withResponse: withResponse, reply: reply) }
    }

    /**
     * The facade allocated `subscriptionId` and calls this before returning it, so the
     * subscription is posted ahead of any unsubscribe of that id (FIFO queue). After
     * destroy or without a link its completion fails, and neither of its listeners ever
     * fires.
     */
    func subscribe(
        _ subscriptionId: Int64,
        device id: UUID,
        key: CharacteristicKey,
        onValue: Listener<Data>,
        completion: Reply<Void, BleError>,
        onEnded: Once<BleError>?
    ) {
        withSession(id, failing: completion) { session in
            session.subscribe(id: subscriptionId, key: key, onValue: onValue, completion: completion, onEnded: onEnded)
        }
    }

    /**
     * Ends a subscription wherever it is. There is no index from subscription id to link
     * (one more thing to keep in step with every link's close): each link is asked, also
     * one going down (its subscriptions last until its close), and the one that has the id
     * takes over `reply`. An id of a link that went down (its subscriptions ended with
     * it), of a link replaced since, or never handed out succeeds: ids are never reused,
     * so an old id can't hit a newer subscription.
     */
    func unsubscribe(_ subscriptionId: Int64, reply: Reply<Void, BleError>) {
        perform(failing: reply) { [self] in
            // The link that has the id takes over `reply`.
            if links.values.contains(where: { $0.unsubscribe(id: subscriptionId, reply: reply) }) {
                return
            }
            reply.succeed()
        }
    }

    /**
     * NativeBleNitro.nitro.ts, isSubscribedToCharacteristic: an active (completed, not
     * ended) subscription of this manager exists on the characteristic. Asked of the link
     * whether it is up or going down (PeripheralLink.isSubscribed), as on Android: after
     * disconnect(), active subscriptions keep receiving until the link is down, and its
     * close ends them.
     */
    func isSubscribed(_ id: UUID, key: CharacteristicKey) -> Bool {
        return query(false) { links[id.uuidString]?.isSubscribed(key) ?? false }
    }

    // MARK: - LinkOwner

    /// A link's Connected, Disconnected or ServicesChanged event, emitted after the link's own callbacks of it.
    func connectionEvent(_ event: ConnectionEvent) {
        connectionObservers.emit(event)
    }

    // MARK: - Destroy

    /**
     * Closes the gate on the caller's thread (every listener is silent and every
     * completion fails with BluetoothManagerDestroyed from then on, CallbackGate), posts the
     * teardown and returns. destroy() may be called from any thread (deinit, dispose(), JS,
     * C++, a callback on the queue), and the completions the teardown fails must run on
     * the queue, never inline on the caller (a C++ caller may hold a lock they take). Only
     * the call that closed the gate posts the teardown.
     *
     * Barrier (NativeBleNitro.nitro.ts, section "After destroy()": a C++ caller may release its
     * listener state once destroy() returned): the gate is a check before each delivery,
     * so a listener that passed it just before the gate closed may still be running on the
     * queue. Called off the queue, destroy() waits for an empty task posted ahead of the
     * teardown: once it ran, every task that could have passed the gate has returned. It
     * waits for that task only, not for the teardown. On the queue there is nothing to wait
     * for: the caller is the running task. So, as for the synchronous getters
     * (NativeBleNitro.nitro.ts, section "Threading"), a caller must not hold a lock its BLE
     * callbacks take while it calls destroy(). JS callbacks never make it wait on the JS
     * thread: Nitro dispatches them asynchronously.
     */
    func destroy() {
        let closedNow = gate.close()
        if isOnQueue {
            if closedNow {
                queue.async { [self] in tearDown() }
            }
            return
        }
        let barrier = DispatchSemaphore(value: 0)
        queue.async { barrier.signal() }
        if closedNow {
            queue.async { [self] in tearDown() }
        }
        barrier.wait()
    }

    /**
     * First the OS resources: the central's delegate is cleared (no more central calls),
     * the scan stops, every connection is cancelled and the central is released, so a new
     * manager created right after (a JS reload) can take the same restore identifier.
     * Then, after every state change (collect, then fire): every link closes
     * (PeripheralLink.closeAll), failing its pending connect, operations, subscription
     * completions and disconnect() calls with BluetoothManagerDestroyed, and the calls
     * waiting for the first state fail with it too. The links close silently: their ended
     * and disconnect callbacks and Disconnected events are listeners, silent since
     * destroy() was called, and so is the running scan. Last, the observers go.
     */
    private func tearDown() {
        if let central {
            central.delegate = nil
            _ = scanner.stop(on: central)
            // CoreBluetooth only accepts the call while powered on (it logs API misuse
            // otherwise); below that, the links are already down.
            if central.state == .poweredOn {
                for link in links.values where link.peripheral.state != .disconnected {
                    central.cancelPeripheralConnection(link.peripheral)
                }
            }
        }
        central = nil
        centralDelegate = nil
        waitingScanStart = nil
        let waiting = waiters.takeAll()
        restoration.discard()
        PeripheralLink.closeAll(Array(links.values), .destroyed) {
            forgetPeripherals()
        }
        waiting.forEach { $0.fail(destroyedError()) }
        stateObservers.clear()
        connectionObservers.clear()
    }

    // MARK: - CBCentralManagerDelegate (on the queue, only while not destroying: BleCentralManagerDelegate)

    /**
     * When Bluetooth leaves the powered-on state, every link and the scan end
     * (bluetoothBecameUnavailable). Then, in this order: the links' callbacks, the scan's
     * end, the restoration report, the calls waiting for a known state, and the state
     * observers. A callback of one link that reads another link's state inline
     * (isConnected, getConnectedDevices) sees it down already.
     *
     * A callback fired here may call destroy() inline. Each waiting call is checked again
     * before it runs, so none starts OS work after that (it fails with
     * BluetoothManagerDestroyed); the gate silences the rest.
     */
    func centralDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let unavailable = unavailableError(state)
        var scanEnded: Once<BleError>?
        if let unavailable {
            scanEnded = bluetoothBecameUnavailable(state, unavailable)
        } else if state == .poweredOn {
            scanner.centralPoweredOn(central)
        }
        let waiting = state == .unknown ? [] : waiters.takeAll()
        if let scanEnded, let unavailable {
            scanEnded.fire(unavailable)
        }
        // CoreBluetooth calls willRestoreState before the first state update when it
        // restores anything (Apple: the first method invoked on a restoration launch).
        // Getting here with nothing reported means there was nothing to restore: the
        // callback gets an empty list, once (StateRestoration).
        if restoresState {
            restoration.report([])
        }
        for waiter in waiting {
            if isDestroying {
                waiter.fail(destroyedError())
            } else {
                waiter.resume(on: central)
            }
        }
        stateObservers.emit(state.bleState)
    }

    /**
     * Bluetooth left the powered-on state, which ends every link and the scan without a
     * didDisconnectPeripheral for each. As in ble-plx (RxBluetoothKit fails whatever needs
     * a powered-on central with the state's error), pending connects fail with the state's
     * error, and links that were up drop like any other (DeviceDisconnected). A
     * didDisconnectPeripheral arriving after this finds nothing left to report.
     * CoreBluetooth ended every attempt with the radio, so no late report of a cancelled
     * one is owed (the links forget their cancelled attempts).
     *
     * At poweredOff the peripheral objects stay valid, so their links (and restored
     * peripherals) are kept. Below it (resetting, unauthorized, unsupported, unknown),
     * CoreBluetooth invalidates every CBPeripheral the central handed out; they "must be
     * retrieved or discovered again" (CBCentralManager.h, centralManagerDidUpdateState:).
     * They are forgotten then, so the next connect or request retrieves a valid one
     * instead of waiting forever on a dead object.
     *
     * Every link's state, the forgetting and the scan's end are done before the first link
     * callback runs (PeripheralLink.closeAll), and the scan's `ended` event is returned for
     * the caller to fire after the links' callbacks. A running scan's end is an event, so
     * it stays silent once destroy() was called (CallbackGate.scanEnded).
     */
    private func bluetoothBecameUnavailable(_ state: CBManagerState, _ unavailable: BleError) -> Once<BleError>? {
        var scanEnded: Once<BleError>?
        PeripheralLink.closeAll(Array(links.values), .bluetoothUnavailable(unavailable)) {
            if state.rawValue < CBManagerState.poweredOff.rawValue {
                forgetPeripherals()
            }
            scanEnded = scanner.abandon()
        }
        return scanEnded
    }

    /**
     * Restored peripherals get their link here, so CoreBluetooth's calls about them reach
     * this manager. They become this manager's links through connect(), which adopts a
     * connected one at once (firing Connected) and takes over a pending one
     * (PeripheralLink.connect); until then requests on them fail with DeviceNotConnected.
     * In the report, isConnected tells whether the system restored the peripheral
     * connected, the link iOS kept for this app and that connect() adopts.
     *
     * Notifications of characteristics the device still notifies on, arriving before a
     * subscription exists on the adopted link, are dropped: there is no subscriber to give
     * them to, and buffering them would hand a new subscriber values of an earlier
     * session. A subscribe on such a characteristic writes no CCCD (it is on already) and
     * gets every value from then on.
     */
    func centralWillRestoreState(_ state: [String: Any]) {
        let devices = StateRestoration.peripherals(state).map { peripheral -> BLEDevice in
            _ = link(for: peripheral)
            return BLEDevice.known(peripheral, isConnected: peripheral.state == .connected)
        }
        if StateRestoration.restoresScan(state) {
            scanner.restore()
        }
        restoration.report(devices)
    }

    /// isConnected is computed here, on the queue, from this manager's link (BLEDevice.isConnected).
    func centralDidDiscover(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        scanner.didDiscover(peripheral, advertisementData: advertisementData, rssi: rssi) { deviceId in
            links[deviceId]?.isUp ?? false
        }
    }

    func centralDidConnect(_ peripheral: CBPeripheral) {
        links[peripheral.identifier.uuidString]?.didConnect()
    }

    func centralDidFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier.uuidString]?.didFailToConnect(error: error)
    }

    func centralDidDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        links[peripheral.identifier.uuidString]?.didDisconnect(error: error)
    }
}
