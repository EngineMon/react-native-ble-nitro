package com.margelo.nitro.co.zyke.ble

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [NotificationHub]. Characteristics are strings, values ints.
 * A CCCD operation is simulated by its plan and its finish, in the order the
 * link's operation queue runs them.
 */
class NotificationHubTest {
    private val logs = CoreLogCapture()
    private val hub = NotificationHub<String, Int, TestError> { TestError("OPERATIONCANCELLED", it) }
    private val log = mutableListOf<String>()
    private val lost = TestError("DEVICEDISCONNECTED", "link lost")
    private val servicesChanged = TestError("SERVICESNOTDISCOVERED", "services changed")
    private val writeFailed = TestError("CHARACTERISTICNOTIFYCHANGEFAILED", "CCCD write failed")

    @After
    fun stopCapturing() = logs.close()

    private fun subscribe(
        id: Long,
        key: String = "k",
        onValue: (Int) -> Unit = {},
        onCompleted: () -> Unit = {},
    ) = hub.add(
        id,
        key,
        Listener { value ->
            log += "$id got $value"
            onValue(value)
        },
        Reply { error, _ ->
            log += if (error == null) "$id subscribed" else "$id failed ${error.code}"
            onCompleted()
        },
        Once { error -> log += "$id ended ${error.code}" },
    )

    private fun subscribeRequest(id: Long, key: String = "k") = CccdRequest.Subscribe<String, TestError>(id, key)

    /** Plans subscriber [id]'s subscribe operation (Android: no OS notifying state). */
    private fun planSubscribe(id: Long, key: String = "k", osNotifying: Boolean? = null) =
        hub.plan(subscribeRequest(id, key), osNotifying)

    /** An unsubscribe request whose reply logs its outcome. */
    private fun unsubscribeRequest(key: String = "k") = CccdRequest.Unsubscribe<String, TestError>(
        key,
        Reply { error, _ -> log += if (error == null) "unsubscribe of $key succeeded" else "unsubscribe of $key failed ${error.code}" },
    )

    /** Plans an unsubscribe operation of [key]. */
    private fun planUnsubscribe(key: String = "k", osNotifying: Boolean? = null) =
        hub.plan(unsubscribeRequest(key), osNotifying)

    /** Runs subscriber [id]'s subscribe operation to success, writing what its plan asks for. */
    private fun subscribeSucceeds(id: Long, key: String = "k") {
        val request = subscribeRequest(id, key)
        hub.finish(request, hub.plan(request, osNotifying = null), error = null, cause = null)
    }

    /** Subscribes [id] and runs its subscribe operation to success. */
    private fun activeSubscriber(id: Long, key: String = "k") {
        subscribe(id, key)
        subscribeSucceeds(id, key)
    }

    @Test
    fun valuesReachPendingAndActiveSubscribersOfTheirCharacteristic() {
        activeSubscriber(1)
        subscribe(2)
        activeSubscriber(3, key = "other")
        log.clear()

        hub.deliver("k") { 7 }

        assertEquals(listOf("1 got 7", "2 got 7"), log)
    }

    @Test
    fun everySubscriberGetsItsOwnValueAndNoneIsMadeWithoutAReceiver() {
        var made = 0
        val makeValue = { ++made * 10 }
        subscribe(1, onValue = { hub.remove(2) })
        subscribe(2)
        activeSubscriber(3)
        subscribe(4, key = "left")
        hub.remove(4)
        log.clear()

        hub.deliver("k", makeValue)
        hub.deliver("left", makeValue)
        hub.deliver("unknown", makeValue)

        // One value per receiver, none for subscriber 2 (removed during the
        // delivery), the characteristic whose last subscriber left, or one
        // never subscribed.
        assertEquals(listOf("1 got 10", "2 failed OPERATIONCANCELLED", "3 got 20"), log)
        assertEquals(2, made)
    }

    @Test
    fun firstSubscribeWritesOnAndLaterOnesDoNot() {
        subscribe(1)
        val first = planSubscribe(1)
        assertTrue(first.write)
        assertTrue(first.enable)
        hub.finish(subscribeRequest(1), first, error = null, cause = null)

        subscribe(2)
        val second = planSubscribe(2)

        assertFalse(second.write)
        assertTrue(second.enable)
    }

    @Test
    fun subscribeOperationWritesOnlyForItsOwnPresentSubscriber() {
        subscribe(1)
        subscribe(2)
        hub.remove(1)

        val ofRemoved = planSubscribe(1)
        val ofPresent = planSubscribe(2)

        assertFalse(ofRemoved.write)
        assertTrue(ofRemoved.enable)
        assertTrue(ofPresent.write)
    }

    @Test
    fun subscribeRemovedBeforeItsOperationRanWritesNothingEitherWay() {
        subscribe(1)
        hub.remove(1)

        val subscribePlan = planSubscribe(1)
        val unsubscribePlan = planUnsubscribe()

        assertFalse(subscribePlan.write)
        assertFalse(subscribePlan.enable)
        assertFalse(unsubscribePlan.write)
    }

    @Test
    fun planForASubscriberOfAnotherCharacteristicWritesNothing() {
        subscribe(1, key = "a")

        val plan = planSubscribe(1, key = "b")

        assertFalse(plan.write)
        assertFalse(plan.enable)
        assertTrue(planSubscribe(1, key = "a").write)
    }

    @Test
    fun unsubscribeWritesOffOnlyAfterTheLastSubscriber() {
        activeSubscriber(1)
        activeSubscriber(2)

        hub.remove(1)
        val notLast = planUnsubscribe()
        hub.remove(2)
        val request = unsubscribeRequest()
        val last = hub.plan(request, osNotifying = null)
        hub.finish(request, last, error = null, cause = null)
        val afterOff = planUnsubscribe()

        assertFalse(notLast.write)
        assertTrue(notLast.enable)
        assertTrue(last.write)
        assertFalse(last.enable)
        assertFalse(afterOff.write)
        assertEquals("unsubscribe of k succeeded", log.last())
    }

    @Test
    fun failedWriteMakesTheStateUnknownSoTheNextOperationWritesEitherWay() {
        activeSubscriber(1)
        hub.remove(1)
        val unsubscribe = unsubscribeRequest()
        hub.finish(unsubscribe, hub.plan(unsubscribe, osNotifying = null), error = writeFailed, cause = null)

        subscribe(2)
        val on = planSubscribe(2)
        hub.finish(subscribeRequest(2), on, error = writeFailed, cause = null)
        val offAgain = planUnsubscribe()

        assertTrue(on.write)
        assertTrue(offAgain.write)
    }

    @Test
    fun osNotifyingStateReplacesTheTrackedState() {
        subscribe(1)
        val alreadyNotifying = planSubscribe(1, osNotifying = true)
        hub.finish(subscribeRequest(1), alreadyNotifying, error = null, cause = null)
        hub.remove(1)
        val stoppedByTheOs = planUnsubscribe(osNotifying = false)
        val stillNotifying = planUnsubscribe(osNotifying = true)

        assertFalse(alreadyNotifying.write)
        assertFalse(stoppedByTheOs.write)
        assertTrue(stillNotifying.write)
    }

    @Test
    fun settleSuccessActivatesOnlyItsOwnSubscriber() {
        subscribe(1)
        subscribe(2)

        subscribeSucceeds(1)

        assertEquals(listOf("1 subscribed"), log)
        assertTrue(hub.isSubscribed("k"))
        hub.endAll(lost)
        assertEquals(listOf("1 subscribed", "2 failed DEVICEDISCONNECTED", "1 ended DEVICEDISCONNECTED"), log)
    }

    @Test
    fun settleFailureRemovesOnlyItsOwnSubscriberAndFailsItsCompletion() {
        subscribe(1)
        subscribe(2)

        hub.finish(subscribeRequest(1), planSubscribe(1), error = writeFailed, cause = null)
        hub.deliver("k") { 7 }

        assertEquals(listOf("1 failed CHARACTERISTICNOTIFYCHANGEFAILED", "2 got 7"), log)
        assertNull(hub.remove(1))
    }

    @Test
    fun secondSettleIsIgnored() {
        activeSubscriber(1)

        hub.finish(subscribeRequest(1), plan = null, error = writeFailed, cause = FailCause.START_REFUSED)
        hub.deliver("k") { 7 }

        assertEquals(listOf("1 subscribed", "1 got 7"), log)
        assertTrue(hub.isSubscribed("k"))
        assertTrue(logs.records.isNotEmpty())
    }

    @Test
    fun settleAfterAnEndIsIgnored() {
        // A CCCD success that arrives after Service Changed ended the subscription.
        subscribe(1)
        val request = subscribeRequest(1)
        val plan = hub.plan(request, osNotifying = null)
        hub.endKeys(servicesChanged) { true }

        hub.finish(request, plan, error = null, cause = null)

        assertEquals(listOf("1 failed SERVICESNOTDISCOVERED"), log)
        assertFalse(hub.isSubscribed("k"))
    }

    @Test
    fun subscribeFailedByTheQueueClosingWaitsForTheEndOfItsSubscriptions() {
        subscribe(1)

        hub.finish(subscribeRequest(1), plan = null, error = lost, cause = FailCause.QUEUE_CLOSED)
        assertEquals(emptyList<String>(), log)

        // What ended the link, not the queue's close error, reaches the caller.
        hub.endAll(TestError("OPERATIONTIMEDOUT", "timed out"))
        assertEquals(listOf("1 failed OPERATIONTIMEDOUT"), log)
    }

    @Test
    fun subscribeThatTimedOutFailsItsCompletionWithTheTimeout() {
        subscribe(1)
        val request = subscribeRequest(1)
        val plan = hub.plan(request, osNotifying = null)

        hub.finish(request, plan, error = TestError("OPERATIONTIMEDOUT", "timed out"), cause = FailCause.TIMED_OUT)

        assertEquals(listOf("1 failed OPERATIONTIMEDOUT"), log)
        // The write went out unanswered: the next subscribe writes again.
        subscribe(2)
        assertTrue(planSubscribe(2).write)
    }

    @Test
    fun unsubscribeFailedByTheQueueClosingSucceeds() {
        activeSubscriber(1)
        hub.remove(1)
        val closed = unsubscribeRequest()

        hub.finish(closed, plan = null, error = lost, cause = FailCause.QUEUE_CLOSED)

        assertEquals("unsubscribe of k succeeded", log.last())
    }

    @Test
    fun unsubscribeThatTimedOutFailsWithTheTimeout() {
        activeSubscriber(1)
        hub.remove(1)
        val timedOut = unsubscribeRequest()

        hub.finish(timedOut, hub.plan(timedOut, osNotifying = null), error = TestError("OPERATIONTIMEDOUT"), cause = FailCause.TIMED_OUT)

        assertEquals("unsubscribe of k failed OPERATIONTIMEDOUT", log.last())
        // The write went out unanswered: the next unsubscribe writes again.
        assertTrue(planUnsubscribe().write)
    }

    @Test
    fun unsubscribeWriteErrorFailsItsReply() {
        activeSubscriber(1)
        hub.remove(1)
        val written = unsubscribeRequest()
        val refused = unsubscribeRequest()

        hub.finish(written, hub.plan(written, osNotifying = null), error = writeFailed, cause = null)
        hub.finish(refused, plan = null, error = servicesChanged, cause = FailCause.START_REFUSED)

        assertEquals(
            listOf("unsubscribe of k failed CHARACTERISTICNOTIFYCHANGEFAILED", "unsubscribe of k failed SERVICESNOTDISCOVERED"),
            log.takeLast(2),
        )
    }

    @Test
    fun removeStopsDeliveryAtOnceAndCancelsAPendingCompletion() {
        subscribe(1)

        assertEquals("k", hub.remove(1))
        hub.deliver("k") { 7 }
        subscribeSucceeds(1)
        hub.endAll(lost)

        assertEquals(listOf("1 failed OPERATIONCANCELLED"), log)
    }

    @Test
    fun removedActiveSubscriberIsNeverEnded() {
        activeSubscriber(1)

        assertEquals("k", hub.remove(1))
        hub.endAll(lost)

        assertEquals(listOf("1 subscribed"), log)
    }

    @Test
    fun removeOfAnUnknownOrEndedIdReturnsNull() {
        activeSubscriber(1)
        hub.endAll(lost)
        subscribe(2)
        hub.remove(2)

        assertNull(hub.remove(99))
        assertNull(hub.remove(1))
        assertNull(hub.remove(2))
    }

    @Test
    fun endAllFailsPendingCompletionsThenEndsActiveSubscribersInSubscriptionOrder() {
        activeSubscriber(1)
        subscribe(2)
        activeSubscriber(3, key = "other")
        subscribe(4, key = "other")
        log.clear()

        hub.endAll(lost)
        hub.endAll(lost)
        hub.deliver("k") { 7 }
        hub.deliver("other") { 7 }

        assertEquals(
            listOf("2 failed DEVICEDISCONNECTED", "4 failed DEVICEDISCONNECTED", "1 ended DEVICEDISCONNECTED", "3 ended DEVICEDISCONNECTED"),
            log,
        )
        assertFalse(hub.isSubscribed("k"))
        assertFalse(hub.isSubscribed("other"))
    }

    @Test
    fun endCallbacksSeeTheStateAfterTheEnd() {
        var seenSubscribed: Boolean? = null
        var seenRemoved: String? = "not called"
        subscribe(1, onCompleted = {
            seenSubscribed = hub.isSubscribed("k")
            seenRemoved = hub.remove(2)
        })
        activeSubscriber(2)

        hub.endAll(lost)

        assertEquals(false, seenSubscribed)
        assertNull(seenRemoved)
        assertEquals(listOf("2 subscribed", "1 failed DEVICEDISCONNECTED", "2 ended DEVICEDISCONNECTED"), log)
    }

    @Test
    fun endAllResetsTheTrackedStateSoTheNextSubscribeWritesOn() {
        activeSubscriber(1)

        hub.endAll(lost)
        subscribe(2)

        assertTrue(planSubscribe(2).write)
    }

    @Test
    fun endKeysEndsAndResetsOnlyTheMatchingCharacteristics() {
        activeSubscriber(1, key = "a")
        activeSubscriber(2, key = "b")
        log.clear()

        hub.endKeys(servicesChanged) { it == "a" }
        hub.deliver("a") { 7 }
        hub.deliver("b") { 8 }
        subscribe(3, key = "a")
        subscribe(4, key = "b")

        assertEquals(listOf("1 ended SERVICESNOTDISCOVERED", "2 got 8"), log)
        assertTrue(planSubscribe(3, key = "a").write)
        assertFalse(planSubscribe(4, key = "b").write)
    }

    @Test
    fun endKeysFailsAPendingSubscriberOfAMatchingCharacteristic() {
        subscribe(1, key = "a")
        subscribe(2, key = "b")

        hub.endKeys(servicesChanged) { it == "a" }

        // Its completion fails; an end never fires for a subscription that never completed.
        assertEquals(listOf("1 failed SERVICESNOTDISCOVERED"), log)
        assertNull(hub.remove(1))
        assertEquals("b", hub.remove(2))
    }

    @Test
    fun writeResultFromBeforeAnEndOfItsCharacteristicIsIgnored() {
        subscribe(1)
        val request = subscribeRequest(1)
        val plan = hub.plan(request, osNotifying = null)
        hub.endAll(lost)
        subscribe(2)

        hub.finish(request, plan, error = null, cause = null)

        assertTrue(planSubscribe(2).write)
    }

    @Test
    fun writeResultIsAppliedWhenAnEndTouchedOnlyOtherCharacteristics() {
        subscribe(1, key = "b")
        val request = subscribeRequest(1, key = "b")
        val plan = hub.plan(request, osNotifying = null)
        hub.endKeys(servicesChanged) { it == "a" }
        hub.finish(request, plan, error = null, cause = null)

        hub.remove(1)

        assertTrue(planUnsubscribe("b").write)
    }

    @Test
    fun writeResultOfAPlanWithoutAWriteChangesNothing() {
        activeSubscriber(1)
        subscribe(2)
        val request = subscribeRequest(2)
        val plan = hub.plan(request, osNotifying = null)
        assertFalse(plan.write)

        hub.finish(request, plan, error = writeFailed, cause = null)

        // Still tracked ON: a third subscriber needs no write.
        subscribe(3)
        assertFalse(planSubscribe(3).write)
    }

    @Test
    fun everyEndBumpsTheGeneration() {
        val start = hub.generation

        hub.endKeys(servicesChanged) { false }
        val afterEndKeys = hub.generation
        hub.endAll(lost)

        assertEquals(start + 1, afterEndKeys)
        assertEquals(start + 2, hub.generation)
    }

    @Test
    fun isSubscribedOnlyWhileAnActiveSubscriberExists() {
        subscribe(1)
        assertFalse(hub.isSubscribed("k"))

        subscribeSucceeds(1)
        assertTrue(hub.isSubscribed("k"))

        hub.remove(1)
        assertFalse(hub.isSubscribed("k"))
    }

    @Test
    fun subscriberRemovedDuringDeliveryIsSkippedAndOneAddedWaitsForTheNextValue() {
        subscribe(1, onValue = { value ->
            if (value == 7) {
                hub.remove(2)
                subscribe(4)
            }
        })
        subscribe(2)
        subscribe(3)

        hub.deliver("k") { 7 }
        hub.deliver("k") { 8 }

        assertEquals(
            listOf("1 got 7", "2 failed OPERATIONCANCELLED", "3 got 7", "1 got 8", "3 got 8", "4 got 8"),
            log,
        )
    }

    @Test
    fun subscriberEndedDuringDeliveryIsSkipped() {
        // User callbacks can't call the hub inline (the facade posts every
        // call); this stands for platform code ending the link while a
        // delivery is under way.
        subscribe(1, onValue = { hub.endAll(lost) })
        activeSubscriber(2)
        log.clear()

        hub.deliver("k") { 7 }

        assertEquals(listOf("1 got 7", "1 failed DEVICEDISCONNECTED", "2 ended DEVICEDISCONNECTED"), log)
    }
}
