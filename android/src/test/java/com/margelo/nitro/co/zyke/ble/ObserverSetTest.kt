package com.margelo.nitro.co.zyke.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Unit tests for [ObserverSet]. */
class ObserverSetTest {
    private val observers = ObserverSet<Int>()
    private val log = mutableListOf<String>()

    private fun observe(id: Long, onValue: (Int) -> Unit = {}) =
        observers.add(id, Listener { value -> log += "$id got $value"; onValue(value) })

    @Test
    fun emitsToEveryObserverInRegistrationOrder() {
        observe(2)
        observe(1)
        observe(3)

        observers.emit(7)

        assertEquals(listOf("2 got 7", "1 got 7", "3 got 7"), log)
    }

    @Test
    fun removedObserverHearsNothingMore() {
        observe(1)
        observe(2)

        assertTrue(observers.remove(1))
        assertFalse(observers.remove(1))
        observers.emit(7)

        assertEquals(listOf("2 got 7"), log)
    }

    @Test
    fun observerRemovedDuringEmitIsSkipped() {
        observe(1) { observers.remove(2) }
        observe(2)
        observe(3)

        observers.emit(7)

        assertEquals(listOf("1 got 7", "3 got 7"), log)
    }

    @Test
    fun observerAddedDuringEmitWaitsForTheNextEmit() {
        observe(1) { value -> if (value == 7) observe(2) }

        observers.emit(7)
        observers.emit(8)

        assertEquals(listOf("1 got 7", "1 got 8", "2 got 8"), log)
    }

    @Test
    fun clearDuringEmitSilencesEveryObserver() {
        observe(1) { observers.clear() }
        observe(2)

        observers.emit(7)
        observers.emit(8)

        assertEquals(listOf("1 got 7"), log)
    }
}
