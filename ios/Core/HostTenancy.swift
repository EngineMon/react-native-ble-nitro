/// What a host (CentralHost) needs of the manager core attached to it (BleCore).
protocol HostTenant: AnyObject {
    /// destroy() was called: the tenant takes no more of the central's calls.
    var isDestroying: Bool { get }

    /**
     * A newer tenant takes the host (`HostTenancy.attach`): the tenant is torn down now,
     * inline, on the host's queue, and detaches itself (`HostTenancy.detach`) before this
     * returns. Called at most once per tenant, and only while it is attached.
     */
    func supersede()
}

/**
 * Which manager core a central reports to: at most one tenant at a time, and what the
 * central reported while it had none that the next one needs. CentralHost forwards
 * every delegate call of its central through this; BleCore is the tenant.
 *
 * Requirements:
 * - One tenant per central. A host with a restore identifier is shared by every manager
 *   made with that identifier, for the life of the process; the manager of a JS reload
 *   is made while, or after, the old one goes away, in no fixed order. A tenant
 *   attaching while another one is still attached supersedes it (`attach`): the old one
 *   is torn down first, inline, so its teardown (stopping the scan, cancelling its
 *   connections, clearing its peripherals' delegates) runs before anything of the new
 *   one and can never undo what the new one starts on the same central.
 * - "Still attached" means its teardown hasn't run, not that it is live: destroy()
 *   closes the gate on its caller's thread and posts the teardown after, so a new
 *   tenant's attach can run between the two. That tenant is torn down at the attach
 *   too; its own posted teardown then finds nothing left to do.
 * - The restored state (willRestoreState's dictionary) is a one-time handoff:
 *   CoreBluetooth calls it once, right after the central is made, and the restored
 *   peripherals are what a relaunch is for. Made while no live tenant is attached (the
 *   central was made at app launch, or the tenant is being destroyed), it is kept for
 *   the next tenant that attaches, and only that one. Keeping it also keeps the restored
 *   peripherals retained, so the connections the system kept pending for them stay
 *   pending until a tenant takes them over.
 * - Every other call is dropped while no live tenant is attached: it is about a
 *   peripheral or scan of no live tenant (a destroyed tenant's are ended by its
 *   teardown), and a tenant reads a peripheral's state from the peripheral when it takes
 *   it on. The host replays the current state at the attach.
 * - A tenant destroyed before it attached (its first task runs after destroy()) never
 *   attaches: it supersedes nobody and takes no restored state.
 *
 * Memory: the tenant is held weakly (the tenant holds its host, which must not hold it
 * back). A tenant that went away without detaching (impossible while BleCore's posted
 * teardown keeps it alive until it ran) simply stops counting as attached.
 *
 * Not thread-safe: confined to the host's serial queue, which also runs `supersede`.
 */
final class HostTenancy<Tenant: HostTenant, RestoredState> {
    private weak var tenant: Tenant?
    /**
     * The restored state, made while no live tenant was attached; for the next one, which
     * takes it (it is released then). CoreBluetooth restores once per central, so a second
     * one doesn't come; one that did would replace this one, so the older one is released
     * and none is ever delivered twice.
     */
    private var keptRestore: RestoredState?

    /// The tenant that takes the central's calls: attached and not destroying.
    var live: Tenant? {
        guard let tenant, !tenant.isDestroying else { return nil }
        return tenant
    }

    /// Whether `candidate` is the attached tenant (destroying or not).
    func isAttached(_ candidate: Tenant) -> Bool {
        return tenant === candidate
    }

    /**
     * `newTenant` takes the central's calls from now on. An attached tenant is superseded
     * first (see the class comment). Returns the restored state kept for it, which the
     * caller hands it before any other call (CoreBluetooth's order: the restored state,
     * then the state update). Nothing happens for a tenant already destroying, or already
     * attached.
     *
     * The superseded tenant's teardown fails its pending completions inline, and one of
     * them may destroy the new tenant (a C++ caller reacting to the old manager's end).
     * The new tenant then doesn't attach either: nobody is attached, and the kept state
     * stays kept.
     */
    func attach(_ newTenant: Tenant) -> RestoredState? {
        guard !newTenant.isDestroying, tenant !== newTenant else { return nil }
        if let previous = tenant {
            previous.supersede()
            guard !newTenant.isDestroying else { return nil }
        }
        tenant = newTenant
        let restored = keptRestore
        keptRestore = nil
        return restored
    }

    /// `leaving` gets no more calls (its teardown). Ignored unless it is the attached tenant: a superseded one never detaches its successor.
    func detach(_ leaving: Tenant) {
        if tenant === leaving {
            tenant = nil
        }
    }

    /**
     * willRestoreState: the live tenant to hand `state` to, or nil when it is kept for
     * the next tenant instead. A live tenant handed a second one reports only the first
     * (StateRestoration).
     */
    func restore(_ state: RestoredState) -> Tenant? {
        guard let live else {
            keptRestore = state
            return nil
        }
        return live
    }

    /**
     * The kept restored state names objects that are no longer valid (CoreBluetooth
     * invalidated every peripheral it handed out, and ended their connects): it is
     * released, and the next tenant reports nothing restored.
     */
    func dropKeptRestore() {
        keptRestore = nil
    }
}
