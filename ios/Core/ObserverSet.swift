/**
 * The listeners of one kind of event (Bluetooth state changes, connection events),
 * each registered under its own id; `emit` calls them in registration order.
 *
 * Requirement: any number of independent observers (one per JS listener, plus C++
 * callers) register and unregister on their own, so removing one never affects another.
 *
 * `emit` iterates a snapshot taken when it starts, because a listener may add or remove
 * observers while it runs:
 * - an observer added during an emit is first called by the next emit;
 * - an observer removed during an emit and not yet called is skipped: once `remove`
 *   returned, the observer is never called again.
 *
 * Not thread-safe and not Sendable: confined to the manager's serial queue, which also
 * runs every listener.
 */
final class ObserverSet<Value> {
    private struct Entry {
        let id: Int64
        let listener: Listener<Value>
    }

    /// In registration order. An array: a manager has a handful of observers at most.
    private var entries: [Entry] = []

    /**
     * Registers `listener` under `id`. Ids come from `IdSource`, so `id` is new; a
     * registered id is a programming error (the earlier listener would silently never
     * fire again).
     */
    func add(id: Int64, _ listener: Listener<Value>) {
        precondition(!contains(id), "Observer id \(id) is already registered")
        entries.append(Entry(id: id, listener: listener))
    }

    /// Unregisters the observer with `id`. Returns false when no observer has that id.
    @discardableResult
    func remove(id: Int64) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Calls every registered observer with `value`, in registration order.
    func emit(_ value: Value) {
        for entry in entries where contains(entry.id) {
            entry.listener.emit(value)
        }
    }

    /// Unregisters every observer.
    func clear() {
        entries.removeAll()
    }

    private func contains(_ id: Int64) -> Bool {
        return entries.contains { $0.id == id }
    }
}
