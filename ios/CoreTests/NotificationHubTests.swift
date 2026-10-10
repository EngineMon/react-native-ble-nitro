import XCTest
@testable import BleNitroCore

/**
 * Unit tests for `NotificationHub`. Characteristics are strings, values ints. A CCCD
 * operation is simulated by its plan and its finish, in the order the link's operation
 * queue runs them.
 */
final class NotificationHubTests: XCTestCase {
    private typealias Hub = NotificationHub<String, Int, TestError>

    private let hub = Hub(cancelledError: { TestError("OPERATIONCANCELLED", $0) })
    private let log = EventLog()
    private let lost = TestError("DEVICEDISCONNECTED", "link lost")
    private let servicesChanged = TestError("SERVICESNOTDISCOVERED", "services changed")
    private let writeFailed = TestError("CHARACTERISTICNOTIFYCHANGEFAILED", "CCCD write failed")

    private func subscribe(
        _ id: Int64,
        key: String = "k",
        onValue: @escaping (Int) -> Void = { _ in },
        onCompleted: @escaping () -> Void = {}
    ) {
        hub.add(
            id: id,
            key: key,
            onValue: Listener { [log] value in
                log.add("\(id) got \(value)")
                onValue(value)
            },
            completion: Reply { [log] error, _ in
                log.add(error.map { "\(id) failed \($0.code)" } ?? "\(id) subscribed")
                onCompleted()
            },
            onEnded: Once { [log] error in log.add("\(id) ended \(error.code)") }
        )
    }

    /// Plans subscriber `id`'s subscribe operation (Android: no OS notifying state).
    private func planSubscribe(_ id: Int64, key: String = "k", osNotifying: Bool? = nil) -> Hub.CccdPlan {
        return hub.plan(.subscribe(id: id, key: key), osNotifying: osNotifying)
    }

    /// An unsubscribe request whose reply logs its outcome.
    private func unsubscribeRequest(_ key: String = "k") -> Hub.CccdRequest {
        return .unsubscribe(key: key, reply: Reply { [log] error, _ in
            log.add(error.map { "unsubscribe of \(key) failed \($0.code)" } ?? "unsubscribe of \(key) succeeded")
        })
    }

    /// Plans an unsubscribe operation of `key`.
    private func planUnsubscribe(_ key: String = "k", osNotifying: Bool? = nil) -> Hub.CccdPlan {
        return hub.plan(unsubscribeRequest(key), osNotifying: osNotifying)
    }

    /// Runs subscriber `id`'s subscribe operation to success, writing what its plan asks for.
    private func subscribeSucceeds(_ id: Int64, key: String = "k") {
        let request = Hub.CccdRequest.subscribe(id: id, key: key)
        hub.finish(request, plan: hub.plan(request, osNotifying: nil), error: nil, cause: nil)
    }

    /// Subscribes `id` and runs its subscribe operation to success.
    private func activeSubscriber(_ id: Int64, key: String = "k") {
        subscribe(id, key: key)
        subscribeSucceeds(id, key: key)
    }

    func testValuesReachPendingAndActiveSubscribersOfTheirCharacteristic() {
        activeSubscriber(1)
        subscribe(2)
        activeSubscriber(3, key: "other")
        let before = log.entries.count

        hub.deliver(key: "k") { 7 }

        XCTAssertEqual(Array(log.entries.dropFirst(before)), ["1 got 7", "2 got 7"])
    }

    func testEverySubscriberGetsItsOwnValueAndNoneIsMadeWithoutAReceiver() {
        var made = 0
        let makeValue = { () -> Int in
            made += 1
            return made * 10
        }
        subscribe(1, onValue: { [unowned self] _ in _ = self.hub.remove(id: 2) })
        subscribe(2)
        activeSubscriber(3)
        subscribe(4, key: "left")
        _ = hub.remove(id: 4)
        let before = log.entries.count

        hub.deliver(key: "k", makeValue: makeValue)
        hub.deliver(key: "left", makeValue: makeValue)
        hub.deliver(key: "unknown", makeValue: makeValue)

        // One value per receiver, none for subscriber 2 (removed during the delivery), the
        // characteristic whose last subscriber left, or one never subscribed.
        XCTAssertEqual(Array(log.entries.dropFirst(before)), ["1 got 10", "2 failed OPERATIONCANCELLED", "3 got 20"])
        XCTAssertEqual(made, 2)
    }

    func testFirstSubscribeWritesOnAndLaterOnesDoNot() {
        subscribe(1)
        let first = planSubscribe(1)
        XCTAssertTrue(first.write)
        XCTAssertTrue(first.enable)
        hub.finish(.subscribe(id: 1, key: "k"), plan: first, error: nil, cause: nil)

        subscribe(2)
        let second = planSubscribe(2)

        XCTAssertFalse(second.write)
        XCTAssertTrue(second.enable)
    }

    func testSubscribeOperationWritesOnlyForItsOwnPresentSubscriber() {
        subscribe(1)
        subscribe(2)
        _ = hub.remove(id: 1)

        let ofRemoved = planSubscribe(1)
        let ofPresent = planSubscribe(2)

        XCTAssertFalse(ofRemoved.write)
        XCTAssertTrue(ofRemoved.enable)
        XCTAssertTrue(ofPresent.write)
    }

    func testSubscribeRemovedBeforeItsOperationRanWritesNothingEitherWay() {
        subscribe(1)
        _ = hub.remove(id: 1)

        let subscribePlan = planSubscribe(1)
        let unsubscribePlan = planUnsubscribe()

        XCTAssertFalse(subscribePlan.write)
        XCTAssertFalse(subscribePlan.enable)
        XCTAssertFalse(unsubscribePlan.write)
    }

    func testPlanForASubscriberOfAnotherCharacteristicWritesNothing() {
        subscribe(1, key: "a")

        let plan = planSubscribe(1, key: "b")

        XCTAssertFalse(plan.write)
        XCTAssertFalse(plan.enable)
        XCTAssertTrue(planSubscribe(1, key: "a").write)
    }

    func testUnsubscribeWritesOffOnlyAfterTheLastSubscriber() {
        activeSubscriber(1)
        activeSubscriber(2)

        _ = hub.remove(id: 1)
        let notLast = planUnsubscribe()
        _ = hub.remove(id: 2)
        let request = unsubscribeRequest()
        let last = hub.plan(request, osNotifying: nil)
        hub.finish(request, plan: last, error: nil, cause: nil)
        let afterOff = planUnsubscribe()

        XCTAssertFalse(notLast.write)
        XCTAssertTrue(notLast.enable)
        XCTAssertTrue(last.write)
        XCTAssertFalse(last.enable)
        XCTAssertFalse(afterOff.write)
        XCTAssertEqual(log.entries.last, "unsubscribe of k succeeded")
    }

    func testFailedWriteMakesTheStateUnknownSoTheNextOperationWritesEitherWay() {
        activeSubscriber(1)
        _ = hub.remove(id: 1)
        let unsubscribe = unsubscribeRequest()
        hub.finish(unsubscribe, plan: hub.plan(unsubscribe, osNotifying: nil), error: writeFailed, cause: nil)

        subscribe(2)
        let on = planSubscribe(2)
        hub.finish(.subscribe(id: 2, key: "k"), plan: on, error: writeFailed, cause: nil)
        let offAgain = planUnsubscribe()

        XCTAssertTrue(on.write)
        XCTAssertTrue(offAgain.write)
    }

    func testOsNotifyingStateReplacesTheTrackedState() {
        subscribe(1)
        let alreadyNotifying = planSubscribe(1, osNotifying: true)
        hub.finish(.subscribe(id: 1, key: "k"), plan: alreadyNotifying, error: nil, cause: nil)
        _ = hub.remove(id: 1)
        let stoppedByTheOs = planUnsubscribe(osNotifying: false)
        let stillNotifying = planUnsubscribe(osNotifying: true)

        XCTAssertFalse(alreadyNotifying.write)
        XCTAssertFalse(stoppedByTheOs.write)
        XCTAssertTrue(stillNotifying.write)
    }

    func testSettleSuccessActivatesOnlyItsOwnSubscriber() {
        subscribe(1)
        subscribe(2)

        subscribeSucceeds(1)

        XCTAssertEqual(log.entries, ["1 subscribed"])
        XCTAssertTrue(hub.isSubscribed(key: "k"))
        hub.endAll(error: lost)
        XCTAssertEqual(log.entries, ["1 subscribed", "2 failed DEVICEDISCONNECTED", "1 ended DEVICEDISCONNECTED"])
    }

    func testSettleFailureRemovesOnlyItsOwnSubscriberAndFailsItsCompletion() {
        subscribe(1)
        subscribe(2)

        hub.finish(.subscribe(id: 1, key: "k"), plan: planSubscribe(1), error: writeFailed, cause: nil)
        hub.deliver(key: "k") { 7 }

        XCTAssertEqual(log.entries, ["1 failed CHARACTERISTICNOTIFYCHANGEFAILED", "2 got 7"])
        XCTAssertNil(hub.remove(id: 1))
    }

    func testSecondSettleIsIgnored() {
        activeSubscriber(1)

        hub.finish(.subscribe(id: 1, key: "k"), plan: nil, error: writeFailed, cause: .startRefused)
        hub.deliver(key: "k") { 7 }

        XCTAssertEqual(log.entries, ["1 subscribed", "1 got 7"])
        XCTAssertTrue(hub.isSubscribed(key: "k"))
    }

    func testSettleAfterAnEndIsIgnored() {
        // A CCCD success that arrives after Service Changed ended the subscription.
        subscribe(1)
        let request = Hub.CccdRequest.subscribe(id: 1, key: "k")
        let plan = hub.plan(request, osNotifying: nil)
        hub.endKeys(error: servicesChanged) { _ in true }

        hub.finish(request, plan: plan, error: nil, cause: nil)

        XCTAssertEqual(log.entries, ["1 failed SERVICESNOTDISCOVERED"])
        XCTAssertFalse(hub.isSubscribed(key: "k"))
    }

    func testSubscribeFailedByTheQueueClosingWaitsForTheEndOfItsSubscriptions() {
        subscribe(1)

        hub.finish(.subscribe(id: 1, key: "k"), plan: nil, error: lost, cause: .queueClosed)
        XCTAssertEqual(log.entries, [])

        // What ended the link, not the queue's close error, reaches the caller.
        hub.endAll(error: TestError("OPERATIONTIMEDOUT", "timed out"))
        XCTAssertEqual(log.entries, ["1 failed OPERATIONTIMEDOUT"])
    }

    func testSubscribeThatTimedOutFailsItsCompletionWithTheTimeout() {
        subscribe(1)
        let request = Hub.CccdRequest.subscribe(id: 1, key: "k")
        let plan = hub.plan(request, osNotifying: nil)

        hub.finish(request, plan: plan, error: TestError("OPERATIONTIMEDOUT", "timed out"), cause: .timedOut)

        XCTAssertEqual(log.entries, ["1 failed OPERATIONTIMEDOUT"])
        // The write went out unanswered: the next subscribe writes again.
        subscribe(2)
        XCTAssertTrue(planSubscribe(2).write)
    }

    func testUnsubscribeFailedByTheQueueClosingSucceeds() {
        activeSubscriber(1)
        _ = hub.remove(id: 1)
        let closed = unsubscribeRequest()

        hub.finish(closed, plan: hub.plan(closed, osNotifying: nil), error: lost, cause: .queueClosed)

        XCTAssertEqual(log.entries.last, "unsubscribe of k succeeded")
    }

    func testUnsubscribeThatTimedOutFailsWithTheTimeout() {
        activeSubscriber(1)
        _ = hub.remove(id: 1)
        let timedOut = unsubscribeRequest()

        hub.finish(timedOut, plan: hub.plan(timedOut, osNotifying: nil), error: TestError("OPERATIONTIMEDOUT"), cause: .timedOut)

        XCTAssertEqual(log.entries.last, "unsubscribe of k failed OPERATIONTIMEDOUT")
        // The write went out unanswered: the next unsubscribe writes OFF again.
        XCTAssertTrue(planUnsubscribe().write)
    }

    func testUnsubscribeWriteErrorFailsItsReply() {
        activeSubscriber(1)
        _ = hub.remove(id: 1)
        let written = unsubscribeRequest()
        let refused = unsubscribeRequest()

        hub.finish(written, plan: hub.plan(written, osNotifying: nil), error: writeFailed, cause: nil)
        hub.finish(refused, plan: nil, error: servicesChanged, cause: .startRefused)

        XCTAssertEqual(
            Array(log.entries.suffix(2)),
            ["unsubscribe of k failed CHARACTERISTICNOTIFYCHANGEFAILED", "unsubscribe of k failed SERVICESNOTDISCOVERED"]
        )
    }

    func testRemoveStopsDeliveryAtOnceAndCancelsAPendingCompletion() {
        subscribe(1)

        XCTAssertEqual(hub.remove(id: 1), "k")
        hub.deliver(key: "k") { 7 }
        subscribeSucceeds(1)
        hub.endAll(error: lost)

        XCTAssertEqual(log.entries, ["1 failed OPERATIONCANCELLED"])
    }

    func testRemovedActiveSubscriberIsNeverEnded() {
        activeSubscriber(1)

        XCTAssertEqual(hub.remove(id: 1), "k")
        hub.endAll(error: lost)

        XCTAssertEqual(log.entries, ["1 subscribed"])
    }

    func testRemoveOfAnUnknownOrEndedIdReturnsNull() {
        activeSubscriber(1)
        hub.endAll(error: lost)
        subscribe(2)
        _ = hub.remove(id: 2)

        XCTAssertNil(hub.remove(id: 99))
        XCTAssertNil(hub.remove(id: 1))
        XCTAssertNil(hub.remove(id: 2))
    }

    func testEndAllFailsPendingCompletionsThenEndsActiveSubscribersInSubscriptionOrder() {
        activeSubscriber(1)
        subscribe(2)
        activeSubscriber(3, key: "other")
        subscribe(4, key: "other")
        let before = log.entries.count

        hub.endAll(error: lost)
        hub.endAll(error: lost)
        hub.deliver(key: "k") { 7 }
        hub.deliver(key: "other") { 7 }

        XCTAssertEqual(
            Array(log.entries.dropFirst(before)),
            ["2 failed DEVICEDISCONNECTED", "4 failed DEVICEDISCONNECTED", "1 ended DEVICEDISCONNECTED", "3 ended DEVICEDISCONNECTED"]
        )
        XCTAssertFalse(hub.isSubscribed(key: "k"))
        XCTAssertFalse(hub.isSubscribed(key: "other"))
    }

    func testEndCallbacksSeeTheStateAfterTheEnd() {
        var seenSubscribed: Bool?
        var seenRemoved: String? = "not called"
        subscribe(1, onCompleted: { [unowned self] in
            seenSubscribed = self.hub.isSubscribed(key: "k")
            seenRemoved = self.hub.remove(id: 2)
        })
        activeSubscriber(2)

        hub.endAll(error: lost)

        XCTAssertEqual(seenSubscribed, false)
        XCTAssertNil(seenRemoved)
        XCTAssertEqual(log.entries, ["2 subscribed", "1 failed DEVICEDISCONNECTED", "2 ended DEVICEDISCONNECTED"])
    }

    func testEndAllResetsTheTrackedStateSoTheNextSubscribeWritesOn() {
        activeSubscriber(1)

        hub.endAll(error: lost)
        subscribe(2)

        XCTAssertTrue(planSubscribe(2).write)
    }

    func testEndKeysEndsAndResetsOnlyTheMatchingCharacteristics() {
        activeSubscriber(1, key: "a")
        activeSubscriber(2, key: "b")
        let before = log.entries.count

        hub.endKeys(error: servicesChanged) { $0 == "a" }
        hub.deliver(key: "a") { 7 }
        hub.deliver(key: "b") { 8 }
        subscribe(3, key: "a")
        subscribe(4, key: "b")

        XCTAssertEqual(Array(log.entries.dropFirst(before)), ["1 ended SERVICESNOTDISCOVERED", "2 got 8"])
        XCTAssertTrue(planSubscribe(3, key: "a").write)
        XCTAssertFalse(planSubscribe(4, key: "b").write)
    }

    func testEndKeysFailsAPendingSubscriberOfAMatchingCharacteristic() {
        subscribe(1, key: "a")
        subscribe(2, key: "b")

        hub.endKeys(error: servicesChanged) { $0 == "a" }

        // Its completion fails; an end never fires for a subscription that never completed.
        XCTAssertEqual(log.entries, ["1 failed SERVICESNOTDISCOVERED"])
        XCTAssertNil(hub.remove(id: 1))
        XCTAssertEqual(hub.remove(id: 2), "b")
    }

    func testWriteResultFromBeforeAnEndOfItsCharacteristicIsIgnored() {
        subscribe(1)
        let request = Hub.CccdRequest.subscribe(id: 1, key: "k")
        let plan = hub.plan(request, osNotifying: nil)
        hub.endAll(error: lost)
        subscribe(2)

        hub.finish(request, plan: plan, error: nil, cause: nil)

        XCTAssertTrue(planSubscribe(2).write)
    }

    func testWriteResultIsAppliedWhenAnEndTouchedOnlyOtherCharacteristics() {
        subscribe(1, key: "b")
        let request = Hub.CccdRequest.subscribe(id: 1, key: "b")
        let plan = hub.plan(request, osNotifying: nil)
        hub.endKeys(error: servicesChanged) { $0 == "a" }
        hub.finish(request, plan: plan, error: nil, cause: nil)

        _ = hub.remove(id: 1)

        XCTAssertTrue(planUnsubscribe("b").write)
    }

    func testWriteResultOfAPlanWithoutAWriteChangesNothing() {
        activeSubscriber(1)
        subscribe(2)
        let request = Hub.CccdRequest.subscribe(id: 2, key: "k")
        let plan = hub.plan(request, osNotifying: nil)
        XCTAssertFalse(plan.write)

        hub.finish(request, plan: plan, error: writeFailed, cause: nil)

        // Still tracked ON: a third subscriber needs no write.
        subscribe(3)
        XCTAssertFalse(planSubscribe(3).write)
    }

    func testEveryEndBumpsTheGeneration() {
        let start = hub.generation

        hub.endKeys(error: servicesChanged) { _ in false }
        let afterEndKeys = hub.generation
        hub.endAll(error: lost)

        XCTAssertEqual(afterEndKeys, start + 1)
        XCTAssertEqual(hub.generation, start + 2)
    }

    func testIsSubscribedOnlyWhileAnActiveSubscriberExists() {
        subscribe(1)
        XCTAssertFalse(hub.isSubscribed(key: "k"))

        subscribeSucceeds(1)
        XCTAssertTrue(hub.isSubscribed(key: "k"))

        _ = hub.remove(id: 1)
        XCTAssertFalse(hub.isSubscribed(key: "k"))
    }

    func testSubscriberRemovedDuringDeliveryIsSkippedAndOneAddedWaitsForTheNextValue() {
        subscribe(1, onValue: { [unowned self] value in
            if value == 7 {
                _ = self.hub.remove(id: 2)
                self.subscribe(4)
            }
        })
        subscribe(2)
        subscribe(3)

        hub.deliver(key: "k") { 7 }
        hub.deliver(key: "k") { 8 }

        XCTAssertEqual(
            log.entries,
            ["1 got 7", "2 failed OPERATIONCANCELLED", "3 got 7", "1 got 8", "3 got 8", "4 got 8"]
        )
    }

    func testSubscriberEndedDuringDeliveryIsSkipped() {
        // User callbacks can't call the hub inline (the facade posts every call); this
        // stands for the glue ending the link while a delivery is under way.
        subscribe(1, onValue: { [unowned self] _ in self.hub.endAll(error: self.lost) })
        activeSubscriber(2)
        let before = log.entries.count

        hub.deliver(key: "k") { 7 }

        XCTAssertEqual(Array(log.entries.dropFirst(before)), ["1 got 7", "1 failed DEVICEDISCONNECTED", "2 ended DEVICEDISCONNECTED"])
    }
}
