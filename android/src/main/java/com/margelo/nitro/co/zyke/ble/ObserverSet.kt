package com.margelo.nitro.co.zyke.ble

/**
 * The listeners of one kind of manager event (Bluetooth state, connection
 * events), keyed by their registration id from [IdSource].
 *
 * Requirements:
 * - Several observers at once, each removed by its own id: one JS listener
 *   or C++ client unregistering must not silence another.
 * - [emit] calls the observers in registration order.
 * - [emit] walks the observers registered when it started. One removed while
 *   the emit runs (by an earlier observer's callback, or by teardown code
 *   running inside it) and not called yet is skipped: after [remove] or
 *   [clear] returned, that observer never hears from this set again. One
 *   added while the emit runs waits for the next emit.
 * - A throwing observer doesn't stop the others ([Listener] catches).
 *
 * The list is copy-on-write: [add], [remove] and [clear] replace it, so an
 * emit can walk the list it started with without copying it; registrations
 * are rare next to events. Not thread-safe: confined to the manager's
 * executor.
 */
internal class ObserverSet<T> {
    private class Entry<T>(val id: Long, val listener: Listener<T>) {
        /** Cleared on removal, so an emit already walking an older list skips it. */
        var registered = true
    }

    private var entries: List<Entry<T>> = emptyList()

    /** Registers [listener] under [id], a fresh [IdSource] id (a duplicate is a programming error). */
    fun add(id: Long, listener: Listener<T>) {
        require(entries.none { it.id == id }) { "Observer id $id is already registered" }
        entries = entries + Entry(id, listener)
    }

    /** Unregisters [id]. Returns false when it isn't registered (never was, or already removed). */
    fun remove(id: Long): Boolean {
        val entry = entries.firstOrNull { it.id == id } ?: return false
        entry.registered = false
        entries = entries - entry
        return true
    }

    fun emit(value: T) {
        val snapshot = entries
        for (i in snapshot.indices) {
            val entry = snapshot[i]
            if (entry.registered) entry.listener.emit(value)
        }
    }

    fun clear() {
        for (entry in entries) entry.registered = false
        entries = emptyList()
    }
}
