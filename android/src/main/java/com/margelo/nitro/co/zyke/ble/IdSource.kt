package com.margelo.nitro.co.zyke.ble

import java.util.concurrent.atomic.AtomicLong

/**
 * Hands out the ids of subscriptions and listener registrations.
 *
 * Requirements:
 * - An id is never reused within the process, across every manager: a stale
 *   id kept by JS or C++ after its registration ended (unsubscribing twice,
 *   unsubscribing after a reload created a new manager) must never name a
 *   newer registration, so removing it is a harmless no-op. A single object
 *   makes this hold by construction; there is no second counter to mix up.
 * - Ids start at 1: 0 stays free as an obviously-invalid value.
 * - Thread-safe: the facade allocates an id on the caller's thread so it can
 *   return it synchronously, before the registration runs on the manager's
 *   executor.
 *
 * Facades hand ids to JS as a Nitro `number` (a Double), exact up to 2^53,
 * which one process never reaches.
 */
internal object IdSource {
    private val last = AtomicLong(0)

    fun next(): Long = last.incrementAndGet()
}
